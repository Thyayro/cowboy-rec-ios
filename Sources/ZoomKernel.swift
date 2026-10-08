import CoreVideo
import Foundation

// ZOOM DA PRÉVIA ESTABILIZADA, CALIBRADO NO APARELHO (0.7.5).
// A prévia estabilizada ("Prévia sem atraso" desligada) mostra o quadro do arquivo, que chega ~0,5–1 s atrasado; a tela o
// amplia pro zoom de agora: k = zoom agora ÷ zoom do CONTEÚDO do quadro. Tomar o conteúdo como "o zoom lido na hora de
// desenhar, no instante do quadro" errava (vai-e-volta no freio do zoom in); aprender um atraso contínuo sobre esse
// histórico (0.7.4) pulou de −190 a +90 ms entre gestos e piorou. Agora todo zoom é posto POR QUADRO pelo ZoomDriver com a
// HORA EXATA de cada valor; o quadro captado em p carrega o último valor posto até p − trava. A trava sai de uma
// CALIBRAÇÃO no aparelho (ZoomCalibration): degraus + cliques + pinça com o celular parado, razão de escala entre quadros
// estabilizados VIZINHOS medida na imagem, melhor trava por mínimos quadrados; depois a calibração VERIFICA (clique e pinça
// com a trava ligada, tela nova × antiga nos MESMOS quadros) e só liga se a nova provar. Senão fica a conta antiga.
// trava (quanto antes do quadro o valor precisa ter sido posto) + suavização (o estabilizador pode alisar o zoom: média
// exponencial dos valores postos pra trás, constante τ). τ = 0: o quadro carrega exatamente o último valor.
struct ZoomFit: Equatable { var lag: Double; var tau: Double
  var text: String { String(format: "trava %+.0fms%@", lag * 1000, tau > 0.001 ? String(format: " suaviza %.0fms", tau * 1000) : "") } }
enum ZoomLag {
  static func load() -> ZoomFit? {
    let u = UserDefaults.standard
    return u.bool(forKey: "zoomLagOn") ? ZoomFit(lag: u.double(forKey: "zoomLag"), tau: u.double(forKey: "zoomTau")) : nil
  }
  static func save(_ v: ZoomFit?) {
    let u = UserDefaults.standard
    if let v { u.set(v.lag, forKey: "zoomLag"); u.set(v.tau, forKey: "zoomTau"); u.set(true, forKey: "zoomLagOn") } else { u.set(false, forKey: "zoomLagOn") }
  }
  // zoom que o quadro captado em p carrega, pelo registro de valores postos
  static func model(_ sets: [(Double, Double)], _ p: Double, _ f: ZoomFit) -> Double? {
    if f.tau < 0.001 { return at(sets, p - f.lag) }
    let step = 0.004   // passo fino: com suavização o quadro depende continuamente do tempo (passo grosso enviesa ~3 ms)
    var acc = 0.0, ws = 0.0, u = 0.0
    while u < 5 * f.tau {
      guard let z = at(sets, p - f.lag - u), z > 0 else { break }
      let w = exp(-u / f.tau); acc += w * Foundation.log(z); ws += w; u += step
    }
    return ws > 0 ? exp(acc / ws) : at(sets, p - f.lag)
  }
  // valor do registro (hora, zoom) vigente em t
  static func at(_ log: [(Double, Double)], _ t: Double) -> Double? {
    guard let first = log.first, t >= first.0 else { return nil }
    var lo = 0, hi = log.count - 1
    if log[hi].0 <= t { return log[hi].1 }
    while hi - lo > 1 { let mid = (lo + hi) / 2; if log[mid].0 <= t { lo = mid } else { hi = mid } }
    return log[lo].1
  }
  // histórico lido na tela (conta antiga): interpolado
  static func hist(_ h: [(Double, Double)], _ t: Double) -> Double? {
    guard let first = h.first, let last = h.last else { return nil }
    if t <= first.0 { return first.1 }
    if t >= last.0 { return last.1 }
    var lo = 0, hi = h.count - 1
    while hi - lo > 1 { let mid = (lo + hi) / 2; if h[mid].0 <= t { lo = mid } else { hi = mid } }
    let a = h[lo], b = h[hi]
    return a.1 + (b.1 - a.1) * (t - a.0) / max(1e-4, b.0 - a.0)
  }
}

// ---- imagem (miniatura 96×54 do plano de luz e medida de escala contra uma referência)
enum ZoomImage {
  static let w = SwitchAligner.w, h = SwitchAligner.h
  static let sub = 8
  // média de 8×8 amostras por ponto (sem serrilhado, pouco ruído), 8 ou 10 bits; ≈0,5 ms em 4K
  static func thumb(_ buffer: CVPixelBuffer) -> [Float]? {
    guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
    let W = CVPixelBufferGetWidthOfPlane(buffer, 0), H = CVPixelBufferGetHeightOfPlane(buffer, 0), row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let sub = min(Self.sub, W / w, H / h)   // quadro pequeno (saída em tamanho de tela): menos amostras por ponto
    guard sub >= 2 else { return nil }
    let sixteen = LutBaker.tenBit.contains(CVPixelBufferGetPixelFormatType(buffer))
    let bpp = sixteen ? 2 : 1
    var xs = [Int](repeating: 0, count: w * sub), ys = [Int](repeating: 0, count: h * sub)
    let fw = Double(W) / Double(w * sub), fh = Double(H) / Double(h * sub)
    for i in 0..<(w * sub) { let px: Int = Int((Double(i) + 0.5) * fw); xs[i] = min(W - 1, px) * bpp }
    for i in 0..<(h * sub) { let py: Int = Int((Double(i) + 0.5) * fh); ys[i] = min(H - 1, py) * row }
    let scale: Float = (sixteen ? 1 / 65535 : 1 / 255) / Float(sub * sub)
    var out = [Float](repeating: 0, count: w * h)
    for y in 0..<h {
      for x in 0..<w {
        var acc: UInt32 = 0
        for sy in 0..<sub {
          let ro = ys[y * sub + sy]
          for sx in 0..<sub {
            let o = ro + xs[x * sub + sx]
            if sixteen { acc &+= UInt32(base.load(fromByteOffset: o, as: UInt16.self)) } else { acc &+= UInt32(base.load(fromByteOffset: o, as: UInt8.self)) }
          }
        }
        out[y * w + x] = Float(acc) * scale
      }
    }
    return out
  }
  // desfoque leve [1 2 1]/4 (sem ele o ruído puxa a medida: a interpolação "alisa" ruído fora do ponto certo e o custo
  // cai ali — 0,78% de erro em quadros PARADOS no teste; com ele, 0,11%) + passa-alta (tira vinheta e sombreamento, que
  // não mudam com o zoom) + normaliza
  static func prep(_ src: [Float]) -> [Float] {
    var t0 = [Float](repeating: 0, count: w * h), a = [Float](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w {
      let l = src[y * w + max(0, x - 1)], c = src[y * w + x], rr = src[y * w + min(w - 1, x + 1)]
      t0[y * w + x] = 0.25 * l + 0.5 * c + 0.25 * rr
    } }
    for y in 0..<h { for x in 0..<w {
      let u = t0[max(0, y - 1) * w + x], c = t0[y * w + x], d = t0[min(h - 1, y + 1) * w + x]
      a[y * w + x] = 0.25 * u + 0.5 * c + 0.25 * d
    } }
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
  // zoom de img relativo a ref (>1 = img mais perto) entre lo e hi, + confiança (quanto o custo sobe errando 0,6%)
  static func vsRef(_ ref: [Float], _ img: [Float], lo: Double = 0.72, hi: Double = 1.40, shift: Int = 2) -> (z: Double, conf: Float) {
    let r = vsRefFull(ref, img, lo: lo, hi: hi, shift: shift); return (r.z, r.conf)
  }
  static func vsRefFull(_ ref: [Float], _ img: [Float], lo: Double = 0.72, hi: Double = 1.40, shift: Int = 2) -> (z: Double, conf: Float, resid: Float) {
    var best = (s: Float(1), dx: Float(0), dy: Float(0), e: Float.infinity)
    func t1(_ s: Float, _ dx: Float, _ dy: Float, _ step: Int) {
      let e = cost(ref, img, s, dx / Float(w), dy / Float(h), step: step); if e < best.e { best = (s, dx, dy, e) }
    }
    let n = Int((log(hi / lo) / log(1.01)).rounded(.up))
    for i in 0...n { t1(Float(1 / (lo * pow(1.01, Double(i)))), 0, 0, 2) }
    var c = best
    for dy in -shift...shift { for dx in -shift...shift { t1(c.s, Float(dx), Float(dy), 2) } }
    c = best; best.e = cost(ref, img, c.s, c.dx / Float(w), c.dy / Float(h), step: 1)
    for si in -5...5 { for dy in -1...1 { for dx in -1...1 { t1(c.s * (1 + Float(si) * 0.002), c.dx + Float(dx) * 0.5, c.dy + Float(dy) * 0.5, 1) } } }
    c = best
    for si in -5...5 { for dy in -1...1 { for dx in -1...1 { t1(c.s * (1 + Float(si) * 0.0004), c.dx + Float(dx) * 0.25, c.dy + Float(dy) * 0.25, 1) } } }
    let e = best.e
    let ep = cost(ref, img, best.s * 1.006, best.dx / Float(w), best.dy / Float(h), step: 1)
    let em = cost(ref, img, best.s / 1.006, best.dx / Float(w), best.dy / Float(h), step: 1)
    let conf = e.isFinite && e > 0 ? ((ep + em) / 2 - e) / e : 0
    return (1 / Double(best.s), conf.isFinite ? conf : 0, e)
  }
}

// gravação das miniaturas durante a calibração (só nas janelas de medida)
final class ZoomCalibRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var on = false
  private var withFast = true
  private var fast: [(Double, [Float])] = []
  private var stab: [(Double, [Float])] = []
  var active: Bool { lock.lock(); defer { lock.unlock() }; return on }
  func begin(fast f: Bool = true) { lock.lock(); on = true; withFast = f; fast = []; stab = []; lock.unlock() }
  func end() -> (fast: [(Double, [Float])], stab: [(Double, [Float])]) { lock.lock(); defer { lock.unlock() }; on = false; let r = (fast, stab); fast = []; stab = []; return r }
  func feed(_ buffer: CVPixelBuffer, pts: Double, stabilized: Bool) {
    lock.lock(); let want = on && (stabilized || withFast); lock.unlock()
    guard want, let t = ZoomImage.thumb(buffer) else { return }
    lock.lock(); if on { if stabilized { stab.append((pts, t)) } else { fast.append((pts, t)) } }; lock.unlock()
  }
}

// ---- matemática da calibração (separada do app pra rodar no teste do build)
struct CalibWindow {
  let name: String; let stab: [(Double, [Float])]; let fast: [(Double, [Float])]; let setLog: [(Double, Double)]; let hist: [(Double, Double)]
  let shown: [(pts: Double, k: Double, kOld: Double, at: Double)]; let tFirst: Double; let tLast: Double
}
struct PairMeas { let a: Double; let b: Double; let r: Double; let conf: Float }
enum ZoomCalibMath {
  // razões medidas entre quadros vizinhos (só no trecho em que o zoom pode mudar)
  static func neighborRatios(_ frames: [(Double, [Float])], from: Double, to: Double) -> [PairMeas] {
    var out: [PairMeas] = []
    var prev: (Double, [Float])?
    for f in frames {
      defer { prev = (f.0, ZoomImage.prep(f.1)) }
      guard let p = prev, f.0 > p.0, f.0 - p.0 < 0.03, f.0 >= from, f.0 <= to else { continue }
      let m = ZoomImage.vsRef(p.1, ZoomImage.prep(f.1), lo: 0.75, hi: 1.35)
      out.append(PairMeas(a: p.0, b: f.0, r: m.z, conf: m.conf))
    }
    return out
  }
  // "tela quieta": 99% dos erros no nível do ruído da medida e nenhum do tamanho de um quadro trocado (≈1,4% num clique);
  // com centenas de pares o MAIOR erro de puro ruído já passa de 3σ, por isso o máximo tem folga maior
  static func quiet(_ res: [Double], _ floor: Double) -> Bool {
    guard !res.isEmpty else { return false }
    let a = res.map { abs($0) }.sorted()
    let p99 = a[min(a.count - 1, Int(Double(a.count) * 0.99))]
    return p99 <= max(3 * floor, 0.004) && a.last! <= max(6 * floor, 0.008)
  }
  static func huber(_ x: Double) -> Double { let a = abs(x); return a < 0.01 ? a * a : 0.01 * (2 * a - 0.01) }
  // erro médio das razões medidas × previstas (modelo = registro exato; nil = conta antiga pelo histórico da tela)
  static func lagError(_ pairs: [(PairMeas, CalibWindow)], _ fit: ZoomFit?) -> (Double, Int) {
    var e = 0.0, n = 0
    for (m, w) in pairs {
      let za: Double?, zb: Double?
      if let fit { za = ZoomLag.model(w.setLog, m.a, fit); zb = ZoomLag.model(w.setLog, m.b, fit) } else { za = ZoomLag.hist(w.hist, m.a); zb = ZoomLag.hist(w.hist, m.b) }
      guard let za, let zb, za > 0, zb > 0 else { continue }
      e += huber(log(m.r) - log(zb / za)); n += 1
    }
    return (n > 0 ? e / Double(n) : .infinity, n)
  }
  static func bestFit(_ pairs: [(PairMeas, CalibWindow)]) -> (ZoomFit, Double, Int)? { search { lagError(pairs, $0) } }
  // busca: 1) só trava (τ = 0), meio da faixa equivalente; 2) com suavização perto dela — só fica com suavização se ela
  // explica as medidas CLARAMENTE melhor (≥10%), pra não inventar suavização com ruído; 3) refino
  static func search(_ errAt: (ZoomFit) -> (Double, Int)) -> (ZoomFit, Double, Int)? {
    var c0: [(Double, Double, Int)] = []
    var lag = -0.10
    while lag <= 0.1201 { let r = errAt(ZoomFit(lag: lag, tau: 0)); if r.1 > 0 { c0.append((lag, r.0, r.1)) }; lag += 0.002 }
    guard let b0 = plateauCenter(c0) else { return nil }
    var best = (ZoomFit(lag: b0.0, tau: 0), b0.1, b0.2)
    for tau in [0.015, 0.03, 0.045, 0.06, 0.09] {
      var c: [(Double, Double, Int)] = []
      var l = b0.0 - 0.07
      while l <= b0.0 + 0.0201 { let r = errAt(ZoomFit(lag: l, tau: tau)); if r.1 > 0 { c.append((l, r.0, r.1)) }; l += 0.004 }
      // com suavização o erro varia contínuo com a trava (sem faixa equivalente): vale o mínimo
      if let m = c.min(by: { $0.1 < $1.1 }), m.1 < best.1 * (best.0.tau > 0 ? 1 : 0.9) { best = (ZoomFit(lag: m.0, tau: tau), m.1, m.2) }
    }
    if best.0.tau > 0 {
      for dl in stride(from: -0.006, through: 0.0061, by: 0.001) { for dt in [-0.01, -0.005, 0, 0.005, 0.01] {
        let f = ZoomFit(lag: best.0.lag + dl, tau: max(0.005, best.0.tau + dt)); let r = errAt(f)
        if r.1 > 0 && r.0 < best.1 { best = (f, r.0, r.1) }
      } }
    }
    return best
  }
  // várias travas dão EXATAMENTE os mesmos quadros (o valor posto só entra no próximo quadro que a trava alcança): erro
  // igual numa faixa. Escolhe o MEIO da faixa do mínimo — o mais longe das bordas, onde o jitter de entrega troca o quadro.
  static func plateauCenter(_ curve: [(Double, Double, Int)]) -> (Double, Double, Int)? {
    guard let best = curve.min(by: { $0.1 < $1.1 }), let i = curve.firstIndex(where: { $0.0 == best.0 }) else { return nil }
    let tol = best.1 * 1.02 + 1e-9
    var lo = i, hi = i
    while lo > 0 && curve[lo - 1].1 <= tol { lo -= 1 }
    while hi < curve.count - 1 && curve[hi + 1].1 <= tol { hi += 1 }
    let mid = curve[(lo + hi) / 2]
    return (mid.0, mid.1, mid.2)
  }
  // VERIFICAÇÃO em janelas que NÃO entraram no ajuste: nos pares de quadros estabilizados vizinhos, quanto a razão medida
  // na imagem foge da prevista pela trava (nova) e pela conta antiga. Parados (nenhuma prevê mudança) = ruído da medida.
  // Liga só se a nova erra bem menos que a antiga e o maior erro dela fica no nível do ruído (sem salto na tela).
  static func verify(_ ws: [CalibWindow], fit: ZoomFit) -> (ok: Bool, eNew: Double, eOld: Double, maxNew: Double, maxOld: Double, floor: Double, n: Int) {
    var rn: [Double] = [], ro: [Double] = [], still: [Double] = []
    for w in ws {
      for m in neighborRatios(w.stab, from: w.tFirst - 0.3, to: w.tLast + 0.9) where m.conf >= 0.04 {
        guard let na = ZoomLag.model(w.setLog, m.a, fit), let nb = ZoomLag.model(w.setLog, m.b, fit), let oa = ZoomLag.hist(w.hist, m.a), let ob = ZoomLag.hist(w.hist, m.b),
          na > 0, nb > 0, oa > 0, ob > 0 else { continue }
        let pn = log(nb / na), po = log(ob / oa), mr = log(m.r)
        if abs(pn) < 1e-6 && abs(po) < 1e-6 { still.append(mr) } else { rn.append(mr - pn); ro.append(mr - po) }
      }
    }
    func ms(_ v: [Double]) -> Double { v.isEmpty ? .infinity : v.reduce(0) { $0 + $1 * $1 } / Double(v.count) }
    let floor = still.count >= 5 ? ms(still).squareRoot() : 0.002
    let eN = ms(rn), eO = ms(ro)
    let mN = rn.map { abs($0) }.max() ?? .infinity, mO = ro.map { abs($0) }.max() ?? .infinity
    let ok = rn.count >= 20 && eN <= 0.7 * eO && quiet(rn, floor)
    return (ok, eN, eO, mN, mO, floor, rn.count)
  }

  // ---- APRENDIZADO NO USO NORMAL (0.7.6): cada zoom do filmmaker vira uma amostra só com as medidas (sem imagens)
  static func sample(stab: [(Double, [Float])], setLog: [(Double, Double)], hist: [(Double, Double)], tFirst: Double, tLast: Double,
                     lensAt: (Double) -> String, boundaries: [Double]) -> GestureSample {
    // fora: perto de troca de lente (o iPhone troca ~0,6 s depois e alisa a troca por ~0,8 s) e de fronteira de modo do sensor
    var changes: [Double] = []
    var prevLens: String?
    for f in stab { let l = lensAt(f.0); if let p = prevLens, p != l { changes.append(f.0) }; prevLens = l }
    func near(_ t: Double) -> Bool {
      if changes.contains(where: { t >= $0 - 0.05 && t <= $0 + 0.8 }) { return true }
      let vals = setLog.filter { $0.0 >= t - 0.7 && $0.0 <= t + 0.1 }.map { $0.1 } + [ZoomLag.at(setLog, t - 0.7) ?? 0].filter { $0 > 0 }
      guard let lo = vals.min(), let hi = vals.max() else { return false }
      return boundaries.contains { $0 > lo * 0.999 && $0 < hi * 1.001 }
    }
    let pairs = neighborRatios(stab, from: tFirst - 0.3, to: tLast + 0.9).filter { $0.conf >= 0.04 && !near($0.a) && !near($0.b) }
    let a = tFirst - 1.0, b = tLast + 1.5
    var sl = setLog.filter { $0.0 >= a - 2 && $0.0 <= b }
    if let before = setLog.last(where: { $0.0 < a - 2 }) { sl.insert(before, at: 0) }   // valor vigente antes do recorte
    return GestureSample(pairs: pairs, setLog: sl, hist: hist.filter { $0.0 >= a && $0.0 <= b }, tFirst: tFirst, tLast: tLast)
  }
  // resíduos (medido − previsto) com a trava e com a conta antiga; parados = nenhum dos dois prevê mudança
  static func residuals(_ g: GestureSample, fit: ZoomFit) -> (new: [Double], old: [Double], still: [Double]) {
    var rn: [Double] = [], ro: [Double] = [], st: [Double] = []
    for m in g.pairs {
      guard let na = ZoomLag.model(g.setLog, m.a, fit), let nb = ZoomLag.model(g.setLog, m.b, fit), let oa = ZoomLag.hist(g.hist, m.a), let ob = ZoomLag.hist(g.hist, m.b),
        na > 0, nb > 0, oa > 0, ob > 0 else { continue }
      let pn = log(nb / na), po = log(ob / oa), mr = log(m.r)
      if abs(pn) < 1e-6 && abs(po) < 1e-6 { st.append(mr) } else { rn.append(mr - pn); ro.append(mr - po) }
    }
    return (rn, ro, st)
  }
  static func bestFit(_ gs: [GestureSample]) -> (ZoomFit, Double, Int)? {
    search { f in
      var e = 0.0, n = 0
      for g in gs { for m in g.pairs {
        guard let za = ZoomLag.model(g.setLog, m.a, f), let zb = ZoomLag.model(g.setLog, m.b, f), za > 0, zb > 0 else { continue }
        e += huber(log(m.r) - log(zb / za)); n += 1
      } }
      return (n > 0 ? e / Double(n) : .infinity, n)
    }
  }
  static func moving(_ g: GestureSample) -> Int { residuals(g, fit: ZoomFit(lag: 0.02, tau: 0)).new.count }
  // decisão: validação cruzada (deixa um gesto de fora, ajusta nos outros, mede no de fora); liga só se a nova erra bem
  // menos que a antiga nos gestos de fora, o maior erro dela fica no nível do ruído e a trava é a mesma em todos
  static func decide(_ gs0: [GestureSample]) -> (fit: ZoomFit?, txt: String) {
    let gs = Array(gs0.filter { moving($0) >= 6 }.suffix(6))
    guard gs.count >= 3 else { return (nil, "gestos úteis \(gs.count)/3") }
    var rn: [Double] = [], ro: [Double] = [], st: [Double] = [], lags: [Double] = []
    for i in 0..<gs.count {
      var rest = gs; rest.remove(at: i)
      guard let f = bestFit(rest) else { continue }
      lags.append(f.0.lag + f.0.tau)   // atraso efetivo (trava + suavização) tem que bater entre as dobras
      let r = residuals(gs[i], fit: f.0); rn += r.new; ro += r.old; st += r.still
    }
    func ms(_ v: [Double]) -> Double { v.isEmpty ? .infinity : v.reduce(0) { $0 + $1 * $1 } / Double(v.count) }
    let floor = st.count >= 5 ? ms(st).squareRoot() : 0.002
    let eN = ms(rn), eO = ms(ro), mN = rn.map { abs($0) }.max() ?? .infinity, mO = ro.map { abs($0) }.max() ?? .infinity
    let spread = (lags.max() ?? 0) - (lags.min() ?? 0)
    guard let g = bestFit(gs) else { return (nil, "sem ajuste") }
    let ok = rn.count >= 30 && eN <= 0.7 * eO && quiet(rn, floor) && spread <= 0.012
    let txt = String(format: "gestos %d pares %d | %@ (dobras %+.0f…%+.0f) | erro nova %.2e antiga %.2e | maior nova %.2f%% antiga %.2f%% | ruído %.2f%%",
                     gs.count, rn.count, g.0.text, (lags.min() ?? 0) * 1000, (lags.max() ?? 0) * 1000, eN, eO, mN * 100, mO * 100, floor * 100)
    return (ok ? g.0 : nil, (ok ? "LIGA " : "ainda não ") + txt)
  }
  // vigia depois de ligada: nos gestos recentes, a trava ainda erra menos que a conta antiga?
  static func stillGood(_ gs: [GestureSample], fit: ZoomFit) -> (ok: Bool, n: Int, eNew: Double, eOld: Double) {
    var rn: [Double] = [], ro: [Double] = []
    for g in gs { let r = residuals(g, fit: fit); rn += r.new; ro += r.old }
    func ms(_ v: [Double]) -> Double { v.isEmpty ? 0 : v.reduce(0) { $0 + $1 * $1 } / Double(v.count) }
    let eN = ms(rn), eO = ms(ro)
    return (rn.count < 30 || eN <= eO, rn.count, eN, eO)
  }
}
struct GestureSample {
  let pairs: [PairMeas]
  let setLog: [(Double, Double)]
  let hist: [(Double, Double)]
  let tFirst: Double
  let tLast: Double
}

// ZOOM REAL DE CADA QUADRO MEDIDO NA SAÍDA RÁPIDA (0.7.9). Descoberta do filmmaker (08/10): com o estabilizador DESLIGADO o
// zoom para perfeito — o quadro chega na hora e a tela não precisa adivinhar nada. Com a Extrema o quadro estabilizado chega
// ~0,5 s depois e a tela amplia ele pro zoom de agora; a ampliação adivinhava o zoom de cada quadro pelo zoom REGISTRADO, que
// anda 0–35 ms fora do aplicado (varia por gesto) -> passava do ponto 7–12% (medido na tela). Aqui não se adivinha: a saída
// rápida (sem estabilização, mesmo instante de captura de cada quadro estabilizado, chega em ~40 ms) é medida NA IMAGEM
// enquanto o zoom anda (quadro contra o anterior), e o zoom real de cada instante vira uma curva. Quando o quadro
// estabilizado daquele instante chega na tela: ampliação = zoom real do quadro rápido mais novo ÷ zoom real do quadro
// mostrado — a tela anda como a câmera sem estabilizador, com a imagem estabilizada. Fora do zoom não mede nada (calor).
// Cena sem textura (noite): a medida não convence e entra o zoom registrado com o adiantamento médio (conta da 0.7.8).
final class FastZoomTracker: @unchecked Sendable {
  private let lock = NSLock()
  private let queue = DispatchQueue(label: "cowboy.zoomtrack", qos: .userInitiated)
  private var prev: (pts: Double, z: Double)?
  // quadro de REFERÊNCIA: cada quadro novo é medido contra ele (não contra o vizinho) — o erro de medida (~0,2%) não se soma
  // quadro a quadro (44 passos num clique davam 1,2%), só a cada troca de referência (~8% de zoom: 3–5 passos num zoom)
  private var key: (pts: Double, img: [Float], acc: Double, predAcc: Double)?
  private var chain: [(Double, Double)] = []   // (pts, log do zoom real acumulado)
  private var acc = 0.0, predAcc = 0.0
  private(set) var measured = 0, guessed = 0
  private(set) var confs: [Float] = []
  private(set) var resids: [Float] = []
  func reset() { queue.async { self.prev = nil; self.key = nil; self.lock.lock(); self.chain.removeAll(); self.acc = 0; self.predAcc = 0; self.lock.unlock() } }
  // fila da saída rápida: só enfileira (a medida roda na fila própria, em ordem)
  func feed(pts: Double, zHist: Double, thumb: [Float]?, moving: Bool) { queue.async { self.step(pts: pts, zHist: zHist, thumb: thumb, moving: moving) } }
  // zHist = zoom registrado previsto pro instante do quadro (com o adiantamento médio); moving = o zoom pode estar mudando
  func step(pts: Double, zHist: Double, thumb: [Float]?, moving: Bool) {
    var pred = 1.0
    if let pv = prev, pts > pv.pts, zHist > 0, pv.z > 0 { pred = zHist / pv.z }
    prev = (pts, zHist)
    predAcc += log(pred)
    var next = acc + log(pred)   // sem medida: segue o registrado
    if moving, let thumb {
      let img = ZoomImage.prep(thumb)
      if let k = key, pts - k.pts < 0.45 {
        let expect = exp(predAcc - k.predAcc)                      // razão prevista contra a referência
        let lo = min(1, expect, exp(acc - k.acc)) / 1.06, hi = max(1, expect, exp(acc - k.acc)) * 1.06
        let m = ZoomImage.vsRefFull(k.img, img, lo: lo, hi: hi, shift: 4)
        confs.append(m.conf); resids.append(m.resid); if confs.count > 400 { confs.removeFirst(); resids.removeFirst() }
        if m.conf >= 0.04 && m.z > lo * 1.004 && m.z < hi / 1.004 {
          next = k.acc + log(m.z); measured += 1
          if abs(log(pred)) < 1e-6 && abs(next - acc) < 0.002 { next = acc }   // parado e dentro do ruído: parado
        } else { guessed += 1 }
        if abs(next - k.acc) > log(1.08) || pts - k.pts > 0.3 { key = (pts, img, next, predAcc) }
      } else { key = (pts, img, next, predAcc) }
    } else if !moving { key = nil }
    acc = next
    lock.lock(); chain.append((pts, acc)); if chain.count > 600 { chain.removeFirst(chain.count - 600) }; lock.unlock()
  }
  // zoom real do quadro rápido mais novo ÷ zoom real do quadro de horário t (nil = horário fora da curva)
  func ratio(newestOver t: Double) -> Double? {
    lock.lock(); defer { lock.unlock() }
    guard let first = chain.first, let last = chain.last, t >= first.0 - 0.02, t <= last.0 + 0.02 else { return nil }
    if t <= first.0 { return exp(last.1 - first.1) }
    if t >= last.0 { return 1 }
    var lo = 0, hi = chain.count - 1
    while hi - lo > 1 { let mid = (lo + hi) / 2; if chain[mid].0 <= t { lo = mid } else { hi = mid } }
    let a = chain[lo], b = chain[hi]
    let v = a.1 + (b.1 - a.1) * (t - a.0) / max(1e-4, b.0 - a.0)
    return exp(last.1 - v)
  }
  var counts: (Int, Int) { (measured, guessed) }
}
