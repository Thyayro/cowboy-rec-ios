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
  var exact = false   // troca medida (0.8.0): já só amplia e o deslocamento cabe na sobra — sem zoom de cobertura
  static let identity = SwitchGeometry()
  var isIdentity: Bool { abs(s - 1) < 0.0005 && abs(tx) < 0.0005 && abs(ty) < 0.0005 }
  var cover: Float { exact ? 1 : 1 + 2 * max(abs(tx), abs(ty)) + max(0, 1 - s) * 1.05 }
  func mix(_ k: Float) -> SwitchGeometry { SwitchGeometry(s: 1 + (s - 1) * k, tx: tx * k, ty: ty * k, exact: exact) }
}

final class SwitchAligner: @unchecked Sendable {
  static let w = 96, h = 54
  static let glide = 0.6
  private let lock = NSLock()
  private var last: [String: (lens: String, t: Double, img: [Float])] = [:]
  private var transitions: [String: [(t0: Double, lens: String, g: SwitchGeometry)]] = [:]
  var lensAt: ((Double) -> String)?
  var onAlign: ((String, SwitchGeometry, Float, Float) -> Void)?
  // MEDIÇÃO DO ESTACIONAR (v3): guarda os quadros crus da tela de 0,3 s ANTES do zoom parar até 2 s depois e compara cada um
  // com o quadro FINAL (v2 começava 0,3 s depois de parar e não via a volta). Por quadro: zoom relativo ao final (>1 = mais
  // perto que o final), deslizamento em px (de 96×54) + estado da câmera. "volta" = quanto andou CONTRA o sentido de chegada.
  private var settleT0 = 0.0
  private var settleActive = false
  private var settleFrames: [(Double, [Float], String, Double)] = []
  // o que a tela mostra: prévia sem atraso = quadro rápido; prévia estabilizada = quadro estabilizado × ampliação da tela
  var settleStream: () -> String = { "fast" }
  var displayScale: ((Double) -> Double?)?
  private var settleTag = ""
  private let settleQueue = DispatchQueue(label: "cowboy.settle", qos: .utility)
  var onSettle: ((String, Float, String) -> Void)?   // quadros, volta, etiqueta do passo
  var probe: (() -> String)?   // estado real no quadro (zoom, lente, rampa, lente de foco, corte e correção da estabilização da tela)
  func startSettle(_ t: Double, tag: String = "") { lock.lock(); settleT0 = t; settleActive = true; settleFrames = []; settleTag = tag; lock.unlock() }
  // escala (como cost: <1 = imagem mais perto que a referência) + deslocamento em px
  static func scaleShiftVsRef(_ ref: [Float], _ img: [Float]) -> (s: Float, dx: Float, dy: Float) {
    var b = (s: Float(1), dx: Float(0), dy: Float(0), e: Float.infinity)
    func try1(_ s: Float, _ dx: Float, _ dy: Float) { let e = cost(ref, img, s, dx / Float(w), dy / Float(h)); if e < b.e { b = (s, dx, dy, e) } }
    for si in -10...10 { for dy in -5...5 { for dx in -5...5 { try1(1 + Float(si) * 0.01, Float(dx), Float(dy)) } } }
    var c = b
    for si in -4...4 { for dy in -1...1 { for dx in -1...1 { try1(c.s + Float(si) * 0.0025, c.dx + Float(dx), c.dy + Float(dy)) } } }
    c = b
    for si in -5...5 { for dy in -2...2 { for dx in -2...2 { try1(c.s + Float(si) * 0.0005, c.dx + Float(dx) * 0.25, c.dy + Float(dy) * 0.25) } } }
    return (b.s, b.dx, b.dy)
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
    var done: [(Double, [Float], String, Double)]?; let tag = settleTag
    if settleActive && stream == settleStream() && t >= settleT0 - 0.3 {
      let dt = t - settleT0
      if dt >= 2.0 { done = settleFrames + [(dt, img, "", t)]; settleActive = false; settleFrames = [] }
      else { lock.unlock(); let st = probe?() ?? ""; lock.lock(); settleFrames.append((dt, img, st, t)) }
    }
    lock.unlock()
    if let done {
      // conta pesada fora da fila dos quadros (nunca segura quadro da câmera — 0.6.1)
      let measured = stream, disp = displayScale
      settleQueue.async { [weak self] in
        // tamanho na tela = tamanho no quadro × ampliação da tela (só na prévia estabilizada; quadro não desenhado fica fora)
        let shown: [((Double, [Float], String, Double), Double)] = done.compactMap { f in
          if measured != "stab" { return (f, 1) }
          return disp?(f.3).map { (f, $0) }
        }
        guard let last = shown.last else { return }
        var parts: [String] = []; var zs: [Float] = []
        for (i, e) in shown.dropLast().enumerated() where e.0.0 < 1.0 || i % 3 == 0 {
          let f = e.0
          let r = Self.scaleShiftVsRef(last.0.1, f.1); let z = 1 / r.s * Float(e.1 / last.1); zs.append(z)
          parts.append(String(format: "%.0f:%.4f,%.1f,%.1f", f.0 * 1000, z, r.dx, r.dy) + (measured == "stab" ? String(format: ",k%.4f", e.1) : "") + "[" + f.2 + "]")
        }
        var back: Float = 0
        if let first = zs.first {
          let dir: Float = 1 - first >= 0 ? 1 : -1   // chegando de mais longe (zoom in) ou de mais perto (zoom out)
          var peak = first
          for z in zs { if (z - peak) * dir >= 0 { peak = z } else { back = max(back, abs(z - peak)) } }
          back = max(back, zs.map { ($0 - 1) * dir }.max() ?? 0)   // passou do final e voltou (ultrapassagem)
        }
        self?.onSettle?(measured + " " + parts.joined(separator: " "), back, tag)
      }
    }
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
