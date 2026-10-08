import CoreImage
import Metal
import MetalKit
import QuartzCore
import SwiftUI
import Vision

// Preview drawn from the SAME stabilized frames that go to the file (what you see is what is recorded), with the
// display LUT (Apple Log/HLG -> Rec.709 + look) applied on the GPU. No color management: code values in, code values out,
// exactly like the .cube the cloud uses.
final class PreviewRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
  let device: MTLDevice?
  private let commandQueue: MTLCommandQueue?
  let context: CIContext
  private let lock = NSLock()
  private var pending: CVPixelBuffer?
  private var pendingPTS: Double?
  private var frozen = false
  private var dropFrames = 0
  // zoom sem atraso: a estabilização entrega o quadro ~0,3–1 s depois; o zoom da tela usa o zoom de AGORA sobre o quadro
  // atrasado (escala = zoom agora ÷ zoom no instante em que o quadro foi captado). O arquivo não muda.
  var zoomNow: (() -> Double?)?
  private var zoomHistory: [(Double, Double)] = []
  // ZOOM PERFEITO: enquanto o zoom se mexe, a tela mostra a saída SEM estabilização (tempo real, quadro inteiro, sem borda
  // inventada), no mesmo enquadramento do estabilizado (corte do estabilizador medido sozinho pelo Vision); parou e o quadro
  // estabilizado alcançou -> volta pra ele. O arquivo é sempre o estabilizado.
  private var fastBuffer: CVPixelBuffer?
  private var fastPTS: Double?
  private var lastZoomMove = 0.0
  // PRÉVIA SEM ATRASO (padrão, como a câmera do iPhone): a tela mostra a saída em tempo real com estabilização leve, no
  // enquadramento do arquivo (corte medido); o arquivo continua com a estabilização Extrema. Zoom e troca de lente na hora.
  var lightPreview = UserDefaults.standard.object(forKey: "lightPreview") as? Bool ?? true
  private var fastFresh = false
  private let eis = PreviewEIS()
  private var fastCorr = (0.0, 0.0)
  // ZOOM DA TELA PELO QUADRO (0.7.3) — prévia ESTABILIZADA ("Prévia sem atraso" desligada): o quadro estabilizado chega
  // atrasado e a tela o amplia pro zoom de agora. Antes a ampliação era zoom PEDIDO agora ÷ zoom pedido no instante do quadro,
  // mas o sensor aplica o zoom alguns quadros depois do pedido: no zoom in a tela ficava vários % fora do certo e, quando o
  // quadro estabilizado alcançava, "voltava" (o vai-e-volta no freio; o zoom out não amplia, por isso ficava certo — 08/10,
  // teste v3: o iPhone do operador estava com a prévia estabilizada). Agora: distância focal REAL de cada quadro (matriz
  // intrínseca que o iPhone anexa a cada quadro da saída rápida, já com o zoom aplicado) -> ampliação = fx do quadro mais novo
  // ÷ fx do quadro estabilizado (mesmo horário de captura). Parou o zoom: o fx do mais novo não muda mais, então o tamanho na
  // tela não muda mais — o quadro estabilizado que alcança só troca ampliação por imagem real, no mesmo tamanho.
  // Sem intrínseca, ou se ela não acompanhar o zoom (conferido sozinho em repouso), volta pra conta antiga.
  private var fxHist: [(Double, Double)] = []
  private var fxLatest: Double?
  private var fxValid = true
  private var fxChecked = false
  private var fxRest: (z: Double, fx: Double, since: Double, done: Bool)?
  private var fxSamples: [(Double, Double)] = []
  var onFxCheck: ((String) -> Void)?
  private var shownK: [(Double, Double)] = []   // ampliação usada na tela por quadro estabilizado (medição do estacionar)
  var lensMatch: LensMatch?
  var aligner: SwitchAligner?
  // NUNCA fila de medições: cada medição segura um quadro da câmera; acumuladas, os quadros acabam e a câmera para (0.6.1)
  private var statsBusy = false
  private var stabBusy = false
  private var nextStab = 0.0
  private let statsQueue = DispatchQueue(label: "cowboy.preview.stats", qos: .utility)
  private let stabQueue = DispatchQueue(label: "cowboy.preview.stab", qos: .utility)
  var blackBorder: (() -> Void)?
  private var nextStats = 0.0
  private var fastAt = 0.0
  private var crop = 1.06
  private var shownCrop = 0.0          // corte usado na tela: segue a medida devagar (sem "ajuste" depois do zoom)
  private var shownCropAt = 0.0
  private var cropSamples: [Double] = []
  // CORTE DA TELA FIXO (medido 08/10): recalcular o corte a cada parada do zoom fazia a imagem da tela crescer/encolher
  // sozinha por 1–2 s ("estacionar"). Agora: 5 medidas ao abrir a câmera -> mediana -> fixo até trocar câmera/formato.
  private var cropFrozen = false
  var displayCrop: Double { lock.lock(); defer { lock.unlock() }; return shownCrop }
  var displayShake: (Double, Double) { lock.lock(); defer { lock.unlock() }; return fastCorr }
  var fxInfo: String { lock.lock(); defer { lock.unlock() }; return fxLatest.map { String(format: "fx%.1f%@", $0, fxValid ? "" : "!") } ?? "fx-" }
  func displayK(at t: Double) -> Double? {
    lock.lock(); defer { lock.unlock() }
    return shownK.last(where: { abs($0.0 - t) < 0.004 })?.1
  }
  private func noteFx(_ fx: Double, pts: Double) {
    let z = zoomNow?() ?? 0
    var report: String?
    lock.lock()
    if let last = fxHist.last, pts <= last.0 { fxHist.removeAll() }   // relógio voltou (câmera reconfigurada)
    fxHist.append((pts, fx)); if fxHist.count > 900 { fxHist.removeFirst(fxHist.count - 900) }
    fxLatest = fx
    // conferência: em repouso (zoom e fx parados 0,5 s) guarda (zoom, fx); dois repousos com zoom ≥30% diferente têm que ter fx
    // na mesma proporção (±12% = diferença de campo entre lentes); senão a intrínseca não acompanha o zoom e sai do jogo
    if z > 0 {
      if let r = fxRest, abs(r.z - z) < 1e-4, abs(r.fx - fx) < 1e-3 * fx {
        if !r.done && pts - r.since > 0.5 {
          fxRest = (r.z, r.fx, r.since, true)
          for q in fxSamples where abs(log(z / q.0)) > log(1.3) {
            let err = abs(log(fx / q.1) - log(z / q.0))
            if err > log(1.12) {
              if fxValid { fxValid = false; report = String(format: "FALHOU z%.3f fx%.1f × z%.3f fx%.1f — conta antiga", q.0, q.1, z, fx) }
              break
            } else if !fxChecked { fxChecked = true; report = String(format: "ok z%.3f fx%.1f × z%.3f fx%.1f (erro %.1f%%)", q.0, q.1, z, fx, (exp(err) - 1) * 100) }
          }
          fxSamples.append((z, fx)); if fxSamples.count > 8 { fxSamples.removeFirst() }
        }
      } else { fxRest = (z, fx, pts, false) }
    }
    lock.unlock()
    if let report { onFxCheck?(report) }
  }
  // fx no instante de captura t (lock segurado). "exato" = veio do quadro GÊMEO da saída rápida (mesmo horário de captura) ou
  // os vizinhos têm o mesmo fx (zoom parado). Gêmeo descartado com o zoom andando: interpolar erra até ~1,6% bem na parada
  // (simulado 08/10) — quem chama segura o quadro anterior em vez de chutar.
  private func fxAt(_ t: Double) -> (fx: Double, exact: Bool)? {
    guard fxValid, let first = fxHist.first, let last = fxHist.last, t >= first.0 - 0.02, t <= last.0 + 0.02 else { return nil }
    var lo = 0, hi = fxHist.count - 1
    while hi - lo > 1 { let mid = (lo + hi) / 2; if fxHist[mid].0 <= t { lo = mid } else { hi = mid } }
    let a = fxHist[lo], b = fxHist[hi]
    if abs(a.0 - t) < 0.004 { return (a.1, true) }
    if abs(b.0 - t) < 0.004 { return (b.1, true) }
    if t <= a.0 { return (a.1, false) }
    if t >= b.0 { return (b.1, false) }
    guard b.0 - a.0 < 0.15 else { return nil }
    return (a.1 * pow(b.1 / a.1, (t - a.0) / (b.0 - a.0)), abs(b.1 / a.1 - 1) < 0.0005)
  }
  private var lastStabDraw = 0.0   // só a thread da tela
  private var calibFast: (pts: Double, image: CGImage)?
  private var calibBusy = false
  private var nextCalib = 0.0
  private let calibQueue = DispatchQueue(label: "cowboy.preview.calib", qos: .utility)
  var onCrop: ((Double) -> Void)?
  var hasFast: Bool { lock.lock(); defer { lock.unlock() }; return fastBuffer != nil }
  private var cube: Data?
  private var cubeSize = 33
  private var orientation: CGImagePropertyOrientation = .right
  private var mirrored = false
  private(set) var frames = 0

  override init() {
    device = MTLCreateSystemDefaultDevice()
    commandQueue = device?.makeCommandQueue()
    let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
    if let device { context = CIContext(mtlDevice: device, options: options) } else { context = CIContext(options: options) }
    super.init()
  }
  func push(_ buffer: CVPixelBuffer, pts: Double? = nil) {
    lock.lock()
    if frozen { lock.unlock(); return }
    if dropFrames > 0 { dropFrames -= 1; lock.unlock(); return }
    pending = buffer; pendingPTS = pts
    let nowS = CACurrentMediaTime()
    let wantStab = aligner != nil && !stabBusy && nowS >= nextStab && pts != nil
    if wantStab { stabBusy = true; nextStab = nowS + 0.03 }
    var match: (pts: Double, image: CGImage)?
    if let cf = calibFast, let pts {
      if abs(cf.pts - pts) < 0.004 { match = cf; calibFast = nil } else if pts > cf.pts + 0.1 { calibFast = nil; calibBusy = false }
    }
    lock.unlock()
    if let match { calibQueue.async { self.register(stabilized: buffer, fast: match.image) } }
    if wantStab, let pts, let al = aligner {
      stabQueue.async {
        if let r = self.sample(buffer, cube: false) { al.feed("stab", t: pts, luma: r.luma) }
        self.lock.lock(); self.stabBusy = false; self.lock.unlock()
      }
    }
  }
  func pushFast(_ buffer: CVPixelBuffer, pts: Double, fx: Double? = nil) {
    // quadro sem intrínseca (a ultra pode vir sem): nada de fx velho valendo — essa parte usa a conta antiga
    if let fx { noteFx(fx, pts: pts) } else { lock.lock(); fxLatest = nil; lock.unlock() }
    // estabilização própria da tela (só deslocamento; cega ao zoom) — calculada aqui, antes de mostrar
    lock.lock(); let fr = frozen; eis.margin = max(0.01, min(0.035, (crop - 1) / 2 - 0.006)); lock.unlock()
    if fr { return }
    // durante o zoom a imagem muda de tamanho: a medida de tremor erraria e depois "voltaria" — segura enquanto o zoom anda
    lock.lock(); let zooming = CACurrentMediaTime() - lastZoomMove < 0.2; lock.unlock()
    let corr = lightPreview ? eis.process(buffer, t: pts, hold: zooming) : (0, 0)
    lock.lock()
    if frozen { lock.unlock(); return }
    fastBuffer = buffer; fastPTS = pts; fastFresh = true; fastCorr = corr
    let now = CACurrentMediaTime()
    fastAt = now
    let wantStats = now >= nextStats && !statsBusy
    if wantStats { nextStats = now + 0.03; statsBusy = true }
    let calm = now - lastZoomMove > 1.2   // zoom parado há um tempo: dá pra medir o corte
    let go = calm && !calibBusy && now >= nextCalib && !cropFrozen
    if go { calibBusy = true; nextCalib = now + 0.5 }
    lock.unlock()
    if wantStats {
      let lm = lensMatch, al = aligner
      statsQueue.async {
        if let r = self.sample(buffer, cube: true) {
          if let lm, lm.enabled { lm.observe(r.stats, at: pts) }
          al?.feed("fast", t: pts, luma: r.luma)
        }
        self.lock.lock(); self.statsBusy = false; self.lock.unlock()
      }
    }
    if go { calibQueue.async { if let img = self.small(buffer) { self.lock.lock(); self.calibFast = (pts, img); self.lock.unlock() } else { self.lock.lock(); self.calibBusy = false; self.lock.unlock() } } }
  }
  // quadro pequeno 96×54 (orientação do sensor): cor/luz (depois do LUT, antes da correção) + luma pro alinhamento
  private func sample(_ buffer: CVPixelBuffer, cube useCube: Bool) -> (stats: FrameStats, luma: [Float])? {
    var img = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    let W = SwitchAligner.w, H = Int((Double(W) * img.extent.height / max(1, img.extent.width)).rounded())
    guard H > 4 else { return nil }
    img = img.transformed(by: CGAffineTransform(scaleX: CGFloat(W) / img.extent.width, y: CGFloat(H) / img.extent.height))
    img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    if useCube { let (cube, size) = currentCube(); img = Self.filtered(img, cube: cube, size: size) }
    // via CGImage: linha 0 = TOPO do quadro (mesma convenção do shader e do alinhamento)
    guard let cg = context.createCGImage(img, from: CGRect(x: 0, y: 0, width: W, height: H), format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB()),
      let data = cg.dataProvider?.data, let base = CFDataGetBytePtr(data), cg.bitsPerPixel == 32 else { return nil }
    var bytes = [UInt8](repeating: 0, count: W * H * 4)
    for y in 0..<min(H, cg.height) { for x in 0..<min(W, cg.width) { let o = y * cg.bytesPerRow + x * 4, d = (y * W + x) * 4; bytes[d] = base[o]; bytes[d + 1] = base[o + 1]; bytes[d + 2] = base[o + 2]; bytes[d + 3] = base[o + 3] } }
    var sum = SIMD3<Float>(0, 0, 0); var lum = [Float](); lum.reserveCapacity(W * H)
    for i in stride(from: 0, to: bytes.count, by: 4) {
      let c = SIMD3<Float>(Float(bytes[i]), Float(bytes[i + 1]), Float(bytes[i + 2])) / 255
      sum += c; lum.append(c.x * 0.2126 + c.y * 0.7152 + c.z * 0.0722)
    }
    let luma = lum
    // detector de BORDA PRETA no quadro em tempo real (estabilizador entortando a imagem durante o zoom?)
    var ring: Float = 0, rn: Float = 0
    for y in 0..<H { for x in 0..<W where x < 2 || y < 2 || x >= W - 2 || y >= H - 2 { let i = (y * W + x) * 4; ring += (Float(bytes[i]) + Float(bytes[i + 1]) + Float(bytes[i + 2])) / 765; rn += 1 } }
    let inner = (sum * SIMD3<Float>(0.2126, 0.7152, 0.0722)).sum() / Float(W * H)
    if rn > 0, ring / rn < 0.015, inner > 0.08 { blackBorder?() }
    lum.sort()
    return (FrameStats(mean: sum / Float(W * H), p25: lum[lum.count / 4], p75: lum[lum.count * 3 / 4]), luma)
  }
  static func matched(_ image: CIImage, _ m: LensCorrection) -> CIImage {
    if m.isIdentity { return image }
    var i = image.applyingFilter("CIGammaAdjust", parameters: ["inputPower": m.gamma])
    i = i.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: CGFloat(m.scale * m.gain.x), y: 0, z: 0, w: 0),
      "inputGVector": CIVector(x: 0, y: CGFloat(m.scale * m.gain.y), z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(m.scale * m.gain.z), w: 0)])
    return i
  }
  private func small(_ buffer: CVPixelBuffer) -> CGImage? {
    var img = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    let s = 480 / max(1, img.extent.width)
    img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
    return context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
  }
  // mesma hora de captura nas duas saídas -> homografia entre o quadro estabilizado e o cru -> escala = corte do estabilizador
  private func register(stabilized: CVPixelBuffer, fast: CGImage) {
    defer { lock.lock(); calibBusy = false; lock.unlock() }
    guard let stab = small(stabilized) else { return }
    let request = VNHomographicImageRegistrationRequest(targetedCGImage: fast, options: [:])
    guard (try? VNImageRequestHandler(cgImage: stab, options: [:]).perform([request])) != nil,
      let obs = request.results?.first as? VNImageHomographicAlignmentObservation else { return }
    let m = obs.warpTransform
    let det = Double(abs(m.columns.0.x * m.columns.1.y - m.columns.1.x * m.columns.0.y))
    guard det > 0.0001 else { return }
    var c = det.squareRoot(); if c < 1 { c = 1 / c }
    guard c >= 1, c <= 1.8 else { return }
    lock.lock()
    guard !cropFrozen else { lock.unlock(); return }
    cropSamples.append(c)
    let sorted = cropSamples.sorted(); crop = sorted[sorted.count / 2]
    if cropSamples.count >= 5 { cropFrozen = true }
    let value = crop, first = cropSamples.count == 5
    lock.unlock()
    if first { onCrop?(value) }
  }
  // troca de câmera/formato: a tela segura o último quadro (sem piscar deitado) até chegarem quadros da configuração nova
  func freeze() { lock.lock(); frozen = true; pending = nil; fastBuffer = nil; eis.reset(); fastCorr = (0, 0); fxHist.removeAll(); fxLatest = nil; shownK.removeAll(); lock.unlock() }
  func thaw(drop: Int = 4) { lock.lock(); frozen = false; dropFrames = drop; zoomHistory.removeAll(); cropSamples.removeAll(); cropFrozen = false; crop = 1.06; shownCrop = 0; nextCalib = 0; calibFast = nil; calibBusy = false; fxRest = nil; fxSamples.removeAll(); fxValid = true; fxChecked = false; lock.unlock() }
  private func zoomAt(_ t: Double) -> Double? {
    guard let first = zoomHistory.first else { return nil }
    if t <= first.0 { return first.1 }
    var last = first
    for e in zoomHistory { if e.0 > t { let k = (t - last.0) / max(0.0001, e.0 - last.0); return last.1 + (e.1 - last.1) * k }; last = e }
    return last.1
  }
  func setCube(_ data: Data?, size: Int) { lock.lock(); cube = data; cubeSize = size; lock.unlock() }
  func setOrientation(_ value: CGImagePropertyOrientation, mirrored mirror: Bool) { lock.lock(); orientation = value; mirrored = mirror; lock.unlock() }
  func currentCube() -> (Data?, Int) { lock.lock(); defer { lock.unlock() }; return (cube, cubeSize) }

  static func filtered(_ image: CIImage, cube: Data?, size: Int) -> CIImage {
    guard let cube, let filter = CIFilter(name: "CIColorCube") else { return image }
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(size, forKey: "inputCubeDimension")
    filter.setValue(cube, forKey: "inputCubeData")
    return filter.outputImage ?? image
  }
  static func oriented(_ buffer: CVPixelBuffer, _ orientation: CGImagePropertyOrientation, mirrored: Bool) -> CIImage {
    orient(CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]), orientation, mirrored: mirrored)
  }
  // alinhamento da troca de lente no quadro do sensor: escala s no centro + deslocamento t (y do sensor pra baixo = −y no CI)
  static func aligned(_ image: CIImage, _ g: SwitchGeometry) -> CIImage {
    let e = image.extent, cx = e.midX, cy = e.midY
    var t = CGAffineTransform(translationX: -cx, y: -cy)
    t = t.concatenating(CGAffineTransform(scaleX: CGFloat(g.s), y: CGFloat(g.s)))
    t = t.concatenating(CGAffineTransform(translationX: cx + CGFloat(g.tx) * e.width, y: cy - CGFloat(g.ty) * e.height))
    return image.clampedToExtent().transformed(by: t).cropped(to: e)
  }
  static func orient(_ source: CIImage, _ orientation: CGImagePropertyOrientation, mirrored: Bool) -> CIImage {
    var image = source.oriented(orientation)
    if mirrored { image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
    return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
  func draw(in view: MTKView) {
    let now = CACurrentMediaTime()
    let zNow = zoomNow?()
    lock.lock()
    if let zNow, zNow > 0 { zoomHistory.append((now, zNow)); if zoomHistory.count > 600 { zoomHistory.removeFirst(zoomHistory.count - 600) } }
    let buffer = pending, pts = pendingPTS; pending = nil; let cube = self.cube, size = cubeSize, orient = orientation, mirror = mirrored
    let zFrame = pts.flatMap { zoomAt($0) }
    let fxHit = pts.flatMap { fxAt($0) }, fxNow = fxLatest
    if shownCrop == 0 { shownCrop = crop } else { let dt = min(0.1, max(0, now - shownCropAt)); shownCrop += (crop - shownCrop) * (1 - exp(-dt / 1.5)) }
    shownCropAt = now
    let fast = fastBuffer, zFast = fastPTS.flatMap { zoomAt($0) }, cropNow = shownCrop
    if let a = zoomHistory.dropLast().last, let b = zoomHistory.last, abs(a.1 - b.1) > 0.0005 { lastZoomMove = now }
    let live = lightPreview && fast != nil
    let corrNow = fastCorr
    let liveFrame: CVPixelBuffer? = live && fastFresh ? fast : nil
    let livePTS = fastPTS
    if live { fastFresh = false; pending = nil }
    lock.unlock()
    if live {
      guard let liveFrame else { return }
      drawLive(view, liveFrame, crop: cropNow, cube: cube, size: size, orient: orient, mirror: mirror, match: lensMatch?.correction(at: livePTS ?? now) ?? .identity,
        geo: aligner?.geometry("fast", at: livePTS ?? now) ?? .identity, shake: corrNow)
      return
    }
    // quadro estabilizado sem o gêmeo da saída rápida com o zoom andando: segura o anterior (até 150 ms) em vez de chutar a escala
    if buffer != nil, fxNow != nil, let h = fxHit, !h.exact, now - lastStabDraw < 0.15 { return }
    guard let buffer, let commandQueue, let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    let target = view.drawableSize
    guard target.width > 0, target.height > 0 else { return }
    lastStabDraw = now
    // troca de lente: o mesmo alinhamento deslizante que vai pro ARQUIVO (a tela mostra o quadro do arquivo)
    var raw = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    let geo = aligner?.geometry("stab", at: pts ?? now) ?? .identity
    if !geo.isIdentity { raw = Self.aligned(raw, geo) }
    var image = Self.orient(raw, orient, mirrored: mirror)
    var k = 1.0
    if let h = fxHit, let fxNow, h.fx > 0 { k = fxNow / h.fx }              // zoom REAL do quadro (intrínseca)
    else if let zNow, let zFrame, zFrame > 0 { k = zNow / zFrame }          // sem intrínseca: zoom pedido (conta antiga)
    k = max(1, min(6, k)); if abs(k - 1) < 0.0005 { k = 1 }   // nunca < 1 (zoom out: o quadro como está, sem borda inventada)
    if let pts { lock.lock(); shownK.append((pts, k)); if shownK.count > 400 { shownK.removeFirst(shownK.count - 400) }; lock.unlock() }
    k *= Double(geo.cover)
    // scale first: the LUT runs on screen pixels, not on 4K
    let scale = min(target.width / image.extent.width, target.height / image.extent.height)
    let fit = CGRect(x: (target.width - image.extent.width * scale) / 2, y: (target.height - image.extent.height * scale) / 2, width: image.extent.width * scale, height: image.extent.height * scale)
    // Uma fonte só (o quadro ESTABILIZADO, igual ao arquivo) com o zoom de agora: o zoom in amplia o quadro na hora.
    // No zoom out o quadro estabilizado (atrasado) ainda não tem a borda nova: só essa borda vem do quadro em tempo real
    // (saída sem estabilização, no mesmo enquadramento — corte medido pelo Vision), com emenda suave de poucos pixels.
    // Sem troca de fonte (não pula) e sem pixel inventado (não repete nem borra).
    image = image.transformed(by: CGAffineTransform(scaleX: scale * k, y: scale * k))
    image = image.transformed(by: CGAffineTransform(translationX: fit.midX - image.extent.midX, y: fit.midY - image.extent.midY))
    image = image.cropped(to: fit)
    image = Self.matched(Self.filtered(image, cube: cube, size: size), lensMatch?.correction(at: pts ?? now) ?? .identity).cropped(to: fit)
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: target))
    image = image.composited(over: black)
    let destination = CIRenderDestination(width: Int(target.width), height: Int(target.height), pixelFormat: view.colorPixelFormat, commandBuffer: commandBuffer) { drawable.texture }
    destination.isFlipped = true
    _ = try? context.startTask(toRender: image, to: destination)
    commandBuffer.present(drawable)
    commandBuffer.commit()
    frames += 1
  }

  private func drawLive(_ view: MTKView, _ buffer: CVPixelBuffer, crop: Double, cube: Data?, size: Int, orient: CGImagePropertyOrientation, mirror: Bool, match: LensCorrection, geo: SwitchGeometry, shake: (Double, Double) = (0, 0)) {
    guard let commandQueue, let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    let target = view.drawableSize
    guard target.width > 0, target.height > 0 else { return }
    var raw = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    // troca de lente (com zoom de cobertura) + tremor da mão (só desloca, dentro da margem do corte — sem zoom extra)
    let g = SwitchGeometry(s: geo.s, tx: geo.tx + Float(shake.0), ty: geo.ty + Float(shake.1))
    if !g.isIdentity { raw = Self.aligned(raw, g) }
    var image = Self.orient(raw, orient, mirrored: mirror)
    let fitScale = min(target.width / image.extent.width, target.height / image.extent.height)
    let fit = CGRect(x: (target.width - image.extent.width * fitScale) / 2, y: (target.height - image.extent.height * fitScale) / 2, width: image.extent.width * fitScale, height: image.extent.height * fitScale)
    let sc = fitScale * max(1, crop) * Double(geo.cover)
    image = image.transformed(by: CGAffineTransform(scaleX: sc, y: sc))
    image = image.transformed(by: CGAffineTransform(translationX: fit.midX - image.extent.midX, y: fit.midY - image.extent.midY)).cropped(to: fit)
    image = Self.matched(Self.filtered(image, cube: cube, size: size), match).cropped(to: fit)
    image = image.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: target)))
    let destination = CIRenderDestination(width: Int(target.width), height: Int(target.height), pixelFormat: view.colorPixelFormat, commandBuffer: commandBuffer) { drawable.texture }
    destination.isFlipped = true
    _ = try? context.startTask(toRender: image, to: destination)
    commandBuffer.present(drawable)
    commandBuffer.commit()
    frames += 1
  }

  // First frame of a take -> small JPEG for the cloud library (with the same LUT, so Log takes show in Rec.709).
  func thumbnail(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, mirrored: Bool, applyCube: Bool = true) -> Data? {
    var image = Self.oriented(buffer, orientation, mirrored: mirrored)
    let scale = 360 / max(1, image.extent.width)
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    if applyCube { let (cube, size) = currentCube(); image = Self.filtered(image, cube: cube, size: size) }
    image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return context.jpegRepresentation(of: image, colorSpace: space, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
  }
}

struct MetalPreview: UIViewRepresentable {
  let renderer: PreviewRenderer
  func makeUIView(context: Context) -> MTKView {
    let view = MTKView(frame: .zero, device: renderer.device)
    view.framebufferOnly = false
    view.colorPixelFormat = .bgra8Unorm
    view.enableSetNeedsDisplay = false
    view.isPaused = false
    view.preferredFramesPerSecond = 60
    view.autoResizeDrawable = true
    view.backgroundColor = .black
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    view.isUserInteractionEnabled = false
    view.delegate = renderer
    return view
  }
  func updateUIView(_ view: MTKView, context: Context) {}
}
