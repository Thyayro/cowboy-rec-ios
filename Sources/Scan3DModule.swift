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

  private func publish(_ f: @escaping @Sendable () -> Void) { DispatchQueue.main.async(execute: f) }

  func start() {
    Task {
      guard await AVCaptureDevice.requestAccess(for: .video), ARWorldTrackingConfiguration.isSupported else {
        publish { self.hint = "Libere a câmera nos Ajustes" }; return
      }
      queue.async {
        let cfg = ARWorldTrackingConfiguration()
        // foto em alta resolução sob demanda (iOS 16): o formato recomendado pra isso; senão 4K; senão o maior
        if let f = ARWorldTrackingConfiguration.recommendedVideoFormatForHighResolutionFrameCapturing { cfg.videoFormat = f; self.highRes = true }
        else if let f = ARWorldTrackingConfiguration.recommendedVideoFormatFor4KResolution { cfg.videoFormat = f }
        cfg.planeDetection = [.horizontal]; cfg.videoHDRAllowed = false; cfg.isAutoFocusEnabled = true
        self.session.delegate = self; self.session.delegateQueue = self.queue
        self.session.run(cfg, options: [.resetTracking, .removeExistingAnchors])
        let r = cfg.videoFormat.imageResolution
        self.publish { self.formatLabel = "\(Int(r.width))×\(Int(r.height))\(self.highRes ? " + foto alta" : "") · \(cfg.videoFormat.framesPerSecond) qps" }
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
      self.center = c
      // chão = plano horizontal logo abaixo do centro (objeto em cima da mesa/piso)
      if let f = self.session.currentFrame {
        let ys = f.anchors.compactMap { $0 as? ARPlaneAnchor }.filter { $0.alignment == .horizontal }.map { $0.transform.columns.3.y }.filter { $0 <= c.y + 0.02 }
        self.floorY = ys.max()
      }
      self.publish { self.centerSet = true; self.onCenter?(c); self.hint = "Centro marcado. INICIAR e ande em volta devagar, a 20–35 cm, com o objeto grande na tela" }
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
      self.dir = d; self.frames = []; self.lastShot = nil
      self.lockCamera()
      self.publish {
        self.scanning = true; self.shots = 0; self.coverage = Array(repeating: Array(repeating: false, count: 36), count: 3)
        self.hint = "Ande em volta, devagar. 3 voltas: baixa, meio, alta"
      }
    }
  }

  func finish(_ done: @escaping @Sendable (URL?) -> Void) {
    queue.async {
      guard self.scanning, let d = self.dir else { done(nil); return }
      self.writePoses(final: true)
      self.unlockCamera()
      let n = self.frames.count
      self.dir = nil
      self.publish { self.scanning = false; self.hint = n >= 20 ? "Scan salvo: enviando pra fila" : "Poucas fotos (\(n)): scan descartado" }
      if n < 20 { try? FileManager.default.removeItem(at: d); done(nil); return }
      let meta: [String: Any] = ["title": self.title.isEmpty ? "Scan \(Self.stamp())" : self.title, "mode": self.mode, "quality": self.quality]
      try? JSONSerialization.data(withJSONObject: meta).write(to: d.appendingPathComponent("meta.json"), options: .atomic)
      done(d)
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
        if dev.isExposureModeSupported(.locked) { dev.exposureMode = .locked }
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
    guard scanning, ok, !busy, let c = center else { return }
    let pos = simd_make_float3(m.columns.3)
    let fromC = pos - c, dist = simd_length(fromC)
    guard dist > 0.05 else { return }
    let dirC = fromC / dist
    if t - lastUI < 0.02 { let cm = Int(dist * 100); publish { self.distanceCM = cm } }
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
    if let floorY { doc["floor_y"] = floorY }
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
  private var running = false
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
        var tries = 0
        while true {
          do { try await upload(d); break } catch {
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
    let names = try FileManager.default.contentsOfDirectory(atPath: d.path).filter { $0.hasSuffix(".jpg") || $0 == "poses.json" }.sorted()
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
      if c0 == 404 { meta["job"] = nil; try JSONSerialization.data(withJSONObject: meta).write(to: metaURL, options: .atomic); throw Scan3DError("job sumiu da fila, recriando") }
      var off = ((o0 as? [String: Any])?["got"] as? Int) ?? 0
      let h = try FileHandle(forReadingFrom: file); defer { try? h.close() }
      while off < sizes[i] {
        try h.seek(toOffset: UInt64(off))
        let chunk = h.readData(ofLength: 8 << 20)
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
  private let gold = Color(red: 1, green: 0.8, blue: 0)

  var body: some View {
    ZStack {
      Scan3DPreview(camera: camera).ignoresSafeArea()
      if !camera.scanning {
        Image(systemName: "plus.viewfinder").font(.system(size: 44, weight: .light)).foregroundStyle(gold).allowsHitTesting(false)
      }
      VStack(spacing: 10) {
        HStack {
          Button { camera.close { Task { @MainActor in close() } } } label: { Label("Câmera", systemImage: "chevron.left") }.disabled(camera.scanning)
          Spacer()
          VStack(alignment: .trailing, spacing: 2) {
            Text("SCAN 3D").font(.system(size: 13, weight: .heavy)).foregroundStyle(gold)
            Text("\(camera.formatLabel) · \(camera.tracking)").font(.caption2).foregroundStyle(.white.opacity(0.8))
          }
        }.padding(.horizontal, 16).padding(.vertical, 10).background(.black.opacity(0.55))
        Spacer()
        Text(camera.hint).font(.footnote.weight(.semibold)).multilineTextAlignment(.center).padding(.horizontal, 14).padding(.vertical, 8)
          .background(.black.opacity(0.7), in: Capsule()).padding(.horizontal, 20)
        HStack(alignment: .bottom) {
          VStack(spacing: 6) {
            ZStack {
              Scan3DCoverage(coverage: camera.coverage).frame(width: 118, height: 118)
              Text("\(camera.shots)").font(.system(size: 22, weight: .bold)).monospacedDigit()
            }
            if camera.scanning {
              HStack(spacing: 6) {
                Circle().fill(camera.sharpOK ? Color.green : Color.orange).frame(width: 9, height: 9)
                Text(camera.distanceCM < 20 ? "\(camera.distanceCM) cm · muito perto" : "\(camera.distanceCM) cm")
                  .font(.caption.weight(.semibold)).monospacedDigit().foregroundStyle(camera.distanceCM < 20 ? .orange : .white)
              }.padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.6), in: Capsule())
            }
          }
          Spacer()
          VStack(spacing: 8) {
            if camera.scanning {
              Button { if camera.ringFill.contains(where: { $0 < 0.66 }) { confirmFinish = true } else { finishScan() } } label: {
                Text("CONCLUIR").font(.headline).frame(width: 150, height: 54).background(Color(red: 1, green: 0.23, blue: 0.19), in: Capsule())
              }.foregroundStyle(.white)
            } else if !camera.centerSet {
              Button { camera.setCenter(from: nil) } label: {
                Text("MARCAR OBJETO").font(.headline).frame(width: 170, height: 54).background(gold, in: Capsule())
              }.foregroundStyle(.black).disabled(!camera.ready)
            } else {
              Button { camera.mode = mode; camera.quality = quality; camera.begin() } label: {
                Text("INICIAR").font(.headline).frame(width: 150, height: 54).background(gold, in: Capsule())
              }.foregroundStyle(.black).disabled(!camera.ready)
              Button("remarcar objeto") { camera.setCenter(from: nil) }.font(.caption)
            }
          }
        }.padding(.horizontal, 18)
        if !camera.scanning {
          HStack(spacing: 8) {
            Picker("", selection: $mode) { Text("Objeto").tag("objeto"); Text("Pessoa").tag("pessoa"); Text("Ambiente").tag("ambiente") }.pickerStyle(.segmented)
            Picker("", selection: $quality) { Text("Ultra").tag("ultra"); Text("Alta").tag("alta") }.pickerStyle(.segmented).frame(width: 120)
          }.padding(.horizontal, 16)
          Button { list = true; Task { await up.refresh() } } label: {
            HStack { Image(systemName: "cube.transparent"); Text("Meus scans"); if up.pending > 0 { Text("· \(up.pending) a enviar") } }
              .font(.subheadline.weight(.semibold)).padding(.horizontal, 16).padding(.vertical, 8).background(.black.opacity(0.6), in: Capsule())
          }
        }
        if !up.status.isEmpty {
          VStack(spacing: 4) {
            ProgressView(value: up.progress).tint(gold)
            Text(up.status).font(.caption2)
          }.padding(.horizontal, 20)
        }
      }.padding(.bottom, 18)
    }
    .preferredColorScheme(.dark).tint(gold)
    .sheet(isPresented: $list) { Scan3DList() }
    .alert("Cobertura incompleta", isPresented: $confirmFinish) {
      Button("Continuar escaneando", role: .cancel) {}
      Button("Concluir assim mesmo") { finishScan() }
    } message: {
      let f = camera.ringFill.map { Int($0 * 100) }
      Text("Voltas: baixa \(f[0])%, meio \(f[1])%, alta \(f[2])%. Cada volta incompleta vira buraco na malha. O ideal é passar de 70% nas três.")
    }
    .task { camera.start(); up.kick() }
    .onDisappear { camera.close() }
    .onChange(of: phase) { _, p in
      if p == .background { if camera.scanning { camera.finish { _ in } }; camera.close() }
      else if p == .active { camera.start(); up.kick() }
    }
  }
}

extension Scan3DView {
  func finishScan() { camera.finish { dir in Task { @MainActor in if dir != nil { Scan3DUploader.shared.kick() } } } }
}

struct Scan3DList: View {
  @ObservedObject private var up = Scan3DUploader.shared
  @State private var preview: URL?
  @State private var loading: String?
  var body: some View {
    NavigationStack {
      List {
        Section {
          Label(up.pcOnline ? "PC ligado: processando a fila" : "PC desligado: os scans esperam na fila", systemImage: up.pcOnline ? "bolt.fill" : "moon.zzz")
            .foregroundStyle(up.pcOnline ? .green : .orange)
          if up.pending > 0 { Text("\(up.pending) scan(s) no iPhone aguardando envio. Mantenha o app aberto até subir.").font(.caption) }
        }
        ForEach(up.jobs.indices, id: \.self) { i in
          let j = up.jobs[i]
          let id = j["id"] as? String ?? "", st = j["status"] as? String ?? ""
          let results = j["results"] as? [String] ?? []
          VStack(alignment: .leading, spacing: 4) {
            HStack { Text(j["title"] as? String ?? "Scan").font(.headline); Spacer(); Text(st).font(.caption.weight(.bold)).foregroundStyle(st == "pronto" ? .green : st == "erro" ? .red : .yellow) }
            Text(j["stage"] as? String ?? "").font(.caption).foregroundStyle(.secondary)
            if st == "processando" { ProgressView(value: Double(j["pct"] as? Int ?? 0) / 100) }
            if let s = j["stats"] as? [String: Any], let dims = s["size_cm"] as? String { Text("Tamanho real: \(dims)").font(.caption) }
            if st == "pronto" {
              HStack(spacing: 14) {
                if results.contains("model.usdz") {
                  Button(loading == id ? "baixando…" : "Ver em 3D/AR") { Task { loading = id; preview = await up.download(job: id, name: "model.usdz"); loading = nil } }
                }
                ForEach(["model.stl", "model_full.zip", "model.glb"].filter { results.contains($0) }, id: \.self) { n in
                  if let u = URL(string: "/r/\(id)/\(n)", relativeTo: Scan3DAPI.origin)?.absoluteURL { ShareLink(n.replacingOccurrences(of: "model_full.zip", with: "OBJ"), item: u) }
                }
              }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
            }
          }.padding(.vertical, 4)
        }
      }
      .navigationTitle("Scans 3D").navigationBarTitleDisplayMode(.inline)
      .refreshable { await up.refresh() }
      .quickLookPreview($preview)
      .task { while !Task.isCancelled { await up.refresh(); try? await Task.sleep(nanoseconds: 6_000_000_000) } }
    }.preferredColorScheme(.dark)
  }
}
