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
          if kind == "clique" { let dur = 0.35; return t <= T0 ? z0 : (t >= T0 + dur ? z1 : z0 * pow(z1 / z0, (t - T0) / dur)) }
          return t <= 0 ? z0 : cmd[min(cmd.count - 1, Int(t * fps))]
        }
        var tEnd = T0 + 0.2
        while tEnd < 6 && abs(zProp(tEnd + 0.05) / zProp(tEnd) - 1) > 1e-6 { tEnd += 1 / fps }
        func content(_ p: Double) -> Double { zProp(p + lead) }
        let track = FastZoomTracker()
        var hist: [(Double, Double)] = []
        var fi = 0, lastShown = -1.0
        var newN: [Double] = [], oldN: [Double] = []
        var jx = 0.0, jy = 0.0
        for dIdx in 0..<240 {
          let t = Double(dIdx) / 60 + 0.005
          hist.append((t, zProp(t)))
          // quadros rápidos que já chegaram (~38 ms depois da captura)
          while Double(fi) / fps + 0.038 <= t {
            let p = Double(fi) / fps
            jx = jx * 0.95 + rng.normal() * 0.0006; jy = jy * 0.95 + rng.normal() * 0.0006
            let arrive = p + 0.038
            let moving = abs(log(zProp(arrive) / zProp(arrive - 0.4))) > 1e-6
            var th: [Float]? = nil
            if moving { th = scene.thumb(content(p), jx, jy, noise: 0.004, &rng).map { Float(0.5) + ($0 - Float(0.5)) * Float(contrast) } }
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
          if let rr = track.ratio(newestOver: p) { k = max(1, min(6, rr)); if abs(k - 1) < 0.0005 { k = 1 } }
          if t > tEnd + 0.02 { newN.append(content(p) * k); oldN.append(content(p) * kOld) }
        }
        func spread(_ x: [Double]) -> Double { guard let mx = x.max(), let mn = x.min(), let l = x.last else { return 1 }; return (mx - mn) / l }
        let dn = spread(newN), dO = spread(oldN)
        let c = track.counts
        if contrast >= 0.5 && dn > 0.01 {   // diagnóstico: erro do medidor contra o zoom verdadeiro, por quadro rápido
          var line: [String] = []
          var p = T0 - 0.1
          while p < tEnd + 0.2 {
            if let r = track.ratio(newestOver: p) { let truth = content(Double(fi - 1) / fps) / content(p); line.append(String(format: "%.0f:%+.2f", (p - T0) * 1000, (r / truth - 1) * 100)) }
            p += 1 / fps
          }
          print("     erro do medidor por quadro (ms desde o início: %): " + line.joined(separator: " "))
        }
        if contrast >= 0.5 {
          check(dn <= 0.01, String(format: "zoom medido, adiantamento %.0f ms, %@: tela REAL depois de parar — medido %.2f%% × conta da 0.7.8 %.2f%% (medidos %d, estimados %d)", lead * 1000, kind, dn * 100, dO * 100, c.0, c.1))
        } else {
          check(dn <= max(dO + 0.005, 0.01), String(format: "zoom medido NO ESCURO, adiantamento %.0f ms, %@: tela %.2f%% × conta da 0.7.8 %.2f%% (não pode piorar; medidos %d, estimados %d)", lead * 1000, kind, dn * 100, dO * 100, c.0, c.1))
        }
      }
    }
    print("TESTE DO ZOOM OK")
  }
}
