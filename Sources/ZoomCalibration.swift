import AVFoundation
import Foundation
import QuartzCore

// CALIBRAÇÃO + VERIFICAÇÃO AUTOMÁTICA DO ZOOM DA PRÉVIA ESTABILIZADA (0.7.5) — ver ZoomLag (ZoomKernel.swift).
// Celular parado, cena iluminada. Tudo entre 1,3× e 1,7× (longe das trocas de lente/sensor).
// 1) AJUSTE: dois degraus (1,3 -> 1,625 -> 1,3), dois cliques (1,3 -> 1,7 -> 1,3) e uma pinça (1,3 -> 1,7). Para cada par
//    de quadros estabilizados VIZINHOS no trecho em que o zoom muda: razão de escala medida na imagem (erro ~0,15%) ×
//    razão prevista por cada trava candidata (registro exato dos valores postos) e pela conta antiga. Melhor trava = menor
//    erro (robusto).
// 2) VERIFICAÇÃO com a trava ligada: um clique e uma pinça. Para cada quadro mostrado depois que o zoom parou: salto de
//    escala NA TELA entre quadros vizinhos = razão medida na imagem × razão das ampliações (nova e antiga, no mesmo quadro).
//    Liga só se a nova provar (saltos e deriva ≤ metade da antiga, ou ≤ ruído da medida).
extension NativeCamera {
  @MainActor func runZoomCalibration() {
    guard selfTest.isEmpty, ready, !recording, let cam = device, cam.position == .back else { return }
    Task { @MainActor in await self.zoomCalibration() }
  }

  @MainActor private func zoomCalibration() async {
    let wasUltra = ultraLock, startZoom = zoom
    let rec = renderer.calibRec
    let previousLag = ZoomLag.load()
    calibrating = true
    func sleep(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
    func finish(_ msg: String) async {
      selfTest = msg
      calibrating = false
      selectZoom(wasUltra ? 0.5 : startZoom)
      await sleep(4.5)
      selfTest = ""
    }
    func window(_ name: String, _ act: () async -> Void) async -> CalibWindow? {
      renderer.clearShown()
      let before = zoomDriver.lastSet?.0 ?? 0
      rec.begin(); await sleep(0.35)
      let t0 = CACurrentMediaTime()
      await act()
      await sleep(3.4)   // termina de chegar + quadros estabilizados (atrasados) chegarem
      let data = rec.end()
      let log = zoomDriver.setLogSnapshot()
      let sets = log.filter { $0.0 >= t0 - 0.01 && $0.0 > before }
      guard let first = sets.first, let last = sets.last else { return nil }
      return CalibWindow(name: name, stab: data.stab, fast: data.fast, setLog: log, hist: renderer.zoomHistorySnapshot(), shown: renderer.shownSnapshot(), tFirst: first.0, tLast: last.0)
    }
    func pinch() async {
      for i in 1...30 { followZoom(1.3 * pow(1.7 / 1.3, Double(i) / 30)); await sleep(1.0 / 60) }
      endZoomGesture()
    }
    selfTest = "Calibrando o zoom (~45 s): deixe o celular PARADO, apoiado, apontado pra algo iluminado e com detalhes. Não toque."
    setFrameLag(nil)
    selectZoom(1.3); await sleep(2.8)
    // ---- 1) ajuste
    var fitW: [CalibWindow] = []
    if let w = await window("degrau+", { self.zoomDriver.jump(to: CGFloat(1.625) * self.base) }) { fitW.append(w) }
    if let w = await window("degrau-", { self.zoomDriver.jump(to: CGFloat(1.3) * self.base) }) { fitW.append(w) }
    if let w = await window("clique+", { self.selectZoom(1.7) }) { fitW.append(w) }
    if let w = await window("clique-", { self.selectZoom(1.3) }) { fitW.append(w) }
    if let w = await window("pinça+", { await pinch() }) { fitW.append(w) }
    selfTest = "Calibrando o zoom… medindo (não mexa)"
    let fit: (lag: Double, e: Double, eOld: Double, n: Int, lagFast: Double?, txt: [String]) = await withCheckedContinuation { cont in
      DispatchQueue.global(qos: .userInitiated).async {
        var all: [(PairMeas, CalibWindow)] = [], allFast: [(PairMeas, CalibWindow)] = []
        var txt: [String] = []
        for w in fitW {
          let st = ZoomCalibMath.neighborRatios(w.stab, from: w.tFirst - 0.15, to: w.tLast + 0.25)
          let fa = ZoomCalibMath.neighborRatios(w.fast, from: w.tFirst - 0.15, to: w.tLast + 0.25)
          for m in st where m.conf >= 0.04 { all.append((m, w)) }
          for m in fa where m.conf >= 0.04 { allFast.append((m, w)) }
          txt.append(w.name + String(format: " (%d valores postos em %.0f ms) estab: ", w.setLog.filter { $0.0 >= w.tFirst && $0.0 <= w.tLast }.count, (w.tLast - w.tFirst) * 1000)
            + st.map { String(format: "%.0f:%.4f%@", ($0.b - w.tFirst) * 1000, $0.r, $0.conf >= 0.04 ? "" : "?") }.joined(separator: " ")
            + " | rápida: " + fa.map { String(format: "%.0f:%.4f%@", ($0.b - w.tFirst) * 1000, $0.r, $0.conf >= 0.04 ? "" : "?") }.joined(separator: " "))
        }
        let bs = ZoomCalibMath.bestLag(all), bf = ZoomCalibMath.bestLag(allFast), old = ZoomCalibMath.lagError(all, nil)
        cont.resume(returning: (bs?.0 ?? 0, bs?.1 ?? .infinity, old.0, bs?.2 ?? 0, bf?.0, txt))
      }
    }
    for t in fit.txt { Diag.step("zoom-calib-janela", ["dados": String(t.prefix(7000))]) }
    Diag.step("zoom-calib-ajuste", ["trava_ms": String(format: "%.0f", fit.lag * 1000), "erro": String(format: "%.2e", fit.e), "erro_antiga": String(format: "%.2e", fit.eOld),
      "pares": fit.n, "trava_rapida_ms": fit.lagFast.map { String(format: "%.0f", $0 * 1000) } ?? "-"])
    guard fit.n >= 30, fit.e.isFinite else {
      setFrameLag(previousLag)
      Diag.step("zoom-calib", ["resultado": "SEM PROVA: pouca textura/luz", "pares": fit.n])
      await finish("Calibração: a imagem não deu pra medir (pouca luz ou cena lisa). Ficou como estava — tente num lugar iluminado.")
      return
    }
    // ---- 2) verificação com a trava ligada
    setFrameLag(fit.lag)
    var verW: [CalibWindow] = []
    selfTest = "Calibrando o zoom… conferindo"
    selectZoom(1.3); await sleep(2.8)
    if let w = await window("clique", { self.selectZoom(1.7) }) { verW.append(w) }
    selectZoom(1.3); await sleep(2.8)
    if let w = await window("pinça", { await pinch() }) { verW.append(w) }
    let checks: [(String, (Double, Double), (Double, Double), Int)] = await withCheckedContinuation { cont in
      DispatchQueue.global(qos: .userInitiated).async {
        cont.resume(returning: verW.map { w in let j = ZoomCalibMath.screenJumps(w); return (w.name, j.new, j.old, j.n) })
      }
    }
    var ok = checks.count == 2
    var parts: [String] = []
    for c in checks {
      let pass = c.3 >= 15 && c.1.0 <= max(0.004, 0.5 * c.2.0) && c.1.1 <= max(0.006, 0.5 * c.2.1)
      ok = ok && pass
      parts.append(String(format: "%@: antes salto %.2f%% deriva %.2f%% | agora salto %.2f%% deriva %.2f%% (%d pares) %@",
        c.0, c.2.0 * 100, c.2.1 * 100, c.1.0 * 100, c.1.1 * 100, c.3, pass ? "OK" : "NÃO"))
    }
    Diag.step("zoom-calib", ["resultado": ok ? "LIGADO" : "NÃO PROVOU — mantém", "trava_ms": String(format: "%.0f", fit.lag * 1000), "verificacao": parts.joined(separator: " · ")])
    if ok {
      ZoomLag.save(fit.lag); setFrameLag(fit.lag)
      let before = checks.map { max($0.2.0, $0.2.1) }.max() ?? 0, after = checks.map { max($0.1.0, $0.1.1) }.max() ?? 0
      await finish(String(format: "Zoom calibrado ✓ — escala ao parar: antes %.1f%%, agora %.1f%%", before * 100, after * 100))
    } else {
      setFrameLag(previousLag)
      await finish("Calibração não provou melhora — ficou como estava (resultado enviado pra análise).")
    }
  }
}
