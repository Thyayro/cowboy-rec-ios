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
  // prévia estabilizada: zoom que cada quadro carrega pelo REGISTRO exato do ZoomDriver + trava calibrada no aparelho
  // (ZoomLag/ZoomCalibration); nil = sem calibração aprovada: conta antiga. Só a thread da tela lê e escreve.
  let calibRec = ZoomCalibRecorder()
  let tap = PreviewTap()   // trechos do que a tela mostrou em volta de cada zoom (diagnóstico)
  // ZOOM NA PRÉVIA ESTABILIZADA (0.7.8, medido na tela do aparelho em 5 trechos): o quadro estabilizado (o do arquivo)
  // para LISO sozinho — sobe sem recuar, ultrapassagem ≤0,6%. Todo o vai-e-volta vinha da ampliação que mostra o zoom
  // "na hora" sobre o quadro atrasado: o conteúdo chega ~25 ms ADIANTADO em relação ao zoom lido na tela (variando 0–35 ms
  // de gesto pra gesto com a Extrema), e a ampliação passava do ponto 7–12%. Com o adiantamento medido: ~3,5% em média.
  // zoomInstant = false: a tela mostra exatamente o arquivo (sem ampliação) — liso, mas o zoom aparece ~0,5 s depois.
  var zoomInstant = UserDefaults.standard.object(forKey: "zoomInstant") as? Bool ?? true
  static let contentLead = 0.025
  let zoomTrack = FastZoomTracker()   // zoom real de cada instante, medido na saída rápida (0.7.9)
  // TROCA DE LENTE SEM PULO (0.8.0, ver LensSwitchHider): sensor de cada quadro nas duas saídas; a rápida mede a troca e
  // tela + arquivo se preparam antes de o quadro estabilizado da lente nova chegar
  let switchHider = LensSwitchHider()
  var onSwitch: (([String: String]) -> Void)?
  private var lastFast: (buffer: CVPixelBuffer, id: Int, pts: Double)?
  private var lastStab: (buffer: CVPixelBuffer, id: Int)?
  private var pendingSID = 0
  private var switchBusy = false
  private let switchQueue = DispatchQueue(label: "cowboy.preview.switch", qos: .userInitiated)
  // nitidez da saída rápida antes e 2 s depois de cada troca de lente (prova do foco sem pedir teste, 0.8.2)
  private var lastSharp: Float = 0
  var focusProbe: (() -> String)?
  // zoom digital na ultra (0.8.7): agora na tela, pelo pts no arquivo
  var digitalNow: (() -> Double)?
  var digitalAt: ((Double) -> Double)?
  private var lastDZ = 1.0
  // DESFOQUE DE MOVIMENTO (0.8.9, ver MotionBlur): tela com rastro no Live (ou no Render com "ver como render")
  var blurPreview = false
  var blurShutter: (() -> Double)?   // obturador sintético agora (s), já sem a exposição real
  var blurFOV = 106.0                // campo horizontal do formato no zoom 1 do aparelho (graus)
  var blurHot = false                // aparelho quente: menos cópias na tela (o arquivo não muda)
  private var focusWatch: (t0: Double, before: Float, items: [String], from: Int, to: Int)?
  var stabSampling = false   // amostras do estabilizado pro alinhador antigo (só o teste antigo; o arquivo usa a troca medida)
  var frameZoom: ((Double) -> Double?)?
  // por quadro estabilizado desenhado: ampliação usada, a que a conta antiga daria e a hora (medição do estacionar/calibração)
  private var shownK: [(pts: Double, k: Double, kOld: Double, at: Double)] = []
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
  func displayK(at t: Double) -> Double? { lock.lock(); defer { lock.unlock() }; return shownK.last(where: { abs($0.pts - t) < 0.004 })?.k }
  func zoomHistorySnapshot() -> [(Double, Double)] { lock.lock(); defer { lock.unlock() }; return zoomHistory }
  func shownSnapshot() -> [(pts: Double, k: Double, kOld: Double, at: Double)] { lock.lock(); defer { lock.unlock() }; return shownK }
  func clearShown() { lock.lock(); shownK.removeAll(); lock.unlock() }
  var displayShake: (Double, Double) { lock.lock(); defer { lock.unlock() }; return fastCorr }
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
    let sid = LensID.of(buffer)
    lock.lock()
    if frozen { lock.unlock(); return }
    let prevStab = lastStab; lastStab = (buffer, sid)
    lock.unlock()
    // primeiro quadro estabilizado da lente nova: mede o pulo NELE (é o que a tela e o arquivo mostram), em volta da previsão
    // da saída rápida, ANTES de ele ir pra tela e pro arquivo (só na troca; poucos ms)
    if let pts, let ps = prevStab, ps.id != sid, ps.id != 0, sid != 0, let ev = switchHider.awaiting(from: ps.id, to: sid, at: pts) {
      measureStabSwitch(ps.buffer, buffer, ev: ev)
    }
    lock.lock()
    if frozen { lock.unlock(); return }
    if dropFrames > 0 { dropFrames -= 1; lock.unlock(); return }
    pending = buffer; pendingPTS = pts; pendingSID = sid
    let nowS = CACurrentMediaTime()
    let wantStab = stabSampling && aligner != nil && !stabBusy && nowS >= nextStab && pts != nil
    if wantStab { stabBusy = true; nextStab = nowS + 0.1 }   // 10/s (era 33/s: aquecia)
    var match: (pts: Double, image: CGImage)?
    if let cf = calibFast, let pts {
      if abs(cf.pts - pts) < 0.004 { match = cf; calibFast = nil } else if pts > cf.pts + 0.1 { calibFast = nil; calibBusy = false }
    }
    lock.unlock()
    if let pts, calibRec.active { calibRec.feed(buffer, pts: pts, stabilized: true) }
    if let match { calibQueue.async { self.register(stabilized: buffer, fast: match.image) } }
    if wantStab, let pts, let al = aligner {
      stabQueue.async {
        if let r = self.sample(buffer, cube: false) { al.feed("stab", t: pts, luma: r.luma) }
        self.lock.lock(); self.stabBusy = false; self.lock.unlock()
      }
    }
  }
  func pushFast(_ buffer: CVPixelBuffer, pts: Double) {
    let sid = LensID.of(buffer)
    if calibRec.active { calibRec.feed(buffer, pts: pts, stabilized: false) }
    // estabilização própria da tela (só deslocamento; cega ao zoom) — calculada aqui, antes de mostrar
    lock.lock(); let fr = frozen; eis.margin = max(0.01, min(0.035, (crop - 1) / 2 - 0.006)); lock.unlock()
    if fr { return }
    // durante o zoom a imagem muda de tamanho: a medida de tremor erraria e depois "voltaria" — segura enquanto o zoom anda
    lock.lock(); let zooming = CACurrentMediaTime() - lastZoomMove < 0.2
    // só mede enquanto o zoom pedido mudou há pouco (o conteúdo chega ≤35 ms adiantado e o quadro rápido chega ~40 ms depois):
    // parado, o quadro não muda mais — medir só somaria ruído (e trocaria a referência à toa: degrau de ~1%)
    let trackMoving = CACurrentMediaTime() - lastZoomMove < 0.15, zHistFast = zoomAt(pts + Self.contentLead) ?? 0
    // troca de lente (0.8.0): sensor deste quadro rápido × o do anterior, com o zoom PARADO nos dois
    let prevFast = lastFast; lastFast = (buffer, sid, pts)
    var switchJob = false, still = false, switchStep = 1.0
    if let pf = prevFast, pf.id != sid, pf.id != 0, sid != 0 {
      if focusWatch == nil { focusWatch = (pts, lastSharp, [], pf.id, sid) }
      // 0.8.6: com a troca automática o iOS troca NA CHEGADA do zoom (não ~1 s depois): a troca no fim do zoom também é
      // preparada — o passo de zoom entre os dois quadros (registrado) é descontado da medida. Zoom rápido (>1,2% por
      // quadro): o movimento esconde. (Antes exigia zoom parado há 150 ms: a troca do clique ficava sem preparo = +1,1%.)
      let zPrev = zoomAt(pf.pts + Self.contentLead) ?? 0
      switchStep = zHistFast > 0 && zPrev > 0 ? zHistFast / zPrev : 1
      still = abs(log(switchStep)) < 0.012
      if still && !switchBusy { switchBusy = true; switchJob = true }
    }
    let cropNow = crop; lock.unlock()
    if let pf = prevFast, pf.id != sid, pf.id != 0, sid != 0 {
      lensColorSwitch(pf.buffer, buffer, pts: pts)   // cor/luz: em TODA troca (parado ou andando)
      if switchJob { measureFastSwitch(pf.buffer, buffer, pts: pts, from: pf.id, to: sid, crop: cropNow, step: switchStep) }
      else { onSwitch?(["etapa": "rapida", "de": "\(pf.id)", "para": "\(sid)", "medido": still ? "ocupado" : "zoom andando (o movimento esconde)"]) }
    }
    if !lightPreview && zoomInstant { zoomTrack.feed(pts: pts, zHist: zHistFast, thumb: trackMoving ? ZoomImage.thumb(buffer) : nil, moving: trackMoving, sensor: sid) }
    let corr = lightPreview ? eis.process(buffer, t: pts, hold: zooming) : (0, 0)
    lock.lock()
    if frozen { lock.unlock(); return }
    fastBuffer = buffer; fastPTS = pts; fastFresh = true; fastCorr = corr
    let now = CACurrentMediaTime()
    fastAt = now
    let wantStats = now >= nextStats && !statsBusy
    if wantStats { nextStats = now + 0.1; statsBusy = true }   // 10/s (era 33/s: aquecia)
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
          self.watchFocus(pts: pts, sharp: ZoomImage.sharpness(r.luma))
        }
        self.lock.lock(); self.statsBusy = false; self.lock.unlock()
      }
    }
    if go { calibQueue.async { if let img = self.small(buffer) { self.lock.lock(); self.calibFast = (pts, img); self.lock.unlock() } else { self.lock.lock(); self.calibBusy = false; self.lock.unlock() } } }
  }
  // troca vista na saída rápida (zoom parado): mede o pulo entre o último quadro da lente velha e o 1º da nova e avisa a
  // tela/arquivo ~0,45 s antes de o quadro estabilizado da nova chegar
  private func measureFastSwitch(_ a: CVPixelBuffer, _ b: CVPixelBuffer, pts: Double, from: Int, to: Int, crop: Double, step: Double = 1) {
    switchQueue.async {
      var m: (g: SwitchGeometry, conf: Float, gain: Float)?
      if let ta = ZoomImage.thumb(a), let tb = ZoomImage.thumb(b) { m = ZoomImage.switchGeo(ZoomImage.prep(ta), ZoomImage.prep(tb)) }
      // só o pulo da LENTE: o quadro novo também está `step` mais perto pelo próprio zoom (a ampliação k cuida disso)
      m = m.map { (SwitchGeometry(s: $0.g.s * Float(step), tx: $0.g.tx, ty: $0.g.ty, exact: true), $0.conf, $0.gain) }
      // previsão pro quadro estabilizado: escala × razão aprendida deste par (o corte da estabilização pode mudar com a lente),
      // deslocamento × corte (o estabilizado mostra 1/corte do quadro rápido); sem medida: o que este par costuma fazer
      var pred: SwitchGeometry?
      if let m { let c = Float(max(1, crop)); pred = SwitchGeometry(s: m.g.s * SwitchMemory.ratio(from: from, to: to), tx: m.g.tx * c, ty: m.g.ty * c, exact: true) }
      else if let s = SwitchMemory.scale(from: from, to: to) { pred = SwitchGeometry(s: s, tx: 0, ty: 0, exact: true) }
      self.switchHider.add(t: pts, from: from, to: to, fast: m?.g, pred: pred, step: step)
      var info: [String: String] = ["etapa": "rapida", "de": "\(from)", "para": "\(to)", "passo": String(format: "%.4f", step), "medido": m.map { Self.geoText($0.g) + String(format: " conf %.2f", $0.conf) } ?? "não deu"]
      if let pred { info["previsto"] = Self.geoText(pred); info["preparo"] = Self.geoText(SwitchPlan.pre(pred)) }
      self.onSwitch?(info)
      self.lock.lock(); self.switchBusy = false; self.lock.unlock()
    }
  }
  private func watchFocus(pts: Double, sharp: Float) {
    lock.lock()
    var done: [String: String]?
    if var w = focusWatch {
      w.items.append(String(format: "%.0f:%.0f", (pts - w.t0) * 1000, sharp) + (focusProbe?() ?? ""))
      if pts - w.t0 > 2.0 {
        done = ["etapa": "foco", "de": "\(w.from)", "para": "\(w.to)", "antes": String(format: "%.0f", w.before), "depois": w.items.joined(separator: " ")]
        focusWatch = nil
      } else { focusWatch = w }
    }
    lastSharp = sharp
    lock.unlock()
    if let done { onSwitch?(done) }
  }
  // igualar câmeras no quadro EXATO da troca (0.8.1): cor/luz do último quadro da lente velha × 1º da nova, registrado
  // ~0,45 s antes de o quadro estabilizado da nova chegar na tela/arquivo
  private func lensColorSwitch(_ a: CVPixelBuffer, _ b: CVPixelBuffer, pts: Double) {
    guard let lm = lensMatch, lm.enabled, let la = LensID.name(a), let lb = LensID.name(b), la != lb else { return }
    switchQueue.async {
      guard let sa = self.sample(a, cube: true)?.stats, let sb = self.sample(b, cube: true)?.stats else { return }
      lm.switched(at: pts, from: la, before: sa, to: lb, after: sb)
    }
  }
  // 1º quadro estabilizado da lente nova (fila dos quadros, antes da tela e do arquivo): mede em volta da previsão
  private func measureStabSwitch(_ a: CVPixelBuffer, _ b: CVPixelBuffer, ev: LensSwitchHider.Event) {
    var m: (g: SwitchGeometry, conf: Float, gain: Float)?
    if let around = ev.pred, let ta = ZoomImage.thumb(a), let tb = ZoomImage.thumb(b) {
      let st = Float(ev.step)
      m = ZoomImage.switchGeo(ZoomImage.prep(ta), ZoomImage.prep(tb), around: SwitchGeometry(s: around.s / st, tx: around.tx, ty: around.ty, exact: true))
      m = m.map { (SwitchGeometry(s: $0.g.s * st, tx: $0.g.tx, ty: $0.g.ty, exact: true), $0.conf, $0.gain) }
    }
    switchHider.stabMeasured(t: ev.t, g: m?.g)
    if let m { SwitchMemory.record(from: ev.from, to: ev.to, stab: m.g.s, fast: ev.fast?.s) }
    onSwitch?(["etapa": "estabilizado", "de": "\(ev.from)", "para": "\(ev.to)", "previsto": ev.pred.map { Self.geoText($0) } ?? "nada",
      "medido": m.map { Self.geoText($0.g) + String(format: " conf %.2f", $0.conf) } ?? "não deu"])
  }
  static func geoText(_ g: SwitchGeometry) -> String { String(format: "%.4f %+.4f %+.4f", g.s, g.tx, g.ty) }
  // arquivo: a mesma troca medida que a tela usa (sem segurar quadro: no arquivo a ida-e-volta vira um respiro suave)
  func fileSwitchGeometry(_ pb: CVPixelBuffer?, pts: Double) -> SwitchGeometry {
    guard let pb else { return .identity }
    let g = switchHider.geometry(pts: pts, sensor: LensID.of(pb), file: true).g
    let d = Float(max(1, digitalAt?(pts) ?? 1))
    return d > 1.0005 ? SwitchPlan.compose(SwitchGeometry(s: d, tx: 0, ty: 0, exact: true), g) : g
  }
  // desfoque do quadro captado em p — a MESMA conta pra tela e arquivo (o arquivo chama da fila dos quadros): zoom do
  // conteúdo (registro da tela, adiantado como o resto da ampliação) × digital, giro suavizado e distância focal do quadro
  func blurParams(at p: Double, width: Double, height: Double) -> BlurParams {
    guard let shutter = blurShutter?(), shutter > 0.0002 else { return .none }
    let h = 1.0 / 60
    lock.lock()
    let za = zoomAt(p + Self.contentLead - h), zb = zoomAt(p + Self.contentLead + h), z0 = zoomAt(p + Self.contentLead), c = crop
    lock.unlock()
    var v = 0.0
    if let za, let zb, za > 0, zb > 0 { v = log(zb / za) / (2 * h) }
    var d0 = 1.0
    if let dAt = digitalAt { d0 = dAt(p); let da = dAt(p - h), db = dAt(p + h); if da > 0, db > 0 { v += log(db / da) / (2 * h) } }
    let w = MotionHub.shared.rotation(around: p) ?? (x: 0, y: 0, z: 0)
    let f = MotionBlur.focalNorm(fovDegrees: blurFOV, zoomRaw: z0 ?? 1, crop: c, digital: d0)
    return MotionBlur.params(zoomSpeed: v, omega: w, shutter: shutter, focalNorm: f, width: width, height: height)
  }
  // rastro na tela: cópias do quadro (já na escala da tela, antes do LUT — igual ao arquivo) ao longo do caminho; só nos
  // quadros com movimento (parado = nada a mais pra GPU)
  private func previewBlur(_ image: CIImage, raw: CIImage, at p: Double, orient: CGImagePropertyOrientation, mirror: Bool, scale: Double, fit: CGRect) -> CIImage {
    let W = Double(raw.extent.width), H = Double(raw.extent.height)
    let bp = blurParams(at: p, width: W, height: H)
    let n = bp.samples(pxScale: scale, spacing: 5, max: blurHot ? 3 : 6)
    guard n > 1 else { return image }
    // vetor: quadro do sensor (y pra baixo) -> Core Image (y pra cima) -> orientação da tela -> escala da tela
    let t = raw.orientationTransform(for: orient)
    let vx = bp.mx * W, vy = -bp.my * H
    var dx = Double(t.a) * vx + Double(t.c) * vy, dy = Double(t.b) * vx + Double(t.d) * vy
    if mirror { dx = -dx }
    return Self.blurred(image, zoom: bp.zoom, dx: dx * scale, dy: dy * scale, n: n, center: CGPoint(x: fit.midX, y: fit.midY), fit: fit)
  }
  static func blurred(_ image: CIImage, zoom: Double, dx: Double, dy: Double, n: Int, center c: CGPoint, fit: CGRect) -> CIImage {
    let src = image.clampedToExtent()
    var acc: CIImage?
    for i in 0..<n {
      let u = MotionBlur.u(i, n), s = exp(zoom * u)
      let t = CGAffineTransform(translationX: -c.x, y: -c.y).concatenating(CGAffineTransform(scaleX: s, y: s)).concatenating(CGAffineTransform(translationX: c.x + dx * u, y: c.y + dy * u))
      let copy = src.transformed(by: t).cropped(to: fit)
      // média uniforme por dissolução encadeada (a k-ésima cópia entra com peso 1/k): sem alfa parcial no caminho
      acc = acc.map { $0.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: copy, kCIInputTimeKey: 1.0 / Double(i + 1)]) } ?? copy
    }
    return (acc ?? image).cropped(to: fit)
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
  func freeze() { lock.lock(); frozen = true; pending = nil; fastBuffer = nil; lastFast = nil; lastStab = nil; eis.reset(); fastCorr = (0, 0); shownK.removeAll(); lock.unlock(); zoomTrack.reset(); switchHider.reset() }
  func thaw(drop: Int = 4) { lock.lock(); frozen = false; dropFrames = drop; zoomHistory.removeAll(); cropSamples.removeAll(); cropFrozen = false; crop = 1.06; shownCrop = 0; nextCalib = 0; calibFast = nil; calibBusy = false; lock.unlock() }
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
    let newestFast = zoomTrack.newestPTS
    lock.lock()
    if let zNow, zNow > 0 { zoomHistory.append((now, zNow)); if zoomHistory.count > 600 { zoomHistory.removeFirst(zoomHistory.count - 600) } }
    let buffer = pending, pts = pendingPTS, sid = pendingSID; pending = nil; let cube = self.cube, size = cubeSize, orient = orientation, mirror = mirrored
    let zFrame = pts.flatMap { zoomAt($0 + Self.contentLead) }
    let zNewest = newestFast.flatMap { zoomAt($0 + Self.contentLead) }   // conteúdo adiantado ~25 ms em relação ao zoom lido
    if shownCrop == 0 { shownCrop = crop } else { let dt = min(0.1, max(0, now - shownCropAt)); shownCrop += (crop - shownCrop) * (1 - exp(-dt / 1.5)) }
    shownCropAt = now
    let fast = fastBuffer, zFast = fastPTS.flatMap { zoomAt($0) }, cropNow = shownCrop
    if let a = zoomHistory.dropLast().last, let b = zoomHistory.last, abs(a.1 - b.1) > 0.0005 { lastZoomMove = now }
    let zoomMovedNow = lastZoomMove == now
    let live = lightPreview && fast != nil
    let corrNow = fastCorr
    let liveFrame: CVPixelBuffer? = live && fastFresh ? fast : nil
    let livePTS = fastPTS
    if live { fastFresh = false; pending = nil }
    lock.unlock()
    let dz = max(1, digitalNow?() ?? 1)
    let dMoved = abs(dz - lastDZ) > 1e-4; lastDZ = dz
    tap.tick(now: now, moving: zoomMovedNow || dMoved)
    if live {
      guard let liveFrame else { return }
      drawLive(view, liveFrame, crop: cropNow, cube: cube, size: size, orient: orient, mirror: mirror, match: lensMatch?.correction(at: livePTS ?? now, lens: LensID.name(liveFrame)) ?? .identity,
        geo: aligner?.geometry("fast", at: livePTS ?? now) ?? .identity, shake: corrNow, pts: livePTS)
      return
    }
    // troca de lente (0.8.0): preparo/saída sem pulo; ida-e-volta rápida = a tela segura o quadro anterior
    let sw = pts.map { switchHider.geometry(pts: $0, sensor: sid, file: false) } ?? (g: SwitchGeometry.identity, hold: false)
    if sw.hold && buffer != nil { return }
    guard let buffer, let commandQueue, let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    let target = view.drawableSize
    guard target.width > 0, target.height > 0 else { return }
    var raw = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    if !sw.g.isIdentity { raw = Self.aligned(raw, sw.g) }   // no quadro do sensor (mesma conta do arquivo)
    var image = Self.orient(raw, orient, mirrored: mirror)
    // ampliação = zoom pedido agora ÷ zoom do conteúdo do quadro; nunca < 1 (zoom out: o quadro como está, sem borda inventada)
    var kOld = 1.0
    if zoomInstant, let zNow, let zFrame, zFrame > 0 { kOld = max(1, min(6, zNow / zFrame)); if abs(kOld - 1) < 0.004 { kOld = 1 } }
    var k = kOld
    if zoomInstant, let p = pts, let rr = zoomTrack.ratio(newestOver: p) {
      // 0.8.8: o quadro rápido mais novo medido é de ~50 ms atrás — o zoom que ainda andou até agora (pelo zoom pedido, liso
      // e conhecido) entra junto; sem isso a tela POUSAVA curta (~3,6% no 0,5→1 de dia) e completava depois de parar
      var r = rr
      if let zN = zNow, zN > 0, let zH = zNewest, zH > 0 { r *= zN / zH }
      k = max(1, min(6, r)); if abs(k - 1) < 0.0005 { k = 1 }
    }   // zoom REAL medido
    else if zoomInstant, let zNow, let p = pts, let zk = frameZoom?(p), zk > 0 { k = max(1, min(6, zNow / zk)); if abs(k - 1) < 0.0005 { k = 1 } }
    if let pts { lock.lock(); shownK.append((pts, k, kOld, now)); if shownK.count > 600 { shownK.removeFirst(shownK.count - 600) }; lock.unlock() }
    // scale first: the LUT runs on screen pixels, not on 4K
    let scale = min(target.width / image.extent.width, target.height / image.extent.height)
    let fit = CGRect(x: (target.width - image.extent.width * scale) / 2, y: (target.height - image.extent.height * scale) / 2, width: image.extent.width * scale, height: image.extent.height * scale)
    // Uma fonte só (o quadro ESTABILIZADO, igual ao arquivo) com o zoom de agora: o zoom in amplia o quadro na hora.
    // No zoom out o quadro estabilizado (atrasado) ainda não tem a borda nova: só essa borda vem do quadro em tempo real
    // (saída sem estabilização, no mesmo enquadramento — corte medido pelo Vision), com emenda suave de poucos pixels.
    // Sem troca de fonte (não pula) e sem pixel inventado (não repete nem borra).
    image = image.transformed(by: CGAffineTransform(scaleX: scale * k * dz, y: scale * k * dz))
    image = image.transformed(by: CGAffineTransform(translationX: fit.midX - image.extent.midX, y: fit.midY - image.extent.midY))
    image = image.cropped(to: fit)
    if blurPreview, let p = pts { image = previewBlur(image, raw: raw, at: p, orient: orient, mirror: mirror, scale: scale * k * dz, fit: fit) }
    image = Self.matched(Self.filtered(image, cube: cube, size: size), lensMatch?.correction(at: pts ?? now, lens: LensID.name(buffer)) ?? .identity).cropped(to: fit)
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: target))
    image = image.composited(over: black)
    if tap.active { tap.offer(image, size: target, context: context, at: now, pts: pts ?? 0, k: k * dz, kOld: kOld, g: Double(sw.g.s), z: zNow ?? 0, lens: LensID.name(buffer) ?? lensMatch?.lens(at: pts ?? now) ?? "") }
    let destination = CIRenderDestination(width: Int(target.width), height: Int(target.height), pixelFormat: view.colorPixelFormat, commandBuffer: commandBuffer) { drawable.texture }
    destination.isFlipped = true
    _ = try? context.startTask(toRender: image, to: destination)
    commandBuffer.present(drawable)
    commandBuffer.commit()
    frames += 1
  }

  private func drawLive(_ view: MTKView, _ buffer: CVPixelBuffer, crop: Double, cube: Data?, size: Int, orient: CGImagePropertyOrientation, mirror: Bool, match: LensCorrection, geo: SwitchGeometry, shake: (Double, Double) = (0, 0), pts: Double? = nil) {
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
    if blurPreview, let p = pts { image = previewBlur(image, raw: raw, at: p, orient: orient, mirror: mirror, scale: sc, fit: fit) }
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
