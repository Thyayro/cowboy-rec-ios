import Foundation
import QuartzCore

// TROCA DE LENTE SEM PULO DE POSIÇÃO: ultra (0,5×), principal (1×) e tele ficam em pontos diferentes do aparelho (paralaxe) e
// a câmera virtual troca no mesmo campo de visão, mas os objetos ainda "pulam" alguns % na troca. Na troca, o último quadro
// da lente anterior e o primeiro da nova (imagens pequenas 96×54, normalizadas — robusto à diferença de luz) são comparados
// por busca exaustiva de escala + deslocamento; a imagem nova entra ALINHADA à anterior e escorrega até a posição real em
// 0,6 s (curva suave). Medido separado em cada saída (tela e arquivo — o estabilizador do arquivo mexe diferente).
// Convenção: corrigido(u) = novo(((u − 0,5 − t) / s) + 0,5), u em coordenadas do quadro do sensor (0–1, y pra baixo).
struct SwitchGeometry: Equatable {
  var s: Float = 1
  var tx: Float = 0
  var ty: Float = 0
  static let identity = SwitchGeometry()
  var isIdentity: Bool { abs(s - 1) < 0.0005 && abs(tx) < 0.0005 && abs(ty) < 0.0005 }
  var cover: Float { 1 + 2 * max(abs(tx), abs(ty)) + max(0, 1 - s) * 1.05 }
  func mix(_ k: Float) -> SwitchGeometry { SwitchGeometry(s: 1 + (s - 1) * k, tx: tx * k, ty: ty * k) }
}

final class SwitchAligner: @unchecked Sendable {
  static let w = 96, h = 54
  static let glide = 0.6
  private let lock = NSLock()
  private var last: [String: (lens: String, t: Double, img: [Float])] = [:]
  private var transitions: [String: [(t0: Double, lens: String, g: SwitchGeometry)]] = [:]
  var lensAt: ((Double) -> String)?
  var onAlign: ((String, SwitchGeometry, Float, Float) -> Void)?
  // MEDIÇÃO DO ESTACIONAR: depois que o zoom para, a escala de cada quadro é medida contra um quadro de REFERÊNCIA fixo
  // (0,3 s depois de parar) até 2,2 s — sem soma de ruído. Amplitude = quanto a escala ainda andou (ideal ≈ 0).
  private var settleT0 = 0.0
  private var settleActive = false
  private var settleRef: [Float]?
  private var settleVals: [(Double, Float, String)] = []
  var onSettle: ((String, Float) -> Void)?
  var probe: (() -> String)?   // estado real da câmera no quadro (posição da lente de foco, zoom, lente, exposição)
  func startSettle(_ t: Double) { lock.lock(); settleT0 = t; settleActive = true; settleRef = nil; settleVals = []; lock.unlock() }
  static func scaleVsRef(_ ref: [Float], _ img: [Float]) -> Float {
    var best = (s: Float(1), dx: 0, dy: 0, e: Float.infinity)
    for si in -10...10 { let s = 1 + Float(si) * 0.005
      for dy in -4...4 { for dx in -4...4 { let e = cost(ref, img, s, Float(dx) / Float(w), Float(dy) / Float(h)); if e < best.e { best = (s, dx, dy, e) } } } }
    let c = best
    for si in -5...5 { let s = c.s + Float(si) * 0.001
      for dy in (c.dy - 1)...(c.dy + 1) { for dx in (c.dx - 1)...(c.dx + 1) { let e = cost(ref, img, s, Float(dx) / Float(w), Float(dy) / Float(h)); if e < best.e { best = (s, dx, dy, e) } } } }
    return best.s
  }
  func geometry(_ stream: String, at t: Double) -> SwitchGeometry {
    lock.lock(); defer { lock.unlock() }
    guard let tr = transitions[stream]?.last(where: { $0.t0 <= t }), t - tr.t0 < Self.glide, lensAt?(t) == tr.lens else { return .identity }
    let k = Float(1 - (t - tr.t0) / Self.glide)
    return tr.g.mix(k * k * (3 - 2 * k))
  }
  func feed(_ stream: String, t: Double, luma: [Float]) {
    guard luma.count == Self.w * Self.h, let lens = lensAt?(t) else { return }
    let img = Self.normalize(luma)
    lock.lock(); let prev = last[stream]; last[stream] = (lens, t, img)
    var job: (ref: [Float], dt: Double)?; var finished: (String, Float)?
    if stream == "fast" && settleActive && t >= settleT0 {
      let dt = t - settleT0
      if dt >= 2.2 {
        let v = settleVals.map { $0.1 }
        let amp = (v.max() ?? 1) - (v.min() ?? 1)
        finished = (settleVals.map { String(format: "%.0f:%.3f", $0.0 * 1000, $0.1) + "[" + $0.2 + "]" }.joined(separator: " "), amp)
        settleActive = false; settleVals = []; settleRef = nil
      } else if dt >= 0.3 {
        if let r = settleRef { job = (r, dt) } else { settleRef = img }
      }
    }
    lock.unlock()
    if let job { let st = probe?() ?? ""; let sc = Self.scaleVsRef(job.ref, img); lock.lock(); settleVals.append((job.dt, sc, st)); lock.unlock() }
    if let finished { onSettle?(finished.0, finished.1) }
    guard let prev, prev.lens != lens, t - prev.t < 0.2 else { return }
    guard (prev.lens == "ultra") != (lens == "ultra") else { return }   // só 0,5× <-> 1× (da 1× em diante não precisa)
    let r = Self.align(reference: prev.img, moving: img)
    guard r.err < r.err0 * 0.92, abs(r.g.tx) < 0.09, abs(r.g.ty) < 0.09 else { return }
    lock.lock(); transitions[stream, default: []].append((t, lens, r.g)); if transitions[stream]!.count > 12 { transitions[stream]!.removeFirst() }; lock.unlock()
    onAlign?(stream, r.g, r.err, r.err0)
  }
  static func normalize(_ a: [Float]) -> [Float] {
    let n = Float(a.count), m = a.reduce(0, +) / n
    let sd = max(0.002, (a.reduce(0) { $0 + ($1 - m) * ($1 - m) } / n).squareRoot())
    return a.map { ($0 - m) / sd }
  }
  // custo: diferença média entre a referência e a imagem nova transformada (miolo, 12% de margem fora)
  static func cost(_ a: [Float], _ b: [Float], _ s: Float, _ tx: Float, _ ty: Float) -> Float {
    let W = Float(w), H = Float(h); var sum: Float = 0; var n: Float = 0
    let x0 = Int(W * 0.12), x1 = w - x0, y0 = Int(H * 0.12), y1 = h - y0
    for y in y0..<y1 {
      let v = ((Float(y) + 0.5) / H - 0.5 - ty) / s + 0.5
      let fy = v * H - 0.5; let iy = Int(fy.rounded(.down)); let ay = fy - Float(iy)
      if iy < 0 || iy >= h - 1 { continue }
      for x in x0..<x1 {
        let u = ((Float(x) + 0.5) / W - 0.5 - tx) / s + 0.5
        let fx = u * W - 0.5; let ix = Int(fx.rounded(.down)); let ax = fx - Float(ix)
        if ix < 0 || ix >= w - 1 { continue }
        let i = iy * w + ix
        let bv = (b[i] * (1 - ax) + b[i + 1] * ax) * (1 - ay) + (b[i + w] * (1 - ax) + b[i + w + 1] * ax) * ay
        let d = a[y * w + x] - bv; sum += d * d; n += 1
      }
    }
    return n > 100 ? sum / n : .infinity
  }
  static func align(reference a: [Float], moving b: [Float]) -> (g: SwitchGeometry, err: Float, err0: Float) {
    let err0 = cost(a, b, 1, 0, 0)
    var best = (s: Float(1), tx: Float(0), ty: Float(0), e: err0)
    let px = 1 / Float(w), py = 1 / Float(h)
    // grosso: escala ±4% (0,5%), deslocamento ±8 px
    for si in -8...8 {
      let s = 1 + Float(si) * 0.005
      for dy in -8...8 { for dx in -8...8 {
        let e = cost(a, b, s, Float(dx) * px, Float(dy) * py)
        if e < best.e { best = (s, Float(dx) * px, Float(dy) * py, e) }
      } }
    }
    // fino: ±0,4% e ±1 px em passos de 0,25 px
    let c = best
    for si in -2...2 { for dy in -4...4 { for dx in -4...4 {
      let s = c.s + Float(si) * 0.002, tx = c.tx + Float(dx) * px * 0.25, ty = c.ty + Float(dy) * py * 0.25
      let e = cost(a, b, s, tx, ty)
      if e < best.e { best = (s, tx, ty, e) }
    } } }
    return (SwitchGeometry(s: best.s, tx: best.tx, ty: best.ty), best.e, err0)
  }
}
