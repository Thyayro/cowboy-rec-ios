import CoreVideo
import Foundation

// DEFASAGEM DO ZOOM APRENDIDA NA IMAGEM (0.7.4) — prévia ESTABILIZADA ("Prévia sem atraso" desligada).
// O quadro estabilizado chega ~0,5–1 s atrasado e a tela o amplia pro zoom de agora: k = zoom pedido agora ÷ zoom do
// CONTEÚDO do quadro. O zoom do conteúdo era tomado como o zoom PEDIDO no instante do quadro — mas o sensor/estabilizador
// aplicam o zoom DEFASADOS (d) e às vezes suavizados (τ) em relação ao pedido. Simulado 08/10: d = ±33 ms já dá 6–7% de
// vai-e-volta no clique; ±100 ms, 20%+ (zoom out não amplia, por isso ficava certo). A intrínseca do iPhone não serve
// (0.7.3: fx não acompanha o zoom digital).
// Aqui: a cada zoom, quadros estabilizados consecutivos são medidos NA IMAGEM (miniatura 96×54 passa-alta, escala +
// deslocamento) e o par (d, τ) que melhor explica as medidas é ajustado (mínimos quadrados robustos); a tela usa
// zoom do conteúdo = zoom pedido em (t − d), suavizado por τ. Um número só pro aparelho — nada de erro de medida somando
// quadro a quadro. Só aprende com medida CONFIÁVEL (cena com textura/luz; à noite a medida erra 2–3% e enviesaria — fica
// o valor já aprendido, ou a conta antiga). Guardado no aparelho; cada zoom bom refina.
final class ZoomTiming: @unchecked Sendable {
  static let w = SwitchAligner.w, h = SwitchAligner.h
  static let minConf: Float = 0.04
  static let dGrid: [Double] = stride(from: -0.20, through: 0.2501, by: 0.01).map { $0 }
  static let tauGrid: [Double] = [0, 0.02, 0.04, 0.06, 0.08, 0.10, 0.12]
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "cowboy.zoomtiming", qos: .utility)
  private var d: Double
  private var tau: Double
  private var learnedN: Int
  var history: (() -> [(Double, Double)])?     // zoom pedido (hora, valor) — cópia
  var lensAt: ((Double) -> String)?
  var boundaries: [Double] = []                 // zoom bruto onde troca lente/modo do sensor (fora da medida)
  var onReport: ((String) -> Void)?
  // só na fila própria
  private var prev: (pts: Double, img: [Float], lens: String)?
  private var pairs: [(pa: Double, pb: Double, r: Double, conf: Float)] = []
  private var moving = 0
  private var unsure = 0
  private var backlog = 0

  init() {
    let u = UserDefaults.standard
    learnedN = u.integer(forKey: "zoomTimingN")
    d = learnedN > 0 ? u.double(forKey: "zoomTimingD") : 0
    tau = learnedN > 0 ? u.double(forKey: "zoomTimingTau") : 0
  }
  var params: (d: Double, tau: Double, learned: Bool) { lock.lock(); defer { lock.unlock() }; return (d, tau, learnedN > 0) }
  func reset() { queue.async { self.prev = nil; self.pairs.removeAll(); self.moving = 0; self.unsure = 0 } }

  // zoom pedido interpolado no instante t (histórico em ordem de tempo)
  static func at(_ hist: [(Double, Double)], _ t: Double) -> Double {
    guard let first = hist.first, let last = hist.last else { return 0 }
    if t <= first.0 { return first.1 }
    if t >= last.0 { return last.1 }
    var lo = 0, hi = hist.count - 1
    while hi - lo > 1 { let mid = (lo + hi) / 2; if hist[mid].0 <= t { lo = mid } else { hi = mid } }
    let a = hist[lo], b = hist[hi]
    return a.1 + (b.1 - a.1) * (t - a.0) / max(1e-4, b.0 - a.0)
  }
  // zoom do conteúdo do quadro captado em p: pedido em (p − d), suavizado (média exponencial τ pra trás)
  static func model(_ hist: [(Double, Double)], _ p: Double, _ d: Double, _ tau: Double) -> Double {
    if tau <= 0.001 { return at(hist, p - d) }
    var acc = 0.0, wsum = 0.0, x = 0.0
    while x < 6 * tau { let w = exp(-x / tau); acc += at(hist, p - d - x) * w; wsum += w; x += 0.005 }
    return acc / wsum
  }

  // fila dos quadros: só a miniatura (≈0,3 ms); medida e ajuste na fila própria
  func submit(_ buffer: CVPixelBuffer, pts: Double) {
    guard let img = Self.thumb(buffer) else { return }
    lock.lock(); backlog += 1; let late = backlog > 3; lock.unlock()
    queue.async {
      self.process(Self.prep(img), pts: pts, skipMeasure: late)
      self.lock.lock(); self.backlog -= 1; self.lock.unlock()
    }
  }
  private func process(_ img: [Float], pts: Double, skipMeasure: Bool) {
    let lens = lensAt?(pts) ?? ""
    defer { prev = (pts, img, lens) }
    guard let pv = prev, pts > pv.pts, pts - pv.pts < 0.1, let hist = history?(), hist.count > 20 else { return }
    let a = Self.at(hist, pv.pts - 0.3), b = Self.at(hist, pts + 0.3)
    guard a > 0, b > 0 else { return }
    if abs(log(b / a)) > 1e-4 {
      moving += 1
      let lo0 = min(a, b), hi0 = max(a, b)
      let crosses = boundaries.contains { $0 > lo0 * 0.999 && $0 < hi0 * 1.001 }
      guard !skipMeasure, pv.lens == lens, !crosses else { return }
      let cur = params
      var lo = Double.infinity, hi = 0.0
      for dd in [Self.dGrid.first!, cur.d, Self.dGrid.last!] { for tt in [0, Self.tauGrid.last!] {
        let r = Self.model(hist, pts, dd, tt) / Self.model(hist, pv.pts, dd, tt); lo = min(lo, r); hi = max(hi, r)
      } }
      lo /= 1.015; hi *= 1.015
      guard hi / lo < 1.6 else { return }
      let m = Self.register(pv.img, img, lo: lo, hi: hi)
      if m.conf >= Self.minConf { pairs.append((pv.pts, pts, m.r, m.conf)) } else { unsure += 1 }
    } else if moving > 0 {
      let n = moving, u = unsure
      moving = 0; unsure = 0
      let ps = pairs; pairs.removeAll()
      guard ps.count >= 8 else {
        onReport?(String(format: "zoom de %d quadros: %d medidas confiáveis, %d sem textura — não aprende (fica d%+.0fms τ%.0fms)", n, ps.count, u, params.d * 1000, params.tau * 1000))
        return
      }
      fit(ps, hist, frames: n)
    }
  }
  private func fit(_ ps: [(pa: Double, pb: Double, r: Double, conf: Float)], _ hist: [(Double, Double)], frames: Int) {
    func err(_ dd: Double, _ tt: Double) -> Double {
      var e = 0.0
      for q in ps {
        let x = abs(log(q.r) - log(Self.model(hist, q.pb, dd, tt) / Self.model(hist, q.pa, dd, tt)))
        e += x < 0.01 ? x * x : 0.01 * (2 * x - 0.01)
      }
      return e
    }
    var best = (e: Double.infinity, d: 0.0, t: 0.0)
    for dd in Self.dGrid { for tt in Self.tauGrid { let e = err(dd, tt); if e < best.e { best = (e, dd, tt) } } }
    let c = best
    for i in -5...5 { for j in -4...4 {
      let dd = c.d + Double(i) * 0.002, tt = max(0, c.t + Double(j) * 0.005)
      let e = err(dd, tt); if e < best.e { best = (e, dd, tt) }
    } }
    let cur = params
    let e0 = err(0, 0), eCur = err(cur.d, cur.tau)
    // aceita se explica as medidas bem melhor que a conta antiga (ou que o valor atual)
    let accept = best.e < 0.7 * min(e0, eCur) || (cur.learned && best.e < eCur)
    var txt = String(format: "zoom de %d quadros, %d medidas: melhor d%+.0fms τ%.0fms (erro %.2e) × antiga %.2e × atual d%+.0fms τ%.0fms %.2e",
      frames, ps.count, best.d * 1000, best.t * 1000, best.e, e0, cur.d * 1000, cur.tau * 1000, eCur)
    if accept {
      lock.lock()
      if learnedN == 0 { d = best.d; tau = best.t } else { d = 0.5 * d + 0.5 * best.d; tau = 0.5 * tau + 0.5 * best.t }
      learnedN += 1
      let (nd, nt, nn) = (d, tau, learnedN)
      lock.unlock()
      let u = UserDefaults.standard
      u.set(nd, forKey: "zoomTimingD"); u.set(nt, forKey: "zoomTimingTau"); u.set(nn, forKey: "zoomTimingN")
      txt += String(format: " → APRENDIDO d%+.0fms τ%.0fms (%d)", nd * 1000, nt * 1000, nn)
    } else { txt += " → mantém" }
    onReport?(txt)
  }

  // ---- imagem
  // miniatura 96×54 direto do plano de luz (Y), média de 4×4 amostras por ponto (sem serrilhado), 8 ou 10 bits
  static func thumb(_ buffer: CVPixelBuffer) -> [Float]? {
    guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
    let W = CVPixelBufferGetWidthOfPlane(buffer, 0), H = CVPixelBufferGetHeightOfPlane(buffer, 0), row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    guard W >= w * 4, H >= h * 4 else { return nil }
    let sixteen = LutBaker.tenBit.contains(CVPixelBufferGetPixelFormatType(buffer))
    // posições das 4×4 amostras de cada ponto, calculadas uma vez (a leitura em si fica só carregar e somar)
    let bpp = sixteen ? 2 : 1
    let xs = (0..<(w * 4)).map { min(W - 1, Int((Double($0) + 0.5) / 4 * Double(W) / Double(w))) * bpp }
    let ys = (0..<(h * 4)).map { min(H - 1, Int((Double($0) + 0.5) / 4 * Double(H) / Double(h))) * row }
    var out = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
      for x in 0..<w {
        var acc: Float = 0
        for sy in 0..<4 { let ro = ys[y * 4 + sy]
          for sx in 0..<4 {
            let o = ro + xs[x * 4 + sx]
            acc += sixteen ? Float(base.load(fromByteOffset: o, as: UInt16.self)) / 65535 : Float(base.load(fromByteOffset: o, as: UInt8.self)) / 255
          } }
        out[y * w + x] = acc / 16
      }
    }
    return out
  }
  // passa-alta (tira vinheta e sombreamento, que não mudam com o zoom e puxariam a medida pra "parado") + normaliza
  static func prep(_ a: [Float]) -> [Float] {
    let r = 4
    var tmp = [Float](repeating: 0, count: w * h), blur = [Float](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w {
      var s: Float = 0
      for k in -r...r { s += a[y * w + min(w - 1, max(0, x + k))] }
      tmp[y * w + x] = s / Float(2 * r + 1)
    } }
    for y in 0..<h { for x in 0..<w {
      var s: Float = 0
      for k in -r...r { s += tmp[min(h - 1, max(0, y + k)) * w + x] }
      blur[y * w + x] = s / Float(2 * r + 1)
    } }
    var hp = [Float](repeating: 0, count: w * h)
    for i in 0..<(w * h) { hp[i] = a[i] - blur[i] }
    let n = Float(w * h), m = hp.reduce(0, +) / n
    let sd = max(1e-4, (hp.reduce(0) { $0 + ($1 - m) * ($1 - m) } / n).squareRoot())
    return hp.map { ($0 - m) / sd }
  }
  // diferença média entre a e b transformada (convenção do SwitchAligner.cost), amostrando 1 de cada `step` pontos
  static func cost(_ a: [Float], _ b: [Float], _ s: Float, _ tx: Float, _ ty: Float, step: Int) -> Float {
    let W = Float(w), H = Float(h); var sum: Float = 0; var n: Float = 0
    let x0 = Int(W * 0.12), x1 = w - x0, y0 = Int(H * 0.12), y1 = h - y0
    var y = y0
    while y < y1 {
      let v = ((Float(y) + 0.5) / H - 0.5 - ty) / s + 0.5
      let fy = v * H - 0.5; let iy = Int(fy.rounded(.down)); let ay = fy - Float(iy)
      if iy >= 0 && iy < h - 1 {
        var x = x0
        while x < x1 {
          let u = ((Float(x) + 0.5) / W - 0.5 - tx) / s + 0.5
          let fx = u * W - 0.5; let ix = Int(fx.rounded(.down)); let ax = fx - Float(ix)
          if ix >= 0 && ix < w - 1 {
            let i = iy * w + ix
            let bv = (b[i] * (1 - ax) + b[i + 1] * ax) * (1 - ay) + (b[i + w] * (1 - ax) + b[i + w + 1] * ax) * ay
            let d = a[y * w + x] - bv; sum += d * d; n += 1
          }
          x += step
        }
      }
      y += step
    }
    return n > 60 ? sum / n : .infinity
  }
  // razão de zoom b÷a entre lo e hi + confiança (quanto o custo sobe se a escala errar 0,6%; cena lisa ≈ 0)
  static func register(_ a: [Float], _ b: [Float], lo: Double, hi: Double) -> (r: Double, conf: Float) {
    var best = (s: Float(1 / (lo * hi).squareRoot()), dx: Float(0), dy: Float(0), e: Float.infinity)
    func t1(_ s: Float, _ dx: Float, _ dy: Float, _ step: Int) {
      let e = cost(a, b, s, dx / Float(w), dy / Float(h), step: step); if e < best.e { best = (s, dx, dy, e) }
    }
    let s0 = best.s
    for dy in -3...3 { for dx in -3...3 { t1(s0, Float(dx), Float(dy), 2) } }
    var c = best
    let n = Int((log(hi / lo) / log(1.0025)).rounded(.up))
    for i in 0...max(0, n) { t1(Float(1 / (lo * pow(1.0025, Double(i)))), c.dx, c.dy, 2) }
    c = best
    for si in -2...2 { for dy in -1...1 { for dx in -1...1 { t1(c.s * (1 + Float(si) * 0.0025), c.dx + Float(dx), c.dy + Float(dy), 2) } } }
    c = best; best.e = cost(a, b, c.s, c.dx / Float(w), c.dy / Float(h), step: 1)
    for si in -5...5 { for dy in -1...1 { for dx in -1...1 { t1(c.s * (1 + Float(si) * 0.0005), c.dx + Float(dx) * 0.5, c.dy + Float(dy) * 0.5, 1) } } }
    let e = best.e
    let ep = cost(a, b, best.s * 1.006, best.dx / Float(w), best.dy / Float(h), step: 1)
    let em = cost(a, b, best.s / 1.006, best.dx / Float(w), best.dy / Float(h), step: 1)
    let conf = e.isFinite && e > 0 ? ((ep + em) / 2 - e) / e : 0
    let r = 1 / Double(best.s)
    let edge = r < lo * 1.003 || r > hi / 1.003
    return (r, edge || !conf.isFinite ? 0 : conf)
  }
}
