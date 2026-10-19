import CoreVideo
import Foundation

// Teste do build (roda no Mac do GitHub antes de gerar o app): a calibração do zoom da prévia estabilizada tem que
// (1) medir escala entre miniaturas com erro < 0,4%; (2) achar a trava verdadeira (±5 ms) de uma câmera simulada com
// quadros renderizados, jitter de entrega e tremor; (3) na verificação, a tela com a trava ficar quieta depois que o zoom
// para (salto ≤ 0,4%, deriva ≤ 0,6%) e a conta antiga mostrar o vai-e-volta. Se não passar, o app não sai.
enum LutBaker { static let tenBit: Set<OSType> = [] }   // só pra compilar ZoomKernel.swift sozinho

struct RNG { var s: UInt64; mutating func next() -> Double { s = s &* 6364136223846793005 &+ 1442695040888963407; return Double(s >> 11) / Double(1 << 53) }
  mutating func normal() -> Double { let u = max(1e-12, next()), v = next(); return (-2 * log(u)).squareRoot() * cos(2 * .pi * v) } }

final class Scene {
  let W = 768, H = 432
  var px: [Float]
  init(seed: UInt64) {
    var rng = RNG(s: seed)
    px = [Float](repeating: 0, count: W * H)
    for cell in [6, 12, 24, 48, 96] {   // ruído de valor em oitavas (textura "natural")
      let gw = W / cell + 2, gh = H / cell + 2
      var g = [Float](repeating: 0, count: gw * gh)
      for i in 0..<g.count { g[i] = Float(rng.normal()) }
      let amp = Float(cell) / 96
      for y in 0..<H { for x in 0..<W {
        let fx = Float(x) / Float(cell), fy = Float(y) / Float(cell)
        let ix = Int(fx), iy = Int(fy), ax = fx - Float(ix), ay = fy - Float(iy)
        let v = (g[iy * gw + ix] * (1 - ax) + g[iy * gw + ix + 1] * ax) * (1 - ay) + (g[(iy + 1) * gw + ix] * (1 - ax) + g[(iy + 1) * gw + ix + 1] * ax) * ay
        px[y * W + x] += v * amp
      } }
    }
    let mn = px.min()!, mx = px.max()!
    for i in 0..<px.count { px[i] = (px[i] - mn) / (mx - mn) }
  }
  // miniatura 96×54 (média 8×8) do quadro com zoom z (bruto) e deslocamento (fração), como ZoomImage.thumb
  func thumb(_ z: Double, _ tx: Double, _ ty: Double, noise: Double, _ rng: inout RNG) -> [Float] {
    let w = 96, h = 54, sub = 8
    var out = [Float](repeating: 0, count: w * h)
    let span = 0.45 / (z / 2.0)
    for y in 0..<h { for x in 0..<w {
      var acc: Float = 0
      for sy in 0..<sub { for sx in 0..<sub {
        let u = ((Double(x) + (Double(sx) + 0.5) / Double(sub)) / Double(w) - 0.5) * span + 0.5 + tx
        let v = ((Double(y) + (Double(sy) + 0.5) / Double(sub)) / Double(h) - 0.5) * span + 0.5 + ty
        let ix = min(W - 1, max(0, Int(u * Double(W)))), iy = min(H - 1, max(0, Int(v * Double(H))))
        acc += px[iy * W + ix]
      } }
      out[y * w + x] = acc / Float(sub * sub) * (1 - 0.4 * Float(((Double(x) + 0.5) / 96 - 0.5) * ((Double(x) + 0.5) / 96 - 0.5) * 4)) + Float(rng.normal() * noise)
    } }
    return out
  }
}

var softFail = false
func soft(_ ok: Bool, _ msg: String) { print((ok ? "OK   " : "RUIM ") + msg); if !ok { softFail = true } }
func check(_ ok: Bool, _ msg: String) { if ok { print("OK   " + msg) } else { print("FALHA " + msg); exit(1) } }

@main struct ZoomCalibTests {
  static func main() {
    let scene = Scene(seed: 7)
    var rng = RNG(s: 99)
    // (1) medida de escala
    // entre quadros vizinhos (zoom normal, até 10%) o erro tem que ser mínimo; no degrau de 25% (só na calibração, onde
    // importa QUANDO e não o tamanho exato) a diferença de nitidez entre as miniaturas pesa um pouco mais
    var worstSmall = 0.0, worstBig = 0.0
    for z in [2.6, 3.0] { for r in [1.0, 1.012, 1.04, 1.1, 1.25] { for _ in 0..<2 {
      let a = ZoomImage.prep(scene.thumb(z, 0, 0, noise: 0.004, &rng))
      let b = ZoomImage.prep(scene.thumb(z * r, 0.002, -0.001, noise: 0.004, &rng))
      let m = ZoomImage.vsRef(a, b, lo: 0.75, hi: 1.35)
      let e = abs(m.z / r - 1)
      if r < 1.2 { worstSmall = max(worstSmall, e) } else { worstBig = max(worstBig, e) }
    } } }
    check(worstSmall < 0.003, String(format: "medida de escala entre quadros vizinhos (até 10%%): pior erro %.3f%%", worstSmall * 100))
    check(worstBig < 0.02, String(format: "degrau de 25%% (só diz EM QUAL quadro entrou; 2%% de erro não muda o quadro): pior erro %.3f%%", worstBig * 100))

    // (2)+(3) câmera simulada: 60 qps, valor posto no retorno de cada quadro (38 ms ± 4), trava verdadeira, estabilizado L
    // travas com a fronteira longe do jitter de entrega (estritas) + uma em cima do jitter (ambígua): nessa a verificação
    // NUNCA pode aprovar uma tela que ainda mexe
    for (trueLag, strict) in [(-0.012, true), (0.018, true), (0.037, true), (0.045, false)] {
      let fps = 60.0, L = 0.62
      func simulate(_ kind: String, z0: Double, z1: Double, fittedLag: ZoomFit?) -> CalibWindow {
        var setLog: [(Double, Double)] = [(-5, z0)]
        let n0 = 40
        var zc = z0
        var cb: [Double] = []
        for n in 0..<260 {
          let p = Double(n) / fps
          let c = p + 0.038 + (rng.next() - 0.5) * 0.008
          cb.append(c)
          guard n >= n0 else { continue }
          var v = zc
          switch kind {
          case "degrau": v = z1
          case "clique":
            let dur = abs(log2(z1 / z0)) / max(0.8, abs(log2(z1 / z0)) / max(0.2, 0.42 * (0.6 + 0.4 * min(1, abs(log2(z1 / z0)) / 2))))
            let k = min(1, (p - Double(n0) / fps) / dur + 1 / 60 / dur); v = z0 * pow(z1 / z0, k)
          default:   // pinça: alvo sobe em 0,5 s, passo amortecido por quadro
            let tgt = z0 * pow(z1 / z0, min(1, (p - Double(n0) / fps) / 0.5))
            if abs(log(tgt / zc)) > 0.0006 { v = exp(log(zc) + log(tgt / zc) * (1 - exp(-(1 / fps) / 0.07))) }   // = ZoomDriver.frameTick
          }
          if abs(v - zc) > 1e-9 { setLog.append((c, v)); zc = v }
        }
        let content: (Double) -> Double = { p in ZoomLag.at(setLog, p - trueLag) ?? z0 }
        var stab: [(Double, [Float])] = []
        var jx = 0.0, jy = 0.0
        for n in 0..<260 {
          let p = Double(n) / fps
          jx = jx * 0.9 + rng.normal() * 0.0004; jy = jy * 0.9 + rng.normal() * 0.0004
          stab.append((p, scene.thumb(content(p), jx, jy, noise: 0.004, &rng)))
        }
        // tela a 60 Hz: histórico (propriedade = último valor posto) e quadro estabilizado mais novo ampliado
        var hist: [(Double, Double)] = []
        var shown: [(pts: Double, k: Double, kOld: Double, at: Double)] = []
        var lastShown = -1.0
        for d in 0..<300 {
          let t = Double(d) / 60 + 0.005
          let zNow = ZoomLag.at(setLog, t) ?? z0
          hist.append((t, zNow))
          guard let f = stab.last(where: { $0.0 + L <= t }), f.0 > lastShown else { continue }
          lastShown = f.0
          var kOld = 1.0
          if let zf = ZoomLag.hist(hist, f.0), zf > 0 { kOld = max(1, min(6, zNow / zf)); if abs(kOld - 1) < 0.004 { kOld = 1 } }
          var k = kOld
          if let fit = fittedLag, let zk = ZoomLag.model(setLog, f.0, fit), zk > 0 { k = max(1, min(6, zNow / zk)); if abs(k - 1) < 0.0005 { k = 1 } }
          shown.append((f.0, k, kOld, t))
        }
        let sets = setLog.dropFirst()
        return CalibWindow(name: kind, stab: stab, fast: [], setLog: setLog, hist: hist, shown: shown, tFirst: sets.first!.0, tLast: sets.last!.0)
      }
      var pairs: [(PairMeas, CalibWindow)] = []
      for (kind, a, b) in [("degrau", 2.6, 3.25), ("degrau", 3.25, 2.6), ("clique", 2.6, 3.4), ("clique", 3.4, 2.6), ("pinça", 2.6, 3.4)] {
        let w = simulate(kind, z0: a, z1: b, fittedLag: nil)
        for m in ZoomCalibMath.neighborRatios(w.stab, from: w.tFirst - 0.15, to: w.tLast + 0.25) where m.conf >= 0.04 { pairs.append((m, w)) }
      }
      guard let best = ZoomCalibMath.bestFit(pairs) else { check(false, "ajuste sem pares"); return }
      let old = ZoomCalibMath.lagError(pairs, nil)
      if strict { check(abs(best.0.lag + best.0.tau - trueLag) <= 0.012, String(format: "trava verdadeira %+.0f ms -> achada %@ (%d pares; erro %.2e × antiga %.2e)", trueLag * 1000, best.0.text, best.2, best.1, old.0)) }
      var verW: [CalibWindow] = []
      var oldWorst = 0.0, newWorst = 0.0
      for (kind, a, b) in [("clique", 2.6, 3.4), ("pinça", 2.6, 3.4)] {
        let w = simulate(kind, z0: a, z1: b, fittedLag: best.0)
        verW.append(w)
        // tela REAL (conteúdo verdadeiro × ampliação) depois que o zoom parou: nova tem que ficar parada; antiga mostra o defeito
        let after = w.shown.filter { $0.at > w.tLast + 0.02 }
        let content: (Double) -> Double = { p in ZoomLag.at(w.setLog, p - trueLag) ?? a }
        guard let last = after.last else { check(false, "sem quadros depois de parar"); return }
        let dNew = after.map { abs(content($0.pts) * $0.k / (content(last.pts) * last.k) - 1) }.max() ?? 1
        let dOld = after.map { abs(content($0.pts) * $0.kOld / (content(last.pts) * last.kOld) - 1) }.max() ?? 1
        oldWorst = max(oldWorst, dOld); newWorst = max(newWorst, dNew)
        if strict { check(dNew <= 0.003, String(format: "trava %+.0f ms, %@: tela REAL depois de parar — nova varia %.2f%% (antiga %.2f%%)", trueLag * 1000, kind, dNew * 100, dOld * 100)) }
      }
      if strict { check(oldWorst >= 0.008, String(format: "trava %+.0f ms: a conta antiga reproduz o vai-e-volta (%.2f%%)", trueLag * 1000, oldWorst * 100)) }
      let v = ZoomCalibMath.verify(verW, fit: best.0)
      if !strict {
        check(!(v.ok && newWorst > 0.006), String(format: "trava ambígua %+.0f ms: verificação %@ com tela nova variando %.2f%% (só pode aprovar se ficou parada)", trueLag * 1000, v.ok ? "aprovou" : "recusou", newWorst * 100))
        continue
      }
      check(v.ok, String(format: "trava %+.0f ms: verificação do app aprova (pares %d, erro nova %.2e × antiga %.2e, maior nova %.2f%% × antiga %.2f%%, ruído %.2f%%)",
        trueLag * 1000, v.n, v.eNew, v.eOld, v.maxNew * 100, v.maxOld * 100, v.floor * 100))
    }
    // (4) APRENDIZADO NO USO NORMAL: zooms variados com a mão (tremor maior), cenas com menos textura; a cada zoom o app
    // decide. Tem que ligar sozinho com a trava certa e a tela ficar parada; com um aparelho que o modelo NÃO descreve
    // (estabilizador suavizando o zoom), não pode ligar uma tela que mexe.
    // smooth > 0: estabilizador alisa o zoom pra trás (o modelo cobre); ahead > 0: alisa olhando À FRENTE (o modelo NÃO cobre)
    for (trueLag, smooth, ahead) in [(0.022, 0.0, 0.0), (-0.008, 0.0, 0.0), (0.03, 0.045, 0.0), (0.02, 0.0, 0.04)] {
      let fps = 60.0, L = 0.62
      func trueContent(_ setLog: [(Double, Double)], _ p: Double, _ z0: Double) -> Double {
        if ahead > 0 {   // média simétrica (olha quadros à frente)
          var acc = 0.0, ws = 0.0, u = -2 * ahead
          while u <= 2 * ahead { let w = exp(-(u * u) / (2 * ahead * ahead / 4)); acc += w * log(ZoomLag.at(setLog, p - trueLag - u) ?? z0); ws += w; u += 0.004 }
          return exp(acc / ws)
        }
        if smooth <= 0 { return ZoomLag.at(setLog, p - trueLag) ?? z0 }
        var acc = 0.0, ws = 0.0, u = 0.0
        while u < 5 * smooth { let w = exp(-u / smooth); acc += w * log(ZoomLag.at(setLog, p - trueLag - u) ?? z0); ws += w; u += 0.004 }
        return exp(acc / ws)
      }
      func gesture(_ kind: String, z0: Double, z1: Double, speed: Double, jitter: Double, noise: Double, lag: ZoomFit?) -> (GestureSample, CalibWindow) {
        var setLog: [(Double, Double)] = [(-5, z0)]
        let n0 = 40
        var zc = z0
        for n in 0..<240 {
          let p = Double(n) / fps
          let c = p + 0.038 + (rng.next() - 0.5) * 0.008
          guard n >= n0 else { continue }
          var v = zc
          if kind == "clique" {
            let stops = abs(log2(z1 / z0)), dur = stops / max(0.8, stops / max(0.2, 0.42 * (0.6 + 0.4 * min(1, stops / 2))))
            v = z0 * pow(z1 / z0, min(1, (p - Double(n0) / fps) / dur + 1 / 60 / dur))
          } else {
            let tgt = z0 * pow(z1 / z0, min(1, (p - Double(n0) / fps) / speed))
            if abs(log(tgt / zc)) > 0.0006 { v = exp(log(zc) + log(tgt / zc) * (1 - exp(-(1 / fps) / 0.07))) }
          }
          if abs(v - zc) > 1e-9 { setLog.append((c, v)); zc = v }
        }
        let content: (Double) -> Double = { p in trueContent(setLog, p, z0) }
        var stab: [(Double, [Float])] = []
        var jx = 0.0, jy = 0.0
        for n in 0..<240 {
          let p = Double(n) / fps
          jx = jx * 0.95 + rng.normal() * jitter; jy = jy * 0.95 + rng.normal() * jitter
          stab.append((p, scene.thumb(content(p), jx, jy, noise: noise, &rng)))
        }
        var hist: [(Double, Double)] = []
        var shown: [(pts: Double, k: Double, kOld: Double, at: Double)] = []
        var lastShown = -1.0
        for d in 0..<280 {
          let t = Double(d) / 60 + 0.005
          let zNow = ZoomLag.at(setLog, t) ?? z0
          hist.append((t, zNow))
          guard let f = stab.last(where: { $0.0 + L <= t }), f.0 > lastShown else { continue }
          lastShown = f.0
          var kOld = 1.0
          if let zf = ZoomLag.hist(hist, f.0), zf > 0 { kOld = max(1, min(6, zNow / zf)); if abs(kOld - 1) < 0.004 { kOld = 1 } }
          var k = kOld
          if let lag, let zk = ZoomLag.model(setLog, f.0, lag), zk > 0 { k = max(1, min(6, zNow / zk)); if abs(k - 1) < 0.0005 { k = 1 } }
          shown.append((f.0, k, kOld, t))
        }
        let sets = setLog.dropFirst()
        let w = CalibWindow(name: kind, stab: stab, fast: [], setLog: setLog, hist: hist, shown: shown, tFirst: sets.first!.0, tLast: sets.last!.0)
        let g = ZoomCalibMath.sample(stab: stab, setLog: setLog, hist: hist, tFirst: w.tFirst, tLast: w.tLast, lensAt: { _ in "wide" }, boundaries: [])
        return (g, w)
        // (content usado abaixo pela tela real)
      }
      func realScreen(_ w: CalibWindow, z0: Double) -> (Double, Double) {
        let after = w.shown.filter { $0.at > w.tLast + 0.02 }
        guard let last = after.last else { return (1, 1) }
        func content(_ p: Double) -> Double { trueContent(w.setLog, p, z0) }
        let dN = after.map { abs(content($0.pts) * $0.k / (content(last.pts) * last.k) - 1) }.max() ?? 1
        let dO = after.map { abs(content($0.pts) * $0.kOld / (content(last.pts) * last.kOld) - 1) }.max() ?? 1
        return (dN, dO)
      }
      let plan: [(String, Double, Double, Double, Double, Double)] = [   // tipo, de, até, velocidade, tremor, ruído
        ("pinça", 2.6, 3.3, 0.4, 0.0012, 0.004), ("clique", 3.3, 2.6, 0, 0.0010, 0.004), ("pinça", 2.4, 3.6, 0.9, 0.0015, 0.008),
        ("clique", 2.6, 3.4, 0, 0.0012, 0.006), ("pinça", 3.4, 2.5, 0.6, 0.0012, 0.004), ("pinça", 2.5, 3.2, 0.3, 0.0010, 0.012),
        ("clique", 3.2, 2.6, 0, 0.0012, 0.004), ("pinça", 2.6, 3.5, 0.5, 0.0015, 0.006)]
      var samples: [GestureSample] = []
      var enabled: ZoomFit?
      var when = 0
      for (i, g) in plan.enumerated() {
        let r = gesture(g.0, z0: g.1, z1: g.2, speed: g.3, jitter: g.4, noise: g.5, lag: nil)
        samples.append(r.0)
        if enabled == nil { let d = ZoomCalibMath.decide(samples); if let l = d.fit { enabled = l; when = i + 1 }; print("     zoom \(i + 1): " + d.txt) }
      }
      if ahead <= 0 {
        guard let lag = enabled else { check(false, String(format: "uso normal, trava %+.0f ms suaviza %.0f: não ligou em %d zooms", trueLag * 1000, smooth * 1000, plan.count)); return }
        // trava achada pode ser outra da MESMA faixa (mesmos quadros) — o que vale é a tela real abaixo
        check(true, String(format: "uso normal, trava %+.0f ms suaviza %.0f: ligou sozinho no %dº zoom com %@", trueLag * 1000, smooth * 1000, when, lag.text))
        for (kind, a, b) in [("clique", 2.6, 3.4), ("pinça", 2.6, 3.4)] {
          let w = gesture(kind, z0: a, z1: b, speed: 0.5, jitter: 0.0012, noise: 0.004, lag: lag).1
          let (dN, dO) = realScreen(w, z0: a)
          check(dN <= 0.004, String(format: "uso normal, trava %+.0f ms suaviza %.0f, %@: tela REAL depois de parar — nova %.2f%% (antiga %.2f%%)", trueLag * 1000, smooth * 1000, kind, dN * 100, dO * 100))
        }
      } else {
        if let lag = enabled {
          var worst = 0.0
          for (kind, a, b) in [("clique", 2.6, 3.4), ("pinça", 2.6, 3.4)] { worst = max(worst, realScreen(gesture(kind, z0: a, z1: b, speed: 0.5, jitter: 0.0012, noise: 0.004, lag: lag).1, z0: a).0) }
          check(worst <= 0.006, String(format: "aparelho FORA do modelo (alisa olhando à frente %.0f ms): ligou com %@ e a tela varia %.2f%% (tem que ficar ≤0,6%%)", ahead * 1000, lag.text, worst * 100))
        } else { check(true, String(format: "aparelho FORA do modelo (alisa olhando à frente %.0f ms): não ligou (fica a conta antiga)", ahead * 1000)) }
      }
    }
    // (5) ZOOM REAL MEDIDO NA SAÍDA RÁPIDA (0.7.9): o iPhone aplica o zoom ADIANTADO em relação ao registrado, e o
    // adiantamento VARIA por gesto (0–35 ms, medido na tela do aparelho). A conta da 0.7.8 (registrado + 25 ms) erra nos
    // extremos; o rastreador mede o zoom real nos quadros rápidos e a tela tem que parar quieta. No escuro: não pode piorar.
    for seed in [1, 2, 3] { print("   --- sorteio de ruído \(seed)"); rng = RNG(s: UInt64(1000 + seed * 77))
    for (lead, contrast) in [(0.0, 1.0), (0.018, 1.0), (0.035, 1.0), (0.035, 0.25)] {
      for kind in ["clique", "pinça"] {
        let fps = 60.0, L = 0.55, z0 = 2.6, z1 = 3.4, T0 = 0.6
        var cmd: [Double] = []; var zc = z0
        for n in 0..<400 {
          let t = Double(n) / fps
          let tgt = t < T0 ? z0 : z0 * pow(z1 / z0, min(1, (t - T0) / 0.5))
          if abs(log(tgt / zc)) > 0.0006 { zc = exp(log(zc) + log(tgt / zc) * (1 - exp(-(1 / fps) / 0.07))) }
          cmd.append(zc)
        }
        func zProp(_ t: Double) -> Double {
          if kind == "clique" {   // 3 etapas como o app (0.8.8): 85% a r, 12% a r/3, 3% a r/9 (r = 1/0,35 s)
            let r = 1 / 0.35, d1 = 0.85 / r, d2 = 0.12 / (r / 3), d3 = 0.03 / (r / 9), u = t - T0
            let f = u <= 0 ? 0 : u < d1 ? u * r : u < d1 + d2 ? 0.85 + (u - d1) * r / 3 : u < d1 + d2 + d3 ? 0.97 + (u - d1 - d2) * r / 9 : 1
            return z0 * pow(z1 / z0, f)
          }
          return t <= 0 ? z0 : cmd[min(cmd.count - 1, Int(t * fps))]
        }
        var tEnd = T0 + 0.2
        while tEnd < 6 && abs(zProp(tEnd + 0.05) / zProp(tEnd) - 1) > 1e-6 { tEnd += 1 / fps }
        func content(_ p: Double) -> Double { zProp(p + lead) }
        let track = FastZoomTracker()
        var hist: [(Double, Double)] = []
        var fi = 0, lastShown = -1.0
        var newN: [Double] = [], oldN: [Double] = []
        var dbg: [String] = []
        var jx = 0.0, jy = 0.0
        for dIdx in 0..<240 {
          let t = Double(dIdx) / 60 + 0.005
          hist.append((t, zProp(t)))
          // quadros rápidos que já chegaram (~38 ms depois da captura)
          while Double(fi) / fps + 0.038 <= t {
            let p = Double(fi) / fps
            jx = jx * 0.95 + rng.normal() * 0.0006; jy = jy * 0.95 + rng.normal() * 0.0006
            let arrive = p + 0.038
            let moving = abs(log(zProp(arrive) / zProp(arrive - 0.15))) > 1e-6   // = app: pedido mudou nos últimos 150 ms
            var th: [Float]? = nil
            if moving { th = scene.thumb(content(p), jx, jy, noise: 0.0, &rng).map { Float(0.5) + ($0 - Float(0.5)) * Float(contrast) + Float(rng.normal() * 0.004) } }
            track.step(pts: p, zHist: ZoomLag.hist(hist, p + 0.025) ?? z0, thumb: th, moving: moving)
            fi += 1
          }
          // quadro estabilizado mais novo (mesmo instante de captura), chega L depois
          let p = floor((t - L) * fps) / fps
          guard p > lastShown, p >= 0 else { continue }
          lastShown = p
          let zNow = zProp(t)
          var kOld = 1.0
          if let zf = ZoomLag.hist(hist, p + 0.025), zf > 0 { kOld = max(1, min(6, zNow / zf)); if abs(kOld - 1) < 0.004 { kOld = 1 } }
          var k = kOld
          if let rr = track.ratio(newestOver: p) {
            var r = rr
            if let np = track.newestPTS, let zh = ZoomLag.hist(hist, np + 0.025), zh > 0 { r *= zNow / zh }   // igual ao app
            k = max(1, min(6, r)); if abs(k - 1) < 0.0005 { k = 1 }
          }
          // desde o instante em que o zoom pedido parou (o pouso conta: antes começava 70 ms depois e escondia o pouso curto)
          if t >= tEnd { newN.append(content(p) * k); oldN.append(content(p) * kOld); dbg.append(String(format: "%.0f:%.4f(k%.4f p%.0f)", (t - tEnd) * 1000, content(p) * k / z1, k, (p - T0) * 1000)) }
        }
        func spread(_ x: [Double]) -> Double { guard let mx = x.max(), let mn = x.min(), let l = x.last else { return 1 }; return (mx - mn) / l }
        let dn = spread(newN), dO = spread(oldN)
        let c = track.counts
        let cs = track.confs.sorted()
        let rs = track.resids.sorted()
        if !cs.isEmpty { print(String(format: "     medida (contraste %.2f, %@): confiança mediana %.3f | resíduo mín %.3f mediana %.3f máx %.3f", contrast, kind, cs[cs.count / 2], rs.first!, rs[rs.count / 2], rs.last!)) }
        if false {   // diagnóstico: erro do medidor contra o zoom verdadeiro, por quadro rápido
          var line: [String] = []
          var p = T0 - 0.1
          while p < tEnd + 0.2 {
            if let r = track.ratio(newestOver: p) { let truth = content(Double(fi - 1) / fps) / content(p); line.append(String(format: "%.0f:%+.2f", (p - T0) * 1000, (r / truth - 1) * 100)) }
            p += 1 / fps
          }
          print("     erro do medidor por quadro (ms desde o início: %): " + line.joined(separator: " "))
          print("     tela depois de parar (ms: tamanho/final): " + dbg.prefix(45).joined(separator: " "))
        }
        if contrast >= 0.5 {
          soft(dn <= 0.01, String(format: "zoom medido, adiantamento %.0f ms, %@: tela REAL depois de parar — medido %.2f%% × conta da 0.7.8 %.2f%% (medidos %d, estimados %d)", lead * 1000, kind, dn * 100, dO * 100, c.0, c.1))
        } else {
          soft(dn <= max(dO + 0.005, 0.01), String(format: "zoom medido NO ESCURO, adiantamento %.0f ms, %@: tela %.2f%% × conta da 0.7.8 %.2f%% (não pode piorar; medidos %d, estimados %d)", lead * 1000, kind, dn * 100, dO * 100, c.0, c.1))
        }
      }
    }
    }
    if softFail { print("FALHA (zoom medido em algum sorteio)"); exit(1) }
    // (6) TROCA DE LENTE SEM PULO (0.8.0): câmera simulada a 60 qps; a lente troca com o zoom PARADO, com pulo de escala e
    // de posição como os medidos na tela do aparelho (ultra→principal +3–5%, tele com paralaxe, ida-e-volta de 133 ms perto
    // de objeto). Tela e arquivo recebem o quadro estabilizado 0,5 s depois (corte 1,12). A saída rápida mede a troca ~60 ms
    // depois dela; o 1º quadro estabilizado da lente nova é medido antes de ir pra tela/arquivo. Exigido: nenhum quadro
    // mostrado muda mais de 0,6% de tamanho / 0,4% de posição pro vizinho (sem a correção: o pulo inteiro de uma vez), nunca
    // borda (só amplia), e 0,65 s depois da troca a imagem é a da lente nova pura. Escuro / estabilização sem atraso: não piora.
    var worstMeas = (s: 0.0, t: 0.0)
    for (J, sx, sy) in [(1.05, 0.0, 0.0), (1 / 1.05, 0.003, -0.002), (1.10, -0.006, 0.004), (0.9, 0.0, 0.005), (1.03, 0.01, 0.0)] {
      let z = 2.2
      let a = ZoomImage.prep(scene.thumb(z, 0, 0, noise: 0.004, &rng)), b = ZoomImage.prep(scene.thumb(z * J, sx, sy, noise: 0.004, &rng))
      guard let m = ZoomImage.switchGeo(a, b) else { check(false, String(format: "troca: a medida falhou numa cena com textura (pulo %.3f)", J)); continue }
      // nova (zoom z·J, cena deslocada o) -> velha (zoom z): s = 1/J, t = o·z/0,9 (fração do quadro)
      worstMeas.s = max(worstMeas.s, abs(Double(m.g.s) * J - 1))
      worstMeas.t = max(worstMeas.t, abs(Double(m.g.tx) - sx * z / 0.9) * 96, abs(Double(m.g.ty) - sy * z / 0.9) * 54)
    }
    check(worstMeas.s < 0.003 && worstMeas.t < 0.35, String(format: "troca de lente: medida do pulo (até ±10%%, deslocada) — pior erro %.3f%% de escala, %.2f ponto de posição", worstMeas.s * 100, worstMeas.t))

    func lensSim(_ name: String, J: Double, ox: Double, oy: Double, ratio: Double, contrast: Double, L: Double, flashFrames: Int, file: Bool, strict: Bool, maxStep: Double = 0.006) {
      let fps = 60.0, Z = 2.0, crop = 1.12, te = 2.0
      let hider = LensSwitchHider()
      struct V { let p: Double; let id: Int; let z: Double; let x: Double; let y: Double; let jx: Double; let jy: Double }
      var vs: [V] = []
      var jx = 0.0, jy = 0.0
      let t2 = flashFrames > 0 ? te + Double(flashFrames) / fps : Double.infinity
      for n in 0..<Int(4 * fps) {
        let p = Double(n) / fps
        jx = jx * 0.95 + rng.normal() * 0.0003; jy = jy * 0.95 + rng.normal() * 0.0003
        let new = p >= te - 1e-9 && p < t2 - 1e-9
        vs.append(V(p: p, id: new ? 2 : 1, z: new ? Z * J : Z, x: (new ? ox : 0) + jx, y: (new ? oy : 0) + jy, jx: jx, jy: jy))
      }
      // quadro rápido (sem corte) ou estabilizado (corte; a lente nova pode cortar diferente: ratio); ruído depois do contraste
      func pic(_ v: V, stab: Bool) -> [Float] {
        let z = v.z * (stab ? crop * (v.id == 2 ? ratio : 1) : 1)
        return scene.thumb(z, v.x, v.y, noise: 0, &rng).map { Float(0.5) + ($0 - Float(0.5)) * Float(contrast) + Float(rng.normal() * 0.004) }
      }
      var switches: [Int] = []
      for i in 1..<vs.count where vs[i].id != vs[i - 1].id { switches.append(i) }
      var fastKnown: [(at: Double, i: Int, g: SwitchGeometry?)] = []
      for i in switches {
        let m = ZoomImage.switchGeo(ZoomImage.prep(pic(vs[i - 1], stab: false)), ZoomImage.prep(pic(vs[i], stab: false)))
        fastKnown.append((vs[i].p + 0.06, i, m?.g))
      }
      var added = Set<Int>(), stabbed = Set<Int>()
      var shown: [(z: Double, x: Double, y: Double)] = [], held = 0, border = 0.0, endPure = true
      for v in vs {
        let wall = v.p + L   // hora em que este quadro estabilizado chega na tela/arquivo
        for f in fastKnown where f.at <= wall && !added.contains(f.i) {
          added.insert(f.i)
          let pred = f.g.map { SwitchGeometry(s: $0.s, tx: $0.tx * Float(crop), ty: $0.ty * Float(crop), exact: true) }
          hider.add(t: vs[f.i].p, from: vs[f.i - 1].id, to: vs[f.i].id, fast: f.g, pred: pred)
        }
        if let i = switches.first(where: { vs[$0].p == v.p }), !stabbed.contains(i) {
          stabbed.insert(i)
          if let ev = hider.awaiting(from: vs[i - 1].id, to: v.id, at: v.p) {
            let m = ev.pred.flatMap { ZoomImage.switchGeo(ZoomImage.prep(pic(vs[i - 1], stab: true)), ZoomImage.prep(pic(v, stab: true)), around: $0) }
            hider.stabMeasured(t: ev.t, g: m?.g)
          }
        }
        let r = hider.geometry(pts: v.p, sensor: v.id, file: file)
        if r.hold { held += 1; continue }
        let g = r.g
        border = max(border, Double(max(0, 1 - g.s)), Double(max(abs(g.tx), abs(g.ty)) - (g.s - 1) / 2))
        if v.p > (t2.isFinite ? t2 : te) + 0.65 && !g.isIdentity { endPure = false }
        // o que a tela mostra: a cena com zoom zs·s e deslocamento O − t·0,9/(zs·s) (convenção do aligned/shader); tremor da
        // mão tirado (é igual com e sem correção)
        let zs = v.z * crop * (v.id == 2 ? ratio : 1), zd = zs * Double(g.s)
        shown.append((zd, v.x - v.jx - Double(g.tx) * 0.9 / zd, v.y - v.jy - Double(g.ty) * 0.9 / zd))
      }
      var dz = 0.0, dp = 0.0
      for k in 1..<shown.count {
        let a = shown[k - 1], b = shown[k]
        dz = max(dz, abs(log(b.z / a.z))); dp = max(dp, abs(b.x - a.x) * b.z / 0.9, abs(b.y - a.y) * b.z / 0.9)
      }
      let baseZ = abs(log(J * ratio)), baseP = max(abs(ox), abs(oy)) * Z * crop * J / 0.9
      let tag = (file ? "ARQUIVO " : "tela ") + name
      let txt = String(format: "%@: maior passo entre quadros %.2f%% de tamanho, %.2f%% de posição (sem correção: %.2f%% / %.2f%%), segurou %d", tag, dz * 100, dp * 100, baseZ * 100, baseP * 100, held)
      check(border < 1e-4, tag + ": nunca mostra borda (só amplia)")
      if strict {
        check(dz <= maxStep && dp <= 0.004 && endPure, txt + (endPure ? "" : " — NÃO voltou à lente nova pura"))
        if flashFrames > 0 && !file { check(held == flashFrames, tag + ": segura exatamente os quadros do pulso (\(held)/\(flashFrames))") }
      } else {
        check(dz <= baseZ + 0.002 && dp <= baseP + 0.002, txt + " (não pode piorar)")
      }
    }
    // (o pulo grande fica fora do medido no aparelho, 2,9–5%: ali o preparo anda até 0,7% por quadro, ainda sem degrau)
    for (name, J, ox, oy, ratio, maxStep) in [("ultra→principal +5% (1×, como na tela)", 1.05, 0.0, 0.0, 1.0, 0.006),
                                     ("ultra→principal +3%, estabilizado 1% diferente do rápido", 1.03, 0.001, -0.001, 1.01, 0.006),
                                     ("principal→tele +3% com paralaxe", 1.03, 0.012, 0.006, 1.0, 0.006),
                                     ("lente nova mais ABERTA −5%", 1 / 1.05, -0.003, 0.0, 1.0, 0.006),
                                     ("pulo grande +8% e deslocado", 1.08, -0.008, 0.006, 0.99, 0.007)] {
      for file in [false, true] { lensSim(name, J: J, ox: ox, oy: oy, ratio: ratio, contrast: 1, L: 0.5, flashFrames: 0, file: file, strict: true, maxStep: maxStep) }
    }
    lensSim("ida-e-volta em 133 ms (objeto perto)", J: 1.06, ox: 0.002, oy: 0, ratio: 1, contrast: 1, L: 0.5, flashFrames: 8, file: false, strict: true)
    lensSim("ida-e-volta em 133 ms (arquivo não segura: respira)", J: 1.06, ox: 0.002, oy: 0, ratio: 1, contrast: 1, L: 0.5, flashFrames: 8, file: true, strict: true)
    lensSim("escuro", J: 1.05, ox: 0, oy: 0, ratio: 1, contrast: 0.2, L: 0.5, flashFrames: 0, file: false, strict: false)
    lensSim("estabilização sem atraso (0,15 s): não dá tempo de preparar", J: 1.05, ox: 0, oy: 0, ratio: 1, contrast: 1, L: 0.15, flashFrames: 0, file: false, strict: false)
    // (7) CHEGADA ASSENTADA (0.10.11, refeita na 0.11.4): depois da troca a lente nova "respira" sozinha (17/10: 10×→2× entra 7%
    // menor e cresce em ~2 s). Quadros estabilizados a 60 qps, a medida chega 1 quadro atrasada (como no app). Desde a 0.11.4 só a
    // ESCALA é corrigida. Exigido: do 1º quadro da lente nova até 2,6 s a escala da tela fica na da chegada (≤1%, deriva lenta de mão única), NENHUM passo
    // acima de 0,2% por quadro nem vai-e-volta acima de 0,25% fora do quadro da troca (no aparelho a 0.11.2 tremia 0,5–1,5%), nunca borda, posição nunca pior
    // que sem correção; no movimento seguinte solta em 0,35 s e termina na lente pura. Casos do aparelho: mão tremendo forte,
    // cena escura (ruído), trocas seguidas ida-e-volta.
    ArrivalAnchor.on = true
    func arrivalSim(_ name: String, d0: Double, dx0: Double, dy0: Double, dur: Double, margin: Float?, strict: Bool,
                    shake: Double = 0.00015, noise: Double = 0.004, switches: [Double] = [1.0]) -> Float {
      let fps = 60.0, Z = 2.4, tm = 4.2
      let a = ArrivalAnchor()
      var learned: Float = 0
      a.marginFor = { _, _ in margin }
      a.learn = { _, _, n in learned = n }
      var prevId = 1, pending: (Double, [Float])?
      var shown: [(p: Double, z: Double, x: Double, y: Double, sw: Bool)] = [], border = 0.0, endPure = true
      var jx = 0.0, jy = 0.0
      for n in 0..<Int(5 * fps) {
        let p = Double(n) / fps
        jx = jx * 0.92 + rng.normal() * shake; jy = jy * 0.92 + rng.normal() * shake
        let k = switches.filter { p >= $0 - 1e-9 }.count, id = k == 0 ? 1 : (k % 2 == 1 ? 2 : 1)
        let since = k == 0 ? 0 : p - switches[k - 1]
        let f = k == 0 ? 1 : min(1, since / dur), e = Double(SwitchPlan.smooth(f))
        let ds = k == 0 ? 1 : d0 + (1 - d0) * e, ox = k == 0 ? 0 : dx0 * (1 - e), oy = k == 0 ? 0 : dy0 * (1 - e)
        let zf = Z * ds, x = ox + jx, y = oy + jy
        let want = a.frame(pts: p, sensor: id, prev: prevId, still: p < tm, moving: p >= tm)
        let isSwitch = id != prevId
        prevId = id
        if let q = pending { a.measure(pts: q.0, prepped: q.1); pending = nil }   // a medida do quadro anterior chega agora
        let g = a.geometry(pts: p, sensor: id)
        if want { pending = (p, ZoomImage.prep(scene.thumb(zf, x, y, noise: noise, &rng))) }
        border = max(border, Double(max(0, 1 - g.s)), Double(max(abs(g.tx), abs(g.ty)) - (g.s - 1) / 2))
        if p > tm + ArrivalAnchor.releaseDur + 0.02 && !g.isIdentity { endPure = false }
        let zd = zf * Double(g.s)
        if k > 0 { shown.append((p, zd, x - Double(g.tx) * 0.9 / zd, y - Double(g.ty) * 0.9 / zd, isSwitch)) }
      }
      let last = switches.last ?? 1.0
      let lo = last, hi = min(last + ArrivalAnchor.window, tm)
      let win = shown.filter { $0.p >= lo && $0.p <= hi }
      guard let r0 = win.first else { check(false, name + ": sem quadros"); return 0 }
      var vz = 0.0, vp = 0.0, bp = 0.0, step = 0.0, stepRel = 0.0
      for s in win { vz = max(vz, abs(log(s.z / r0.z))) }
      // vai-e-volta (o tremor de verdade): caminho percorrido menos o deslocamento líquido, em janelas de 0,5 s
      var wobble = 0.0
      for k in 1..<shown.count where !shown[k].sw {
        let dzk = abs(log(shown[k].z / shown[k - 1].z))
        if shown[k].p < tm { step = max(step, dzk) } else { stepRel = max(stepRel, dzk) }
      }
      var i0 = 0
      while i0 < shown.count {
        var i1 = i0, path = 0.0
        while i1 + 1 < shown.count && shown[i1 + 1].p < min(shown[i0].p + 0.5, tm) && !shown[i1 + 1].sw { path += abs(log(shown[i1 + 1].z / shown[i1].z)); i1 += 1 }
        if i1 > i0 { wobble = max(wobble, path - abs(log(shown[i1].z / shown[i0].z))) }
        i0 = i1 + 1
      }
      // posição: a correção não mexe mais nela — só confere que não piorou (mesma conta com e sem)
      for s in win { vp = max(vp, abs(s.x - r0.x) * s.z / 0.9, abs(s.y - r0.y) * s.z / 0.9) }
      bp = max(abs(dx0), abs(dy0)) * Z / 0.9 + shake * 40
      let base = abs(log(d0))
      let txt = String(format: "chegada %@: tela variou %.2f%% de tamanho em 2,6 s (sem: %.2f%%), maior passo fora da troca %.3f%%, vai-e-volta %.3f%%, soltura %.2f%%/quadro, posição %.2f%%, aprendeu sobra %.4f",
        name, vz * 100, base * 100, step * 100, wobble * 100, stepRel * 100, vp * 100, learned)
      check(border < 1e-4, "chegada " + name + ": nunca mostra borda")
      check(endPure, "chegada " + name + ": depois da soltura volta à lente pura")
      check(step <= 0.002 && wobble <= 0.0025, txt + " — NÃO PODE TREMER (passo ≤0,2%/quadro, vai-e-volta ≤0,25% em 0,5 s; a 0.11.2 fazia 0,5–1,5% POR QUADRO)")
      check(vp <= bp + 0.004, txt + " — posição não pode piorar")
      if strict { check(vz <= 0.01 && stepRel <= 0.012, txt + " (deriva lenta ≤1%)") } else { check(vz <= base + 0.002, txt + " (não pode piorar)") }
      return learned
    }
    let need = arrivalSim("10×→2× cresce 7%, sobra padrão (1ª vez)", d0: 0.93, dx0: 0.004, dy0: -0.002, dur: 2.0, margin: nil, strict: false)
    check(need > 1.06 && need <= 1.08, String(format: "chegada: sobra aprendida %.4f pra deriva de 7%%", need))
    _ = arrivalSim("10×→2× cresce 7%, sobra aprendida", d0: 0.93, dx0: 0.004, dy0: -0.002, dur: 2.0, margin: min(1.08, need * 1.005), strict: true)
    _ = arrivalSim("pinça 1×→2× encolhe 10%", d0: 1.10, dx0: 0, dy0: 0.008, dur: 1.8, margin: 1.0, strict: true)
    _ = arrivalSim("2×→1× cresce 5%", d0: 0.95, dx0: -0.004, dy0: 0.008, dur: 1.5, margin: 1.06, strict: true)
    _ = arrivalSim("sem deriva (só tremor)", d0: 1.0, dx0: 0, dy0: 0, dur: 1.0, margin: 1.03, strict: true)
    _ = arrivalSim("mão tremendo FORTE + cresce 3%", d0: 0.97, dx0: 0, dy0: 0, dur: 1.5, margin: 1.04, strict: true, shake: 0.0012)
    _ = arrivalSim("cena escura (ruído 3×) + cresce 3%", d0: 0.97, dx0: 0.002, dy0: 0, dur: 1.5, margin: 1.04, strict: false, noise: 0.012)
    _ = arrivalSim("0,5→1→0,5→1 seguidas (1,2 s entre trocas)", d0: 0.98, dx0: 0.003, dy0: 0, dur: 1.2, margin: 1.03, strict: true, switches: [1.0, 2.2, 3.0])
    // (8) TROCA ENQUADRADA (0.11.7): clique com o iPhone trocando de lente ~90 ms DEPOIS de o zoom chegar, como nos trechos da tela de
    // 19/10 (0.11.6): a lente nova entra 4,3% maior e 2,4% deslocada e o estabilizador escorrega até 4,5% em 0,35 s. A tela recebe o
    // quadro estabilizado 0,565 s depois; a saída rápida vê a troca 40 ms depois dela (o pulo inteiro, sem escorregão). Exigido: do fim
    // do zoom até o zoom seguinte a tela não muda mais que 0,4% de tamanho nem de posição (sem a correção: o pulo inteiro), nenhum passo
    // entre quadros acima de 0,2%, o zoom do clique só anda pra frente (o preparo nunca volta), nunca borda, e no zoom seguinte solta e
    // termina na lente pura. Escuro / tarde / sem movimento / sem medida: não piora (sem movimento: não mexe em nada).
    func lockSim(_ name: String, J: Double, inst: (Double, Double), fin: (Double, Double), glideDur: Double = 0.35, contrast: Double = 1,
                 L: Double = 0.565, fastOK: Bool = true, memPred: SwitchGeometry? = nil, gap: Double = 0.09, strict: Bool = true,
                 shake: Double = 0.0001, untouched: Bool = false) {
      let fps = 60.0, crop = 1.12, lead = 0.025
      let pa = 1.0, pb = 1.15, ts = pb + gap, tm = 3.4, Z0 = 1.0, Z1 = 2.0
      func zc(_ p: Double) -> Double {
        func ramp(_ a: Double, _ b: Double, _ z0: Double, _ z1: Double) -> Double { let x = min(1, max(0, (p - a) / (b - a))); return z0 * pow(z1 / z0, x * x * (3 - 2 * x)) }
        return p < tm ? ramp(pa, pb, Z0, Z1) : ramp(tm, tm + 0.15, Z1, Z1 * 1.5)
      }
      let lk = FrameLock()
      var learned: (SwitchGeometry, SwitchGeometry)?
      lk.learn = { _, _, f, l, _ in learned = (f, l) }
      var hist: [(Double, Double)] = []
      var w = 0.0; while w < 6 { hist.append((w, zc(w - lead))); w += 1.0 / 120 }
      struct F { let p: Double; let id: Int; let zs: Double; let x: Double; let y: Double }
      var frames: [F] = []
      var jx = 0.0, jy = 0.0
      for n in 0..<Int(4.2 * fps) {
        let p = Double(n) / fps
        jx = jx * 0.95 + rng.normal() * shake; jy = jy * 0.95 + rng.normal() * shake
        let new = p >= ts - 1e-9, zs = zc(p) * crop * (new ? J : 1)
        var ox = 0.0, oy = 0.0
        if new {   // deslocamento em fração do quadro estabilizado → cena (o quadro cobre 0,9/z da cena)
          let e = Double(SwitchPlan.smooth((p - ts) / glideDur))
          ox = (inst.0 + (fin.0 - inst.0) * e) * 0.9 / zs; oy = (inst.1 + (fin.1 - inst.1) * e) * 0.9 / zs
        }
        frames.append(F(p: p, id: new ? 2 : 1, zs: zs, x: ox + jx, y: oy + jy))
      }
      func pic(_ zoom: Double, _ x: Double, _ y: Double) -> [Float] {
        ZoomImage.prep(scene.thumb(zoom, x, y, noise: 0, &rng).map { Float(0.5) + ($0 - Float(0.5)) * Float(contrast) + Float(rng.normal() * 0.004) })
      }
      // saída rápida (sem corte): último quadro velho × 1º novo, o pulo INTEIRO (o mesmo deslocamento de cena do final estabilizado)
      var pred = memPred
      if fastOK {
        let zf = zc(ts) * J, fx = fin.0 * 0.9 / (zc(ts) * crop * J), fy = fin.1 * 0.9 / (zc(ts) * crop * J)
        if let m = ZoomImage.switchGeo(pic(zc(ts - 1 / fps), 0, 0), pic(zf, fx, fy)) { pred = SwitchGeometry(s: m.g.s, tx: m.g.tx * Float(crop), ty: m.g.ty * Float(crop), exact: true) }
      }
      var status = "", added = false, prevId = 1
      var shown: [(p: Double, z: Double, x: Double, y: Double)] = [], base: [(p: Double, z: Double, x: Double, y: Double)] = []
      var border = 0.0, endPure = true, anyGeo = false
      for (k, f) in frames.enumerated() {
        if !added && f.p + L >= ts + 0.04 {
          added = true
          status = lk.add(t: ts, from: 1, to: 2, pred: pred, motion: FrameLock.findMotion(hist.filter { $0.0 <= ts + 0.04 }, switchAt: ts, lead: lead))
        }
        let zooming = abs(log(zc(f.p + 1 / 120) / zc(f.p - 1 / 120))) * 60 > 0.05
        switch lk.frame(pts: f.p, sensor: f.id, prev: prevId, moving: zooming, zooming: zooming) {
        case .ref: let q = frames[k - 1]; lk.begin(pts: f.p, sensor: f.id, ref: pic(q.zs, q.x, q.y), img: pic(f.zs, f.x, f.y))
        case .measure: lk.measure(pts: f.p, sensor: f.id, img: pic(f.zs, f.x, f.y))
        case .none: break
        }
        prevId = f.id
        let g = lk.geometry(pts: f.p, sensor: f.id)
        if !g.isIdentity { anyGeo = true }
        border = max(border, Double(max(0, 1 - g.s)), Double(max(abs(g.tx), abs(g.ty)) - (g.s - 1) / 2))
        if f.p > tm + FrameLock.releaseDur + 0.03 && !g.isIdentity { endPure = false }
        let zd = f.zs * Double(g.s)
        shown.append((f.p, zd, f.x - Double(g.tx) * 0.9 / zd, f.y - Double(g.ty) * 0.9 / zd))
        base.append((f.p, f.zs, f.x, f.y))
      }
      func metrics(_ s: [(p: Double, z: Double, x: Double, y: Double)]) -> (vz: Double, vp: Double, sz: Double, sp: Double, back: Double) {
        let win = s.filter { $0.p >= pb - 1e-9 && $0.p < tm }
        guard let r0 = win.first else { return (0, 0, 0, 0, 0) }
        var vz = 0.0, vp = 0.0, sz = 0.0, sp = 0.0, back = 0.0
        for q in win { vz = max(vz, abs(log(q.z / r0.z))); vp = max(vp, abs(q.x - r0.x) * q.z / 0.9, abs(q.y - r0.y) * q.z / 0.9) }
        for k in 1..<win.count { let a = win[k - 1], b = win[k]; sz = max(sz, abs(log(b.z / a.z))); sp = max(sp, abs(b.x - a.x) * b.z / 0.9, abs(b.y - a.y) * b.z / 0.9) }
        let mv = s.filter { $0.p >= pa - 0.02 && $0.p <= pb + 0.001 }
        for k in 1..<mv.count { back = max(back, log(mv[k - 1].z / mv[k].z)) }   // zoom in voltando
        return (vz, vp, sz, sp, back)
      }
      let a = metrics(shown), b = metrics(base)
      let txt = String(format: "enquadrada %@: depois do zoom a tela variou %.2f%% de tamanho e %.2f%% de posição (sem: %.2f%% / %.2f%%), maior passo %.2f%% / %.2f%%, zoom voltou %.3f%% [%@]",
        name, a.vz * 100, a.vp * 100, b.vz * 100, b.vp * 100, a.sz * 100, a.sp * 100, a.back * 100, status)
      check(border < 1e-4, "enquadrada " + name + ": nunca mostra borda")
      check(endPure, "enquadrada " + name + ": no zoom seguinte solta e volta à lente pura")
      check(a.back <= 0.0005, txt + " — o preparo não pode fazer o zoom voltar")
      if untouched { check(!anyGeo, txt + " — sem movimento pra esconder: não mexe em nada"); return }
      if strict {
        check(a.vz <= 0.004 && a.vp <= 0.004 && a.sz <= 0.002 && a.sp <= 0.002, txt)
        if let l = learned { print(String(format: "     aprendeu: 1ª %.4f %+.4f %+.4f · final %.4f %+.4f %+.4f", l.0.s, l.0.tx, l.0.ty, l.1.s, l.1.tx, l.1.ty)) }
      } else {
        check(a.vz <= b.vz + 0.002 && a.vp <= b.vp + 0.002, txt + " (não pode piorar)")
      }
    }
    lockSim("clique 1×→2×: +4,3%, 2,4% → escorrega até 4,5% (medido 19/10)", J: 1.043, inst: (0.024, 0.002), fin: (0.045, 0.003))
    lockSim("5×: +4,8% e 6,5% de uma vez", J: 1.048, inst: (0.062, -0.004), fin: (0.065, -0.004))
    lockSim("lente nova mais ABERTA −5%, 1%", J: 1 / 1.05, inst: (-0.006, 0.004), fin: (-0.01, 0.006))
    lockSim("mão tremendo forte", J: 1.043, inst: (0.024, 0.002), fin: (0.045, 0.003), shake: 0.0006, strict: false)
    lockSim("cena escura (contraste 0,15)", J: 1.043, inst: (0.024, 0.002), fin: (0.045, 0.003), contrast: 0.15, strict: false)
    lockSim("rápida não mediu, previsão aprendida do par", J: 1.043, inst: (0.024, 0.002), fin: (0.045, 0.003), fastOK: false,
            memPred: SwitchGeometry(s: Float(1 / 1.043) * 1.003, tx: 0.043, ty: 0.003, exact: true))
    lockSim("rápida não mediu e nada aprendido", J: 1.043, inst: (0.024, 0.002), fin: (0.045, 0.003), fastOK: false, untouched: true)
    lockSim("estabilização sem atraso (0,15 s): tarde pra preparar", J: 1.043, inst: (0.024, 0.002), fin: (0.045, 0.003), L: 0.15, strict: false)
    lockSim("troca 1 s depois de o zoom parar (sem movimento pra esconder)", J: 1.043, inst: (0.024, 0.002), fin: (0.045, 0.003), gap: 1.0, untouched: true)
    print("TESTE DO ZOOM OK")
  }
}
