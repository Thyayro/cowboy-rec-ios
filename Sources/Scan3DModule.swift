import ARKit
import AVFoundation
import CoreImage
import ImageIO
import QuickLook
import SceneKit
import SwiftUI

// SCAN 3D (0.12.0): captura pra fotogrametria. O ARKit dá a posição do celular em METROS em cada foto: o PC (RTX) monta a
// malha com COLMAP+OpenMVS e usa essas posições pra deixar o modelo em escala real, em pé e sem o chão/fundo.
// Disparo automático: foto em alta resolução a cada ~5° em volta do objeto, só com o celular firme (sem borrão);
// foco e luz travam ao iniciar (textura igual em todas as fotos). Envio pra fila da VPS (scanner3d) com o login do Rec;
// PC desligado = o scan espera na fila.

enum Scan3DAPI {
  static let origin = URL(string: "https://scanner3d.ybguyl.easypanel.host")!
  static func request(_ path: String, method: String = "GET", json: [String: Any]? = nil, body: Data? = nil) async throws -> (Int, Any?) {
    guard let cred = await MainActor.run(body: { CowboyCloud.shared.credential }) else { throw Scan3DError("Entre na conta do Cowboy Rec primeiro") }
    var r = URLRequest(url: URL(string: path, relativeTo: origin)!.absoluteURL)
    r.httpMethod = method; r.timeoutInterval = 120; r.setValue(cred, forHTTPHeaderField: "x-key")
    if let json { r.httpBody = try JSONSerialization.data(withJSONObject: json); r.setValue("application/json", forHTTPHeaderField: "content-type") }
    if let body { r.httpBody = body }
    let (data, resp) = try await URLSession.shared.data(for: r)
    return ((resp as? HTTPURLResponse)?.statusCode ?? 0, try? JSONSerialization.jsonObject(with: data))
  }
}
struct Scan3DError: LocalizedError { let msg: String; init(_ m: String) { msg = m }; var errorDescription: String? { msg } }

// ------------------------------------------------------------------ captura
final class Scan3DCamera: NSObject, ObservableObject, ARSessionDelegate, @unchecked Sendable {
  let session = ARSession()
  private let queue = DispatchQueue(label: "cowboy.scan3d", qos: .userInitiated)
  private let ci = CIContext(options: [.cacheIntermediates: false])
  @Published var ready = false
  @Published var scanning = false
  @Published var shots = 0
  @Published var coverage = Array(repeating: Array(repeating: false, count: 36), count: 3)   // baixo, meio, alto
  @Published var hint = "Aponte a mira pro objeto"
  @Published var formatLabel = "ARKit…"
  @Published var tracking = ""
  @Published var centerSet = false
  @Published var distanceCM = 0
  @Published var sharpOK = true
  private var sharpHist: [Float] = []
  var onCenter: ((simd_float3) -> Void)?
  private var dir: URL?
  private var frames: [[String: Any]] = []
  private var center: simd_float3?
  private var floorY: Float?
  private var lastShot: (p: simd_float3, dir: simd_float3, t: Double)?
  private var prev: (t: Double, m: simd_float4x4)?
  private var busy = false
  private var lastUI = 0.0
  private var highRes = false
  var mode = "objeto", quality = "ultra", title = ""
  // 0.12.2: FILMAGEM 4K (padrao) -- o PC escolhe o quadro mais nitido de cada direcao; fotos automaticas viram opcao
  @Published var videoMode = true
  private var writer: AVAssetWriter?
  private var vin: AVAssetWriterInput?
  private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
  private var vt0: Double?
  private var vfps = 30
  private var covBuf: [(Int, Int)] = []
  private var closing = false
  // 0.12.4: NOTA prevista + previa do VOLUME (pontos do ARKit em voxels de 6 mm) + objeto em suporte
  static let voxel: Float = 0.006
  @Published var score: Double = 0
  @Published var scoreTip = ""
  @Published var volume: [simd_float3] = []
  var suporte = false
  // 0.12.5: pausar/descartar no meio da gravacao + o OBJETO separado da mesa na previa (e o raio dele vai pro PC)
  @Published var paused = false
  private var isPaused = false, pauseAt: Double?, pausedTotal = 0.0
  private var objRadius: Float?, objAxis: simd_float2?
  private var vox: [Int32: UInt8] = [:]
  private var voxFrame = 0, lastVol = 0.0
  private var nTotal = 0, nFast = 0, nBadTrack = 0, nBadDist = 0, luxN = 0
  private var luxSum = 0.0

  private func publish(_ f: @escaping @Sendable () -> Void) { DispatchQueue.main.async(execute: f) }

  func start() {
    Task {
      guard await AVCaptureDevice.requestAccess(for: .video), ARWorldTrackingConfiguration.isSupported else {
        publish { self.hint = "Libere a câmera nos Ajustes" }; return
      }
      queue.async {
        let cfg = ARWorldTrackingConfiguration(); self.highRes = false
        let maior = ARWorldTrackingConfiguration.supportedVideoFormats.max { $0.imageResolution.width * $0.imageResolution.height < $1.imageResolution.width * $1.imageResolution.height }
        if self.videoMode {
          // filmagem: 4K (o maior formato de video do ARKit)
          if let f = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution ?? maior { cfg.videoFormat = f }
        } else if let f = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing { cfg.videoFormat = f; self.highRes = true }
        else if let f = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution { cfg.videoFormat = f }
        self.vfps = cfg.videoFormat.framesPerSecond
        cfg.planeDetection = [.horizontal]; cfg.videoHDRAllowed = false; cfg.isAutoFocusEnabled = true
        self.session.delegate = self; self.session.delegateQueue = self.queue
        self.session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        let r = cfg.videoFormat.imageResolution
        self.publish { self.formatLabel = (self.videoMode ? "Vídeo " : "Fotos ") + "\(Int(r.width))×\(Int(r.height))\(self.highRes ? " + foto alta" : "") · \(cfg.videoFormat.framesPerSecond) qps" }
      }
    }
  }
  func close(_ done: (@Sendable () -> Void)? = nil) {
    queue.async { self.unlockCamera(); self.session.pause(); self.publish { self.ready = false; done?() } }
  }

  /// centro do objeto: raio da mira (ou do toque) contra a geometria estimada
  func setCenter(from query: ARRaycastQuery?) {
    queue.async {
      guard !self.scanning, let q = query ?? self.session.currentFrame?.raycastQuery(from: CGPoint(x: 0.5, y: 0.5), allowing: .estimatedPlane, alignment: .any),
            let hit = self.session.raycast(q).first else { self.publish { self.hint = "Não achei o objeto na mira: chegue mais perto, com luz" }; return }
      let c = simd_make_float3(hit.worldTransform.columns.3)
      self.center = c; self.vox = [:]; self.objRadius = nil; self.objAxis = nil
      // chão = plano horizontal logo abaixo do centro (objeto em cima da mesa/piso)
      if let f = self.session.currentFrame {
        let ys = f.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }.map { $0.transform.columns.3.y }.filter { $0 <= c.y + 0.02 }
        self.floorY = ys.max()
      }
      self.publish { self.centerSet = true; self.onCenter?(c); self.hint = "Centro marcado. INICIAR e ande em volta a 20–35 cm. Dica: apoiado num copo menor que ele, a base sai limpa" }
    }
  }

  func begin() {
    queue.async {
      guard !self.scanning else { return }
      if self.center == nil {
        self.publish { self.hint = "Primeiro marque o objeto: mira nele e toque em MARCAR" }; return
      }
      let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scan3D", isDirectory: true)
      let d = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
      do { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) } catch { self.publish { self.hint = error.localizedDescription }; return }
      self.dir = d; self.frames = []; self.lastShot = nil; self.vt0 = nil; self.closing = false
      self.nTotal = 0; self.nFast = 0; self.nBadTrack = 0; self.nBadDist = 0; self.luxN = 0; self.luxSum = 0
      self.isPaused = false; self.pauseAt = nil; self.pausedTotal = 0
      if self.videoMode {
        guard let f = self.session.currentFrame else { return }
        let w = CVPixelBufferGetWidth(f.capturedImage), h = CVPixelBufferGetHeight(f.capturedImage)
        var falha: String?
        let ex = CowboyObjC.catching {
          do {
            let wr = try AVAssetWriter(outputURL: d.appendingPathComponent("scan.mov"), fileType: .mov)
            let set: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc, AVVideoWidthKey: w, AVVideoHeightKey: h,
                                      AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 60_000_000, AVVideoMaxKeyFrameIntervalKey: 30,
                                                                        AVVideoAllowFrameReorderingKey: false]]   // sem reordenar: quadro i = pose i
            let inp = AVAssetWriterInput(mediaType: .video, outputSettings: set); inp.expectsMediaDataInRealTime = true
            guard wr.canAdd(inp) else { falha = "Gravador de vídeo indisponível"; return }
            wr.add(inp)
            let ad = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: inp, sourcePixelBufferAttributes: nil)
            guard wr.startWriting() else { falha = wr.error?.localizedDescription ?? "Falha ao gravar"; return }
            wr.startSession(atSourceTime: .zero)
            self.writer = wr; self.vin = inp; self.adaptor = ad
          } catch { falha = error.localizedDescription }
        }
        if let m = falha ?? ex { self.publish { self.hint = m }; return }
      }
      self.lockCamera()
      self.publish {
        self.scanning = true; self.shots = 0; self.coverage = Array(repeating: Array(repeating: false, count: 36), count: 3)
        self.hint = self.videoMode ? "Filmando: ande em volta devagar. 3 voltas: baixa, meio, alta" : "Ande em volta, devagar. 3 voltas: baixa, meio, alta"
      }
    }
  }

  func setPaused(_ p: Bool) {
    queue.async {
      guard self.scanning else { return }
      self.isPaused = p
      self.publish { self.paused = p; self.hint = p ? "Pausado: toque em ▶ pra continuar de onde parou" : "Continuando: ande em volta devagar" }
    }
  }
  /// joga fora o scan em andamento (video, fotos e poses) sem enviar nada
  func discard() {
    queue.async {
      guard self.scanning, let d = self.dir else { return }
      self.unlockCamera()
      if let wr = self.writer { self.writer = nil; self.vin = nil; self.adaptor = nil; _ = CowboyObjC.catching { wr.cancelWriting() } }
      self.dir = nil; self.frames = []; self.isPaused = false; self.pauseAt = nil
      try? FileManager.default.removeItem(at: d)
      self.publish { self.scanning = false; self.paused = false; self.hint = "Scan descartado. Marque o objeto e comece de novo" }
    }
  }

  func finish(_ done: @escaping @Sendable (URL?) -> Void) {
    queue.async {
      guard self.scanning, let d = self.dir else { done(nil); return }
      self.unlockCamera(); self.isPaused = false
      let n = self.frames.count, minimo = self.videoMode ? 60 : 20
      let fecha: @Sendable () -> Void = {
        self.queue.async {
          self.writePoses(final: true); self.dir = nil
          self.publish { self.scanning = false; self.paused = false; self.hint = n >= minimo ? "Scan salvo: enviando pra fila" : "Muito curto (\(n)): scan descartado" }
          if n < minimo { try? FileManager.default.removeItem(at: d); done(nil); return }
          let nota = DispatchQueue.main.sync { self.score }
          let meta: [String: Any] = ["title": self.title.isEmpty ? "Scan \(Self.stamp())" : self.title, "mode": self.mode, "quality": self.quality,
                                     "nota_prevista": (nota * 10).rounded() / 10]
          try? JSONSerialization.data(withJSONObject: meta).write(to: d.appendingPathComponent("meta.json"), options: .atomic)
          done(d)
        }
      }
      if let wr = self.writer {
        self.writer = nil; let inp = self.vin; self.vin = nil; self.adaptor = nil
        self.publish { self.hint = "Fechando o vídeo…" }
        _ = CowboyObjC.catching { inp?.markAsFinished() }
        wr.finishWriting { fecha() }
      } else { fecha() }
    }
  }
  static func stamp() -> String { let f = DateFormatter(); f.dateFormat = "dd/MM HH:mm"; return f.string(from: Date()) }

  // foco + luz travados durante o scan (textura e foco iguais em todas as fotos); exposição curta já vem do ARKit
  private var lockedDevice: AVCaptureDevice?
  private func lockCamera() {
    guard let dev = ARWorldTrackingConfiguration.configurableCaptureDeviceForPrimaryCamera else { return }
    let err = CowboyObjC.catching {
      do {
        try dev.lockForConfiguration()
        // 0.12.1: foco NUNCA trava (a distancia muda andando em volta: foco travado = foto borrada, medido no 1o scan)
        if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
        let alvo = CMTime(value: 1, timescale: 250)          // video: obturador curto contra borrao de movimento
        if self.videoMode, dev.isExposureModeSupported(.custom), CMTimeCompare(dev.exposureDuration, alvo) > 0 {
          let ganho = Float(dev.exposureDuration.seconds / alvo.seconds)
          let iso = min(dev.activeFormat.maxISO, max(dev.activeFormat.minISO, dev.iso * ganho))
          dev.setExposureModeCustom(duration: CMTimeMaximum(alvo, dev.activeFormat.minExposureDuration), iso: iso, completionHandler: nil)
        } else if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
        if dev.isWhiteBalanceModeSupported(.locked) { dev.whiteBalanceMode = .locked }
        dev.unlockForConfiguration()
      } catch {}
    }
    if err == nil { lockedDevice = dev }
  }
  private func unlockCamera() {
    guard let dev = lockedDevice else { return }
    _ = CowboyObjC.catching {
      do {
        try dev.lockForConfiguration()
        if dev.isFocusModeSupported(.continuousAutoFocus) { dev.focusMode = .continuousAutoFocus }
        if dev.isExposureModeSupported(.continuousAutoExposure) { dev.exposureMode = .continuousAutoExposure }
        if dev.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { dev.whiteBalanceMode = .continuousAutoWhiteBalance }
        dev.unlockForConfiguration()
      } catch {}
    }
    lockedDevice = nil
  }

  func session(_ session: ARSession, didUpdate frame: ARFrame) {
    let ok: Bool, label: String
    switch frame.camera.trackingState {
    case .normal: ok = true; label = "rastreio ok"
    case .notAvailable: ok = false; label = "rastreio indisponível"
    case .limited(let r):
      ok = false
      switch r { case .excessiveMotion: label = "mais devagar"; case .insufficientFeatures: label = "pouca textura: mais luz/fundo com detalhe"; case .initializing, .relocalizing: label = "iniciando: mova um pouco"; @unknown default: label = "rastreio limitado" }
    }
    let m = frame.camera.transform, t = frame.timestamp
    // velocidade: giro (°/s) e deslocamento (m/s) entre quadros
    var rotSpeed: Float = 0, linSpeed: Float = 0
    if let p = prev, t > p.t {
      let dt = Float(t - p.t)
      let q = simd_quatf(simd_float3x3(simd_make_float3(m.columns.0), simd_make_float3(m.columns.1), simd_make_float3(m.columns.2)))
      let q0 = simd_quatf(simd_float3x3(simd_make_float3(p.m.columns.0), simd_make_float3(p.m.columns.1), simd_make_float3(p.m.columns.2)))
      rotSpeed = (q * q0.inverse).angle * 180 / .pi / dt
      linSpeed = simd_distance(simd_make_float3(m.columns.3), simd_make_float3(p.m.columns.3)) / dt
    }
    prev = (t, m)
    if t - lastUI > 0.25 { lastUI = t; publish { self.tracking = label; self.ready = ok } }
    if scanning && isPaused { if pauseAt == nil { pauseAt = t }; return }
    if let pa = pauseAt { pausedTotal += t - pa; pauseAt = nil }
    if let c = center {
      if scanning {
        let d = simd_distance(simd_make_float3(m.columns.3), c)
        nTotal += 1
        if rotSpeed > 30 || linSpeed > 0.35 { nFast += 1 }
        if !ok { nBadTrack += 1 }
        if d < 0.15 || d > 0.6 { nBadDist += 1 }
        if let le = frame.lightEstimate { luxSum += Double(le.ambientIntensity); luxN += 1 }
      }
      accumulatePoints(frame, center: c)
      if t - lastVol > 1.0 { lastVol = t; publishQuality() }
    }
    guard scanning, ok || (videoMode && writer != nil), !busy, let c = center else { return }
    let pos = simd_make_float3(m.columns.3)
    let fromC = pos - c, dist = simd_length(fromC)
    guard dist > 0.05 else { return }
    let dirC = fromC / dist
    if t - lastUI < 0.02 { let cm = Int(dist * 100); publish { self.distanceCM = cm } }
    if videoMode { recordVideo(frame, center: c, label: label, fast: rotSpeed > 30 || linSpeed > 0.35); return }
    if rotSpeed > 18 || linSpeed > 0.25 {
      if t - lastUI < 0.05 { publish { self.hint = "Mais devagar: foto só com o celular firme" } }
      return
    }
    if let l = lastShot {
      let ang = acos(max(-1, min(1, simd_dot(dirC, l.dir)))) * 180 / .pi
      guard (ang >= 5 || simd_distance(pos, l.p) >= 0.08), t - l.t >= 0.35 else { return }
    }
    // portao de nitidez (centro do quadro, onde esta o objeto): abaixo de 60% da mediana recente = foco ainda andando
    let sh = Self.centerSharpness(frame.capturedImage)
    let ref = sharpHist.count >= 5 ? sharpHist.sorted()[sharpHist.count / 2] : 0
    if ref > 0 && sh < 0.6 * ref {
      if t - lastUI < 0.05 { publish { self.sharpOK = false; self.hint = "Esperando o foco: segure firme" } }
      return
    }
    sharpHist.append(sh); if sharpHist.count > 25 { sharpHist.removeFirst() }
    if !sharpOK { publish { self.sharpOK = true } }
    busy = true
    let shot: (ARFrame) -> Void = { [weak self] f in self?.save(f, center: c) }
    if highRes {
      session.captureHighResolutionFrame { [weak self] f, _ in
        guard let self else { return }
        self.queue.async { if let f { shot(f) } else { shot(frame) }; self.busy = false }
      }
    } else { shot(frame); busy = false }
  }

  /// pontos que o ARKit acha no objeto viram voxels de 6 mm (so dentro de 30 cm do centro e acima da mesa)
  private func accumulatePoints(_ frame: ARFrame, center c: simd_float3) {
    voxFrame += 1
    guard voxFrame % 3 == 0, let pts = frame.rawFeaturePoints?.points else { return }
    let chao = (floorY ?? (c.y - 0.45)) + 0.010
    for p in pts {
      let d = p - c
      guard p.y > chao, d.y < 0.45, d.x * d.x + d.z * d.z < 0.09 else { continue }
      let ix = Int32((d.x / Self.voxel).rounded()) + 64, iy = Int32((d.y / Self.voxel).rounded()) + 128, iz = Int32((d.z / Self.voxel).rounded()) + 64
      guard ix >= 0, ix < 128, iy >= 0, iy < 256, iz >= 0, iz < 128 else { continue }
      let k = (ix << 16) | (iy << 8) | iz
      vox[k] = min(250, (vox[k] ?? 0) + 1)
    }
  }

  private func publishQuality() {
    if let c = center, let f = session.currentFrame {           // o plano da mesa costuma aparecer depois de marcar
      let ys = f.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }.map { $0.transform.columns.3.y }.filter { $0 <= c.y + 0.02 }
      if let y = ys.max(), y > (floorY ?? -.infinity) { floorY = y }
    }
    let obj = objectVoxels()
    var pts: [simd_float3] = []
    for k in obj {
      pts.append(simd_float3(Float((k >> 16) & 0xff) - 64, Float((k >> 8) & 0xff) - 128, Float(k & 0xff) - 64) * Self.voxel)
      if pts.count >= 5000 { break }
    }
    if pts.count >= 30 {                                         // raio do objeto (eixo = centro das colunas) vai pro PC cortar a mesa
      let cx = pts.reduce(Float(0)) { $0 + $1.x } / Float(pts.count), cz = pts.reduce(Float(0)) { $0 + $1.z } / Float(pts.count)
      let r = pts.map { simd_length(simd_float2($0.x - cx, $0.z - cz)) }.sorted()
      objRadius = r[min(r.count - 1, Int(Float(r.count) * 0.95))]
      if let c = center { objAxis = simd_float2(c.x + cx, c.z + cz) }
    }
    let st = (nTotal, nFast, nBadTrack, nBadDist, luxN > 0 ? luxSum / Double(luxN) : 0.0)
    publish { self.volume = pts; if self.scanning { self.updateScore(st, voxels: pts.count) } }
  }

  /// voxels do objeto: o grupo ligado ao ponto marcado (vizinhos ate 2 voxels = 12 mm). O resto e mesa/fundo.
  private func objectVoxels() -> [Int32] {
    let occ = Set(vox.filter { $0.value >= 2 }.keys)
    guard !occ.isEmpty else { return [] }
    func dec(_ k: Int32) -> (Int32, Int32, Int32) { ((k >> 16) & 0xff, (k >> 8) & 0xff, k & 0xff) }
    func enc(_ x: Int32, _ y: Int32, _ z: Int32) -> Int32 { (x << 16) | (y << 8) | z }
    var seed: Int32?, best = Int32.max
    for k in occ {                                               // o voxel mais perto do ponto marcado (64,128,64)
      let (x, y, z) = dec(k); let d = (x - 64) * (x - 64) + (y - 128) * (y - 128) + (z - 64) * (z - 64)
      if d < best { best = d; seed = k }
    }
    guard let s0 = seed, best <= 64 else { return Array(occ) }   // mais de 8 voxels (5 cm) do ponto: sem objeto claro ainda
    var seen: Set<Int32> = [s0], fila = [s0], i = 0
    while i < fila.count {
      let (x, y, z) = dec(fila[i]); i += 1
      for dx in -2...2 { for dy in -2...2 { for dz in -2...2 {
        let nx = x + Int32(dx), ny = y + Int32(dy), nz = z + Int32(dz)
        guard nx >= 0, nx < 128, ny >= 0, ny < 256, nz >= 0, nz < 128 else { continue }
        let k = enc(nx, ny, nz)
        if occ.contains(k) && !seen.contains(k) { seen.insert(k); fila.append(k) }
      } } }
    }
    return fila.count >= 20 ? fila : Array(occ)
  }

  /// nota 0-10 do modelo que vai sair: cobertura, firmeza, rastreio, distancia, luz e textura (pontos achados)
  func updateScore(_ s: (Int, Int, Int, Int, Double), voxels nv: Int) {
    let n = Double(max(1, s.0)), f = ringFill
    let parts: [(peso: Double, nota: Double, dica: String)] = [
      (0.40, 0.3 * min(1, f[0] / 0.8) + 0.45 * min(1, f[1] / 0.8) + 0.25 * min(1, f[2] / 0.7), "complete as voltas que faltam no anel"),
      (0.20, pow(1 - Double(s.1) / n, 2), "ande mais devagar: tem quadro borrado"),
      (0.15, 1 - Double(s.2) / n, "o rastreio caiu: mais luz e fundo com detalhe"),
      (0.10, 1 - Double(s.3) / n, "fique entre 15 e 50 cm do objeto"),
      (0.10, s.4 <= 0 ? 1 : min(1, s.4 / 700), "pouca luz: acenda a luz ou vá pra perto da janela"),
      (0.05, min(1, Double(nv) / 400), "objeto liso ou brilhante: pouca textura, a malha pode falhar")]
    score = 10 * parts.reduce(0) { $0 + $1.peso * $1.nota }
    let pior = parts.max { $0.peso * (1 - $0.nota) < $1.peso * (1 - $1.nota) }!
    scoreTip = pior.peso * (1 - pior.nota) >= 0.03 ? "Pra subir a nota: " + pior.dica : "Excelente: pode concluir"
  }
  var scoreText: String { String(format: "%.1f", score).replacingOccurrences(of: ".", with: ",") }

  private func recordVideo(_ frame: ARFrame, center c: simd_float3, label: String, fast: Bool) {
    guard let wr = writer, wr.status == .writing, let inp = vin, let ad = adaptor, inp.isReadyForMoreMediaData else { return }
    if vt0 == nil { vt0 = frame.timestamp }
    let pts = CMTime(seconds: frame.timestamp - (vt0 ?? 0) - pausedTotal, preferredTimescale: 600000)
    guard ad.append(frame.capturedImage, withPresentationTime: pts) else { return }
    let m = frame.camera.transform, k = frame.camera.intrinsics
    frames.append(["i": frames.count, "t": frame.timestamp - (vt0 ?? 0), "tracking": label == "rastreio ok" ? "normal" : label,
                   "transform": (0..<4).flatMap { col in (0..<4).map { row in Double(m[col][row]) } },
                   "intrinsics": (0..<3).flatMap { col in (0..<3).map { row in Double(k[col][row]) } }])
    let v = simd_make_float3(m.columns.3) - c, el = asin(max(-1, min(1, v.y / max(1e-4, simd_length(v))))) * 180 / .pi
    var az = atan2(v.z, v.x) * 180 / .pi; if az < 0 { az += 360 }
    covBuf.append((el < 15 ? 0 : (el < 45 ? 1 : 2), min(35, Int(az / 10))))
    let n = frames.count
    if n % 6 == 0 {                                       // tela: 5x por segundo
      let buf = covBuf; covBuf = []
      let seg = Double(n) / Double(max(1, vfps))
      publish {
        for (r, sct) in buf { self.coverage[r][sct] = true }
        self.shots = n
        let names = ["baixa", "do meio", "alta"]
        let missing = (0..<3).filter { r in self.coverage[r].filter { $0 }.count < 30 }
        self.hint = fast ? "Mais devagar: assim borra" : (missing.isEmpty ? "Cobertura completa! Pode concluir" : "Falta a volta \(names[missing[0]]) · \(Int(seg)) s")
      }
    }
    if n >= vfps * 240 && !closing { closing = true; finish { d in Task { @MainActor in if d != nil { Scan3DUploader.shared.kick() } } } }   // 4 min: fecha sozinho
  }

  static func centerSharpness(_ pb: CVPixelBuffer) -> Float {
    CVPixelBufferLockBaseAddress(pb, .readOnly); defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0) else { return 0 }
    let w = CVPixelBufferGetWidthOfPlane(pb, 0), h = CVPixelBufferGetHeightOfPlane(pb, 0), row = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    let p = base.assumingMemoryBound(to: UInt8.self)
    let n = 192, x0 = w / 2 - n, y0 = h / 2 - n      // 384x384 px do centro, passo 2
    var sum: Float = 0, sum2: Float = 0, cnt: Float = 0
    for j in stride(from: 2, to: 2 * n - 2, by: 2) {
      for i in stride(from: 2, to: 2 * n - 2, by: 2) {
        let o = (y0 + j) * row + x0 + i
        let l = 4 * Float(p[o]) - Float(p[o - 2]) - Float(p[o + 2]) - Float(p[o - 2 * row]) - Float(p[o + 2 * row])
        sum += l; sum2 += l * l; cnt += 1
      }
    }
    let m = sum / max(1, cnt); return sum2 / max(1, cnt) - m * m
  }

  /// fração coberta de cada volta (baixa, meio, alta)
  var ringFill: [Double] { coverage.map { Double($0.filter { $0 }.count) / 36 } }

  private func save(_ f: ARFrame, center c: simd_float3) {
    guard let d = dir else { return }
    let name = String(format: "img_%04d.jpg", frames.count + 1)
    let img = CIImage(cvPixelBuffer: f.capturedImage)
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
          let jpg = ci.jpegRepresentation(of: img, colorSpace: cs, options: [CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String): 0.95]) else { return }
    do { try jpg.write(to: d.appendingPathComponent(name)) } catch { return }
    let m = f.camera.transform, k = f.camera.intrinsics
    frames.append(["name": name, "t": f.timestamp,
                   "transform": (0..<4).flatMap { col in (0..<4).map { row in Double(m[col][row]) } },
                   "intrinsics": (0..<3).flatMap { col in (0..<3).map { row in Double(k[col][row]) } },
                   "width": CVPixelBufferGetWidth(f.capturedImage), "height": CVPixelBufferGetHeight(f.capturedImage)])
    let pos = simd_make_float3(m.columns.3)
    lastShot = (pos, simd_normalize(pos - c), f.timestamp)
    let v = pos - c, el = asin(max(-1, min(1, v.y / max(1e-4, simd_length(v))))) * 180 / .pi
    let row = el < 15 ? 0 : (el < 45 ? 1 : 2)
    var az = atan2(v.z, v.x) * 180 / .pi; if az < 0 { az += 360 }
    let sec = min(35, Int(az / 10)), n = frames.count
    if n % 10 == 0 { writePoses(final: false) }
    publish {
      self.shots = n; self.coverage[row][sec] = true
      let names = ["baixa", "do meio", "alta"]
      let missing = (0..<3).filter { r in self.coverage[r].filter { $0 }.count < 30 }
      self.hint = missing.isEmpty ? "Cobertura completa! Pode concluir (ou detalhe os cantos)" : "Falta a volta \(names[missing[0]]) · \(n) fotos"
    }
  }

  private func writePoses(final: Bool) {
    guard let d = dir, let c = center else { return }
    var doc: [String: Any] = ["schema": "cowboy-scan3d/v1", "units": "meters", "coordinate_system": "ARKit: y para cima, transform câmera→mundo column-major, câmera olha -Z",
                              "center": [c.x, c.y, c.z], "frames": frames, "complete": final]
    if videoMode { doc["video"] = "scan.mov"; doc["fps"] = vfps }
    if let floorY { doc["floor_y"] = floorY }
    if suporte { doc["suporte"] = true }                  // objeto em cima de algo MENOR que ele: o PC corta no degrau
    if let objRadius, let objAxis { doc["objeto_raio"] = objRadius; doc["objeto_eixo"] = [objAxis.x, objAxis.y] }   // objeto achado na previa: o PC corta a mesa em volta
    try? JSONSerialization.data(withJSONObject: doc).write(to: d.appendingPathComponent("poses.json"), options: .atomic)
  }
}

// ------------------------------------------------------------------ envio e lista de scans
@MainActor final class Scan3DUploader: ObservableObject {
  static let shared = Scan3DUploader()
  @Published var status = ""
  @Published var progress: Double = 0
  @Published var pending = 0
  @Published var jobs: [[String: Any]] = []
  @Published var pcOnline = false
  @Published var localPaused: Set<String> = []
  private var running = false
  private var removed: Set<String> = []
  private var base: URL { FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Scan3D", isDirectory: true) }

  func scans() -> [URL] {
    let all = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: [.creationDateKey])) ?? []
    return all.filter { FileManager.default.fileExists(atPath: $0.appendingPathComponent("meta.json").path) }
      .sorted { ($0.path) < ($1.path) }
  }

  func kick() {
    pending = scans().count
    guard !running else { return }
    running = true
    Task {
      defer { running = false; pending = scans().count }
      for d in scans() {
        if let j = jobOf(d), localPaused.contains(j) || removed.contains(j) { continue }
        var tries = 0
        while true {
          do { try await upload(d); break } catch {
            if (error as? Scan3DError)?.msg == "parado" { break }
            tries += 1; status = "Envio parado: \(error.localizedDescription). Tentando de novo…"
            if tries > 20 { return }
            try? await Task.sleep(nanoseconds: UInt64(min(60, 3 * tries)) * 1_000_000_000)
          }
        }
      }
      status = ""; await refresh()
    }
  }

  private func upload(_ d: URL) async throws {
    let metaURL = d.appendingPathComponent("meta.json")
    var meta = (try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [String: Any]) ?? [:]
    let names = try FileManager.default.contentsOfDirectory(atPath: d.path).filter { $0.hasSuffix(".jpg") || $0 == "poses.json" || $0 == "scan.mov" }.sorted()
    let sizes = try names.map { ((try FileManager.default.attributesOfItem(atPath: d.appendingPathComponent($0).path)[.size] as? NSNumber)?.intValue) ?? 0 }
    let total = Double(max(1, sizes.reduce(0, +)))
    var job = meta["job"] as? String
    if job == nil {
      let (code, obj) = try await Scan3DAPI.request("/api/jobs", method: "POST", json: ["title": meta["title"] ?? "Scan", "mode": meta["mode"] ?? "objeto", "quality": meta["quality"] ?? "ultra", "source": "cowboy-rec",
                                                                                        "files": zip(names, sizes).map { ["name": $0, "size": $1] }])
      guard code == 200, let o = obj as? [String: Any], let id = o["id"] as? String else { throw Scan3DError("fila recusou (\(code))") }
      job = id; meta["job"] = id
      try JSONSerialization.data(withJSONObject: meta).write(to: metaURL, options: .atomic)
    }
    guard let job else { return }
    var sent = 0.0
    for (i, name) in names.enumerated() {
      let file = d.appendingPathComponent(name)
      let (c0, o0) = try await Scan3DAPI.request("/api/jobs/\(job)/files/\(i)")
      if c0 == 404 && removed.contains(job) { try? FileManager.default.removeItem(at: d); throw Scan3DError("parado") }
      if c0 == 404 { meta["job"] = nil; try JSONSerialization.data(withJSONObject: meta).write(to: metaURL, options: .atomic); throw Scan3DError("job sumiu da fila, recriando") }
      var off = ((o0 as? [String: Any])?["got"] as? Int) ?? 0
      let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
      while off < sizes[i] {
        try h.seek(toOffset: UInt64(off))
        let chunk = h.readData(ofLength: 8 << 20)
        if localPaused.contains(job) || removed.contains(job) { status = ""; throw Scan3DError("parado") }
        let (c, o) = try await Scan3DAPI.request("/api/jobs/\(job)/files/\(i)?offset=\(off)", method: "PUT", body: chunk)
        guard c == 200 || c == 409, let got = (o as? [String: Any])?["got"] as? Int else { throw Scan3DError("pedaço recusado (\(c))") }
        off = got
        progress = (sent + Double(off)) / total
        status = String(format: "Enviando scan: %.0f%% de %.0f MB", progress * 100, total / 1_048_576)
      }
      sent += Double(sizes[i])
    }
    let (c, _) = try await Scan3DAPI.request("/api/jobs/\(job)/done", method: "POST")
    guard c == 200 else { throw Scan3DError("fechar o envio falhou (\(c))") }
    try? FileManager.default.removeItem(at: d)
    status = "Scan na fila: o PC processa assim que estiver ligado"
  }

  private func jobOf(_ d: URL) -> String? {
    guard let data = try? Data(contentsOf: d.appendingPathComponent("meta.json")),
          let m = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return m["job"] as? String
  }
  private func localDir(_ job: String) -> URL? { scans().first { jobOf($0) == job } }
  /// pausa: o que ainda sobe do iPhone para aqui; o que esta na fila/no PC para la (o PC guarda as etapas prontas)
  func pause(_ job: String) async {
    if localDir(job) != nil { localPaused.insert(job) }
    else { _ = try? await Scan3DAPI.request("/api/jobs/\(job)/pause", method: "POST") }
    await refresh()
  }
  func resume(_ job: String) async {
    if localPaused.remove(job) != nil { kick() }
    else { _ = try? await Scan3DAPI.request("/api/jobs/\(job)/retry", method: "POST") }
    await refresh()
  }
  func delete(_ job: String) async {
    removed.insert(job); localPaused.remove(job)
    if let d = localDir(job) { try? FileManager.default.removeItem(at: d) }
    _ = try? await Scan3DAPI.request("/api/jobs/\(job)", method: "DELETE")
    pending = scans().count; jobs.removeAll { ($0["id"] as? String) == job }
    await refresh()
  }

  func refresh() async {
    guard let (code, obj) = try? await Scan3DAPI.request("/api/jobs"), code == 200, let o = obj as? [String: Any] else { return }
    jobs = (o["jobs"] as? [[String: Any]]) ?? []; pcOnline = (o["worker_online"] as? Bool) ?? false
  }

  /// baixa o resultado pra ver no Quick Look (USDZ abre em AR)
  func download(job: String, name: String) async -> URL? {
    guard let url = URL(string: "/r/\(job)/\(name)", relativeTo: Scan3DAPI.origin)?.absoluteURL,
          let (tmp, resp) = try? await URLSession.shared.download(from: url), (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
    let dst = FileManager.default.temporaryDirectory.appendingPathComponent("\(job)-\(name)")
    try? FileManager.default.removeItem(at: dst); try? FileManager.default.moveItem(at: tmp, to: dst)
    return dst
  }
}

// ------------------------------------------------------------------ telas
struct Scan3DPreview: UIViewRepresentable {
  let camera: Scan3DCamera
  func makeCoordinator() -> Coordinator { Coordinator(camera: camera) }
  func makeUIView(context: Context) -> ARSCNView {
    let v = ARSCNView(); v.session = camera.session; v.automaticallyUpdatesLighting = false; v.preferredFramesPerSecond = 60
    v.addGestureRecognizer(UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tapped(_:))))
    context.coordinator.view = v
    camera.onCenter = { [weak coord = context.coordinator] c in coord?.showCenter(c) }
    return v
  }
  func updateUIView(_ v: ARSCNView, context: Context) {}
  final class Coordinator: NSObject {
    let camera: Scan3DCamera
    weak var view: ARSCNView?
    private var marker: SCNNode?
    init(camera: Scan3DCamera) { self.camera = camera }
    @objc func tapped(_ g: UITapGestureRecognizer) {
      guard !camera.scanning, let v = g.view as? ARSCNView else { return }
      camera.setCenter(from: v.raycastQuery(from: g.location(in: v), allowing: .estimatedPlane, alignment: .any))
    }
    func showCenter(_ c: simd_float3) {
      guard let v = view else { return }
      marker?.removeFromParentNode()
      let n = SCNNode()
      let s = SCNNode(geometry: SCNSphere(radius: 0.008)); s.geometry?.firstMaterial?.diffuse.contents = UIColor.systemYellow; s.geometry?.firstMaterial?.lightingModel = .constant
      let ring = SCNNode(geometry: SCNTorus(ringRadius: 0.12, pipeRadius: 0.002)); ring.geometry?.firstMaterial?.diffuse.contents = UIColor.systemYellow.withAlphaComponent(0.8); ring.geometry?.firstMaterial?.lightingModel = .constant
      n.addChildNode(s); n.addChildNode(ring); n.simdPosition = c
      v.scene.rootNode.addChildNode(n); marker = n
    }
  }
}

/// 0.12.4: mostruario do que ja foi captado -- voxels cinza girando (o volume da forma, antes do PC montar a malha)
struct Scan3DVolume: UIViewRepresentable {
  let points: [simd_float3]
  func makeUIView(context: Context) -> SCNView {
    let v = SCNView(); v.backgroundColor = .clear; v.scene = SCNScene(); v.autoenablesDefaultLighting = true
    v.antialiasingMode = .multisampling2X; v.isUserInteractionEnabled = false
    let holder = SCNNode(); holder.name = "holder"; v.scene?.rootNode.addChildNode(holder)
    holder.runAction(.repeatForever(.rotateBy(x: 0, y: .pi * 2, z: 0, duration: 12)))
    let cam = SCNNode(); cam.name = "cam"; cam.camera = SCNCamera(); cam.camera?.fieldOfView = 35; cam.camera?.zNear = 0.005
    v.scene?.rootNode.addChildNode(cam); v.pointOfView = cam
    return v
  }
  func updateUIView(_ v: SCNView, context: Context) {
    guard let root = v.scene?.rootNode, let holder = root.childNode(withName: "holder", recursively: false) else { return }
    holder.childNodes.forEach { $0.removeFromParentNode() }
    guard let p0 = points.first else { return }
    var lo = p0, hi = p0
    for p in points { lo = simd_min(lo, p); hi = simd_max(hi, p) }
    let n = SCNNode(geometry: Self.cubes(points, size: Scan3DCamera.voxel)); n.simdPosition = -(lo + hi) / 2
    holder.addChildNode(n)
    let r = max(0.04, simd_length(hi - lo) / 2)
    if let cam = root.childNode(withName: "cam", recursively: false) { cam.simdPosition = simd_float3(0, r * 0.8, r * 3.2); cam.simdLook(at: .zero) }
  }
  static func cubes(_ ps: [simd_float3], size s: Float) -> SCNGeometry {
    let h = s * 0.48
    let faces: [(simd_float3, [simd_float3])] = [
      (simd_float3(1, 0, 0), [simd_float3(1, -1, -1), simd_float3(1, 1, -1), simd_float3(1, 1, 1), simd_float3(1, -1, 1)]),
      (simd_float3(-1, 0, 0), [simd_float3(-1, -1, -1), simd_float3(-1, -1, 1), simd_float3(-1, 1, 1), simd_float3(-1, 1, -1)]),
      (simd_float3(0, 1, 0), [simd_float3(-1, 1, -1), simd_float3(-1, 1, 1), simd_float3(1, 1, 1), simd_float3(1, 1, -1)]),
      (simd_float3(0, -1, 0), [simd_float3(-1, -1, -1), simd_float3(1, -1, -1), simd_float3(1, -1, 1), simd_float3(-1, -1, 1)]),
      (simd_float3(0, 0, 1), [simd_float3(-1, -1, 1), simd_float3(1, -1, 1), simd_float3(1, 1, 1), simd_float3(-1, 1, 1)]),
      (simd_float3(0, 0, -1), [simd_float3(-1, -1, -1), simd_float3(-1, 1, -1), simd_float3(1, 1, -1), simd_float3(1, -1, -1)])]
    var vs: [SCNVector3] = [], ns: [SCNVector3] = [], idx: [Int32] = []
    vs.reserveCapacity(ps.count * 24); ns.reserveCapacity(ps.count * 24); idx.reserveCapacity(ps.count * 36)
    for p in ps {
      for (nrm, cs) in faces {
        let b = Int32(vs.count)
        for c in cs { let q = p + c * h; vs.append(SCNVector3(q.x, q.y, q.z)); ns.append(SCNVector3(nrm.x, nrm.y, nrm.z)) }
        idx += [b, b + 1, b + 2, b, b + 2, b + 3]
      }
    }
    let g = SCNGeometry(sources: [SCNGeometrySource(vertices: vs), SCNGeometrySource(normals: ns)],
                        elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    let m = SCNMaterial(); m.diffuse.contents = UIColor(white: 0.74, alpha: 1); m.lightingModel = .lambert; m.isDoubleSided = true
    g.materials = [m]; return g
  }
}

/// 3 anéis (volta baixa por fora, alta por dentro), 36 fatias de 10°: dourado = coberto
struct Scan3DCoverage: View {
  let coverage: [[Bool]]
  var body: some View {
    Canvas { ctx, size in
      let c = CGPoint(x: size.width / 2, y: size.height / 2), r0 = min(size.width, size.height) / 2
      for row in 0..<3 {
        let r = r0 * (1 - CGFloat(row) * 0.27) - 6
        for s in 0..<36 {
          var p = Path()
          p.addArc(center: c, radius: r, startAngle: .degrees(Double(s) * 10 + 1), endAngle: .degrees(Double(s) * 10 + 9), clockwise: false)
          ctx.stroke(p, with: .color(coverage[row][s] ? Color(red: 1, green: 0.8, blue: 0) : .white.opacity(0.22)), lineWidth: 9)
        }
      }
    }
  }
}

struct Scan3DView: View {
  let close: () -> Void
  @StateObject private var camera = Scan3DCamera()
  @ObservedObject private var up = Scan3DUploader.shared
  @Environment(\.scenePhase) private var phase
  @State private var mode = "objeto"
  @State private var quality = "ultra"
  @State private var list = false
  @State private var confirmFinish = false
  @State private var startedAt: Date?
  @State private var suporte = false
  @State private var bigVolume = false
  @State private var confirmDiscard = false
  private let gold = Color(red: 1, green: 0.8, blue: 0)
  private let red = Color(red: 1, green: 0.23, blue: 0.19)

  var body: some View {
    ZStack {
      Scan3DPreview(camera: camera).ignoresSafeArea()
      if !camera.scanning && !camera.centerSet { reticle }
      VStack(spacing: 0) {
        topBar
        if camera.centerSet && !camera.volume.isEmpty { HStack { Spacer(); volumeCard }.padding(.horizontal, 16).padding(.top, 10) }
        Spacer()
        hintPill.padding(.bottom, 10)
        bottomPanel
      }
    }
    .preferredColorScheme(.dark).tint(gold)
    .sheet(isPresented: $list) { Scan3DList() }
    .alert("Nota prevista \(camera.scoreText) de 10", isPresented: $confirmFinish) {
      Button("Continuar escaneando", role: .cancel) {}
      Button("Concluir assim mesmo") { finishScan() }
    } message: {
      let f = camera.ringFill.map { Int($0 * 100) }
      Text("\(camera.scoreTip).\nVoltas: baixa \(f[0])%, meio \(f[1])%, alta \(f[2])%. Volta incompleta vira buraco na malha; o ideal é passar de 70% nas três e nota 7 ou mais.")
    }
    .confirmationDialog("Descartar este scan?", isPresented: $confirmDiscard, titleVisibility: .visible) {
      Button("Descartar scan", role: .destructive) { camera.discard() }
      Button("Continuar escaneando", role: .cancel) {}
    } message: { Text("O que foi filmado até agora é apagado e nada é enviado.") }
    .task { camera.start(); up.kick() }
    .onDisappear { camera.close() }
    .onChange(of: phase) { _, p in
      if p == .background { if camera.scanning { camera.finish { _ in } }; camera.close() }
      else if p == .active { camera.start(); up.kick() }
    }
  }

  // mira no centro antes de marcar o objeto
  private var reticle: some View {
    ZStack {
      Circle().stroke(gold.opacity(0.9), lineWidth: 1.5).frame(width: 66, height: 66)
      Image(systemName: "plus").font(.system(size: 22, weight: .light)).foregroundStyle(gold)
    }.allowsHitTesting(false)
  }

  private var topBar: some View {
    HStack(spacing: 10) {
      if camera.scanning {
        Button { confirmDiscard = true } label: {
          Image(systemName: "trash").font(.system(size: 16, weight: .semibold)).foregroundStyle(red).frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
        }.accessibilityLabel("Descartar scan")
        Button { camera.setPaused(!camera.paused) } label: {
          Image(systemName: camera.paused ? "play.fill" : "pause.fill").font(.system(size: 16, weight: .semibold)).frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
        }.accessibilityLabel(camera.paused ? "Continuar gravação" : "Pausar gravação")
      } else {
        Button { camera.close { Task { @MainActor in close() } } } label: {
          Image(systemName: "chevron.left").font(.system(size: 17, weight: .semibold)).frame(width: 42, height: 42)
            .background(.ultraThinMaterial, in: Circle())
        }.accessibilityLabel("Voltar à câmera")
      }
      Spacer(minLength: 6)
      if camera.scanning {
        HStack(spacing: 6) {
          Circle().fill(camera.paused ? Color.gray : red).frame(width: 7, height: 7)
          TimelineView(.periodic(from: .now, by: 1)) { ctx in Text(camera.paused ? "pausa" : elapsed(ctx.date)).monospacedDigit() }
          Text("\(camera.distanceCM)cm").monospacedDigit().foregroundStyle(camera.distanceCM < 20 ? .orange : .white)
          Circle().fill(camera.sharpOK ? Color.green : Color.orange).frame(width: 7, height: 7).accessibilityLabel(camera.sharpOK ? "foco ok" : "focando")
          Text("★ " + camera.scoreText).monospacedDigit().foregroundStyle(scoreColor).accessibilityLabel("nota prevista \(camera.scoreText)")
        }
        .font(.footnote.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.75)
        .padding(.horizontal, 11).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
      } else {
        VStack(alignment: .trailing, spacing: 1) {
          Text("SCAN 3D").font(.system(size: 12, weight: .heavy)).foregroundStyle(gold)
          Text(camera.formatLabel).font(.caption2).foregroundStyle(.white.opacity(0.75)).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
      }
    }
    .padding(.horizontal, 16).padding(.top, 6)
  }

  private var hintPill: some View {
    VStack(spacing: 4) {
      Text(camera.hint).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).lineLimit(2)
      if !camera.ready && !camera.tracking.isEmpty {
        Text(camera.tracking).font(.caption2).foregroundStyle(.orange)
      } else if camera.scanning && !camera.scoreTip.isEmpty {
        Text(camera.scoreTip).font(.caption2.weight(.semibold)).foregroundStyle(scoreColor).multilineTextAlignment(.center).lineLimit(2)
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 9)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .padding(.horizontal, 24)
  }

  private var bottomPanel: some View {
    VStack(spacing: 14) {
      if !camera.scanning { chips }
      HStack(alignment: .center, spacing: 0) {
        // cobertura das 3 voltas + contagem
        ZStack {
          Scan3DCoverage(coverage: camera.coverage).frame(width: 80, height: 80)
          VStack(spacing: 0) {
            Text(countText).font(.system(size: 15, weight: .bold)).monospacedDigit().minimumScaleFactor(0.6).lineLimit(1)
            Text(camera.videoMode ? "quadros" : "fotos").font(.system(size: 9, weight: .medium)).foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine).accessibilityLabel("Cobertura")
        VStack(spacing: 6) {
          shutter
          if camera.centerSet && !camera.scanning {
            Button("Remarcar") { camera.setCenter(from: nil) }.font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
          } else {
            Text(shutterCaption).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.85))
          }
        }
        Button { list = true; Task { await up.refresh() } } label: {
          ZStack(alignment: .topTrailing) {
            Image(systemName: "square.stack.3d.up.fill").font(.system(size: 22)).foregroundStyle(.white)
              .frame(width: 58, height: 58).background(.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            if up.pending > 0 {
              Text("\(up.pending)").font(.caption2.bold()).foregroundStyle(.white).frame(minWidth: 18, minHeight: 18)
                .background(red, in: Circle()).offset(x: 6, y: -6)
            }
          }
        }
        .frame(maxWidth: .infinity, alignment: .trailing).accessibilityLabel("Meus scans")
      }
      if !up.status.isEmpty {
        VStack(spacing: 4) {
          ProgressView(value: up.progress).tint(gold)
          Text(up.status).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
        }
      }
    }
    .padding(.horizontal, 18).padding(.top, 14).padding(.bottom, 16)
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    .padding(.horizontal, 10).padding(.bottom, 4)
  }

  // tipo / qualidade / filmagem x fotos: chips compactos com menu (cabe numa linha no iPhone)
  private var chips: some View {
    ScrollView(.horizontal, showsIndicators: false) {
    HStack(spacing: 8) {
      Menu {
        Picker("Tipo", selection: $mode) {
          Label("Objeto", systemImage: "cube").tag("objeto")
          Label("Pessoa / busto", systemImage: "person.crop.circle").tag("pessoa")
          Label("Ambiente", systemImage: "house").tag("ambiente")
        }
      } label: { chip(icon: mode == "pessoa" ? "person.crop.circle" : mode == "ambiente" ? "house" : "cube", text: mode == "pessoa" ? "Pessoa" : mode == "ambiente" ? "Ambiente" : "Objeto") }
      Menu {
        Picker("Qualidade", selection: $quality) {
          Label("Ultra — detalhe máximo", systemImage: "sparkles").tag("ultra")
          Label("Alta — mais rápido", systemImage: "hare").tag("alta")
        }
      } label: { chip(icon: "sparkles", text: quality == "ultra" ? "Ultra" : "Alta") }
      Menu {
        Picker("Captura", selection: Binding(get: { camera.videoMode }, set: { v in camera.videoMode = v; camera.start() })) {
          Label("Filmagem 4K (recomendado)", systemImage: "video").tag(true)
          Label("Fotos automáticas", systemImage: "camera").tag(false)
        }
      } label: { chip(icon: camera.videoMode ? "video" : "camera", text: camera.videoMode ? "4K" : "Fotos") }
      Menu {
        Picker("Apoio", selection: $suporte) {
          Label("Na mesa", systemImage: "rectangle.portrait.bottomhalf.filled").tag(false)
          Label("Num suporte menor que ele (base limpa)", systemImage: "cup.and.saucer").tag(true)
        }
      } label: { chip(icon: suporte ? "cup.and.saucer" : "rectangle.portrait.bottomhalf.filled", text: suporte ? "Suporte" : "Mesa") }
    }
    .padding(.horizontal, 2)
    }
    .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
  }

  private func chip(icon: String, text: String) -> some View {
    HStack(spacing: 5) {
      Image(systemName: icon).font(.caption)
      Text(text).lineLimit(1)
      Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).opacity(0.7)
    }
    .font(.footnote.weight(.semibold)).foregroundStyle(.white)
    .padding(.horizontal, 12).padding(.vertical, 8)
    .background(.white.opacity(0.12), in: Capsule())
    .fixedSize()
  }

  private var shutter: some View {
    Button(action: shutterTap) {
      ZStack {
        Circle().stroke(.white, lineWidth: 4).frame(width: 76, height: 76)
        if camera.scanning {
          RoundedRectangle(cornerRadius: 8, style: .continuous).fill(red).frame(width: 30, height: 30)
        } else if camera.centerSet {
          Circle().fill(red).frame(width: 62, height: 62)
        } else {
          Circle().fill(gold).frame(width: 62, height: 62)
          Image(systemName: "scope").font(.system(size: 26, weight: .semibold)).foregroundStyle(.black)
        }
      }
      .frame(width: 84, height: 84).contentShape(Circle())
    }
    .buttonStyle(.plain)
    .disabled(!camera.ready && !camera.scanning).opacity(!camera.ready && !camera.scanning ? 0.45 : 1)
    .accessibilityLabel(camera.scanning ? "Concluir scan" : camera.centerSet ? "Iniciar scan" : "Marcar objeto")
  }

  private var volumeCard: some View {
    ZStack(alignment: .bottomLeading) {
      Scan3DVolume(points: camera.volume).frame(width: bigVolume ? 220 : 96, height: bigVolume ? 220 : 96)
      Text("volume captado").font(.system(size: 9, weight: .semibold)).foregroundStyle(.white.opacity(0.7)).padding(7)
    }
    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .contentShape(RoundedRectangle(cornerRadius: 18))
    .onTapGesture { withAnimation(.spring(duration: 0.3)) { bigVolume.toggle() } }
    .accessibilityLabel("Prévia do volume captado; toque pra ampliar")
  }
  private var scoreColor: Color { camera.score >= 8 ? .green : camera.score >= 6 ? gold : .orange }
  private var shutterCaption: String { camera.scanning ? "Concluir" : camera.centerSet ? "Iniciar" : "Marcar objeto" }
  private var countText: String {
    let n = camera.shots
    return camera.videoMode && n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)"
  }
  private func elapsed(_ now: Date) -> String {
    let s = Int(now.timeIntervalSince(startedAt ?? now)); return String(format: "%d:%02d", s / 60, s % 60)
  }
  private func shutterTap() {
    if camera.scanning {
      if camera.ringFill.contains(where: { $0 < 0.66 }) || camera.score < 7 { confirmFinish = true } else { finishScan() }
    } else if !camera.centerSet {
      camera.setCenter(from: nil)
    } else {
      camera.mode = mode; camera.quality = quality; camera.suporte = suporte; startedAt = Date(); camera.begin()
    }
  }
}

extension Scan3DView {
  func finishScan() { camera.finish { dir in Task { @MainActor in if dir != nil { Scan3DUploader.shared.kick() } } } }
}

// ------------------------------------------------------------------ Meus scans
struct Scan3DList: View {
  @ObservedObject private var up = Scan3DUploader.shared
  @State private var preview: URL?
  @State private var loading: String?
  var body: some View {
    NavigationStack {
      ScrollView {
        LazyVStack(spacing: 12) {
          HStack(spacing: 10) {
            Image(systemName: up.pcOnline ? "bolt.fill" : "moon.zzz.fill").foregroundStyle(up.pcOnline ? .green : .orange)
            Text(up.pcOnline ? "PC ligado: processando a fila" : "PC desligado: os scans esperam na fila").font(.subheadline.weight(.semibold))
            Spacer(minLength: 0)
          }
          .padding(14).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          if up.pending > 0 {
            HStack(spacing: 10) {
              ProgressView(value: up.progress).frame(width: 60)
              Text("\(up.pending) scan(s) subindo do iPhone. Deixe o app aberto.").font(.footnote).foregroundStyle(.secondary)
              Spacer(minLength: 0)
            }
            .padding(14).background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
          }
          ForEach(up.jobs.indices, id: \.self) { i in Scan3DCard(job: up.jobs[i], loading: $loading, preview: $preview) }
          if up.jobs.isEmpty {
            VStack(spacing: 8) {
              Image(systemName: "cube.transparent").font(.system(size: 40)).foregroundStyle(.secondary)
              Text("Nenhum scan ainda").font(.headline)
              Text("Marque o objeto, toque em iniciar e ande em volta dele.").font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(.top, 60)
          }
        }
        .padding(16)
      }
      .navigationTitle("Meus scans").navigationBarTitleDisplayMode(.inline)
      .refreshable { await up.refresh() }
      .quickLookPreview($preview)
      .task { while !Task.isCancelled { await up.refresh(); try? await Task.sleep(nanoseconds: 6_000_000_000) } }
    }
    .preferredColorScheme(.dark).tint(Color(red: 1, green: 0.8, blue: 0))
  }
}

struct Scan3DCard: View {
  let job: [String: Any]
  @Binding var loading: String?
  @Binding var preview: URL?
  @ObservedObject private var up = Scan3DUploader.shared
  @State private var confirmDelete = false
  private let gold = Color(red: 1, green: 0.8, blue: 0)
  private var id: String { job["id"] as? String ?? "" }
  private var status: String { up.localPaused.contains(id) ? "pausado" : (job["status"] as? String ?? "") }
  private var results: [String] { job["results"] as? [String] ?? [] }
  private var stats: [String: Any] { job["stats"] as? [String: Any] ?? [:] }
  private var hasIA: Bool { results.contains("ia_model.usdz") || results.contains("ia_preview.glb") }
  private func url(_ n: String) -> URL { URL(string: "/r/\(id)/\(n)", relativeTo: Scan3DAPI.origin)!.absoluteURL }
  private var mostruario: URL { URL(string: "/p/\(id)", relativeTo: Scan3DAPI.origin)!.absoluteURL }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .top, spacing: 12) {
        thumb
        VStack(alignment: .leading, spacing: 5) {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(job["title"] as? String ?? "Scan").font(.headline).lineLimit(1)
            Spacer(minLength: 4)
            pill
          }
          Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
          if status == "processando" {
            ProgressView(value: Double(job["pct"] as? Int ?? 0) / 100).tint(gold)
          }
        }
      }
      if status == "pronto" {
        HStack(spacing: 8) {
          Button {
            Task { loading = id; preview = await Scan3DUploader.shared.download(job: id, name: hasIA ? "ia_model.usdz" : "model.usdz"); loading = nil }
          } label: {
            HStack(spacing: 6) {
              if loading == id { ProgressView().tint(.black) } else { Image(systemName: "arkit") }
              Text(loading == id ? "Abrindo…" : "Ver em 3D / AR").lineLimit(1)
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(.black)
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(gold, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
          }
          .buttonStyle(.plain).disabled(loading != nil)
          Link(destination: mostruario) { iconButton("safari") }.accessibilityLabel("Abrir mostruário")
          Menu { downloads } label: { iconButton("square.and.arrow.down") }.accessibilityLabel("Baixar arquivos")
          Button { confirmDelete = true } label: { iconButton("trash") }.accessibilityLabel("Excluir scan")
        }
      } else {
        HStack(spacing: 8) {
          if ["pendente", "processando", "enviando", "erro"].contains(status) {
            actionButton(status == "erro" ? "Tentar de novo" : "Pausar", icon: status == "erro" ? "arrow.clockwise" : "pause.fill") {
              if status == "erro" { await up.resume(id) } else { await up.pause(id) }
            }
          }
          if status == "pausado" { actionButton("Continuar", icon: "play.fill") { await up.resume(id) } }
          Button { confirmDelete = true } label: { iconButton("trash") }.accessibilityLabel("Excluir scan")
        }
      }
    }
    .confirmationDialog("Excluir este scan?", isPresented: $confirmDelete, titleVisibility: .visible) {
      Button("Excluir", role: .destructive) { Task { await up.delete(id) } }
      Button("Cancelar", role: .cancel) {}
    } message: { Text("Apaga da fila, do PC e da galeria. Não dá pra desfazer.") }
    .padding(14)
    .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
  }

  @ViewBuilder private var downloads: some View {
    if hasIA {
      Section("Forma limpa (IA)") {
        if results.contains("ia_model.stl") { ShareLink("STL p/ imprimir (mm)", item: url("ia_model.stl")) }
        if results.contains("ia_model_full.zip") { ShareLink("OBJ + textura", item: url("ia_model_full.zip")) }
        if results.contains("ia_model.glb") { ShareLink("GLB", item: url("ia_model.glb")) }
      }
    }
    Section(hasIA ? "Fiel ao scan" : "Arquivos") {
      if results.contains("model.stl") { ShareLink("STL p/ imprimir (mm)", item: url("model.stl")) }
      if results.contains("model_full.zip") { ShareLink("OBJ + textura", item: url("model_full.zip")) }
      if results.contains("model.glb") { ShareLink("GLB", item: url("model.glb")) }
    }
    Section { ShareLink("Link do mostruário", item: mostruario) }
  }

  private func actionButton(_ title: String, icon: String, _ action: @escaping () async -> Void) -> some View {
    Button { Task { await action() } } label: {
      Label(title, systemImage: icon).font(.subheadline.weight(.semibold)).lineLimit(1).foregroundStyle(.white)
        .frame(maxWidth: .infinity).frame(height: 44)
        .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }.buttonStyle(.plain)
  }

  private func iconButton(_ name: String) -> some View {
    Image(systemName: name).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
      .frame(width: 48, height: 44).background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var thumb: some View {
    Group {
      if results.contains("thumb.jpg") {
        AsyncImage(url: url("thumb.jpg")) { img in img.resizable().scaledToFill() } placeholder: { Color.white.opacity(0.08) }
      } else {
        ZStack {
          Color.white.opacity(0.08)
          Image(systemName: status == "erro" ? "exclamationmark.triangle" : "cube.transparent").font(.system(size: 22)).foregroundStyle(.secondary)
        }
      }
    }
    .frame(width: 64, height: 64).clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
  }

  private var pill: some View {
    let (t, c): (String, Color) = {
      switch status {
      case "pronto": return ("pronto", .green)
      case "processando": return ("\(job["pct"] as? Int ?? 0)%", .yellow)
      case "pendente": return ("na fila", .orange)
      case "enviando": return ("enviando", .blue)
      case "pausado": return ("pausado", .purple)
      case "erro": return ("erro", .red)
      default: return (status, .secondary)
      }
    }()
    return Text(t).font(.caption.weight(.bold)).foregroundStyle(c)
      .padding(.horizontal, 8).padding(.vertical, 3).background(c.opacity(0.15), in: Capsule()).fixedSize()
  }

  private var subtitle: String {
    switch status {
    case "pronto":
      if let s = (hasIA ? stats["ia_size_cm"] : nil) as? String ?? stats["size_cm"] as? String { return "Tamanho real: \(s)" }
      return "Malha pronta"
    case "pendente": return "Na fila: o PC processa assim que estiver ligado"
    case "pausado": return up.localPaused.contains(id) ? "Envio pausado neste iPhone" : "Pausado: toque em Continuar (retoma de onde parou)"
    default: return job["stage"] as? String ?? ""
    }
  }
}
