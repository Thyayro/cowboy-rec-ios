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
    let v = await withCheckedContinuation { cont in
      DispatchQueue.global(qos: .userInitiated).async { cont.resume(returning: ZoomCalibMath.verify(verW, lag: fit.lag)) }
    }
    let ok = v.ok && verW.count == 2
    Diag.step("zoom-calib", ["resultado": ok ? "LIGADO" : "NÃO PROVOU — mantém", "trava_ms": String(format: "%.0f", fit.lag * 1000),
      "verificacao": String(format: "pares %d | erro nova %.2e antiga %.2e | maior nova %.2f%% antiga %.2f%% | ruído %.2f%%", v.n, v.eNew, v.eOld, v.maxNew * 100, v.maxOld * 100, v.floor * 100)])
    if ok {
      ZoomLag.save(fit.lag); setFrameLag(fit.lag)
      await finish(String(format: "Zoom calibrado ✓ — maior erro de escala entre quadros: antes %.1f%%, agora %.1f%%", v.maxOld * 100, v.maxNew * 100))
    } else {
      setFrameLag(previousLag)
      await finish("Calibração não provou melhora — ficou como estava (resultado enviado pra análise).")
    }
  }

  // ---- APRENDIZADO NO USO NORMAL (0.7.6): cada zoom do filmmaker (prévia estabilizada, sem gravar) grava as miniaturas
  // dos quadros estabilizados daquele trecho, mede os vizinhos e guarda só as medidas. Com 3+ zooms úteis: validação
  // cruzada (ZoomCalibMath.decide) — liga a trava sozinho quando prova. Ligada, vigia: errando mais que a antiga, desliga.
  func startZoomAutoLearn() {
    guard autoTimer == nil else { return }
    autoTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in self?.zoomAutoTick() }
  }
  func zoomAutoTick() {
    let rec = renderer.calibRec
    let busy = calibrating || recording || renderer.lightPreview || device?.position != .back
    if busy { if autoWindow != nil { _ = rec.end(); autoWindow = nil }; return }
    guard let last = zoomDriver.lastSet else { return }
    let now = CACurrentMediaTime()
    guard let start = autoWindow else {
      if last.0 > autoHandled + 1e-6 {
        if now - last.0 < 0.6 { rec.begin(fast: false); autoWindow = now - 0.25 } else { autoHandled = last.0 }
      }
      return
    }
    guard now - last.0 > 2.0 || now - start > 8 else { return }
    let data = rec.end(); autoWindow = nil
    let log = zoomDriver.setLogSnapshot(), hist = renderer.zoomHistorySnapshot()
    let sets = log.filter { $0.0 >= start - 0.35 && $0.0 > autoHandled }
    autoHandled = last.0
    guard let tFirst = sets.first?.0, let tLast = sets.last?.0, data.stab.count > 20 else { return }
    let lensAt = renderer.aligner?.lensAt ?? { _ in "" }
    let bounds = zoomBoundaries
    DispatchQueue.global(qos: .utility).async {
      let g = ZoomCalibMath.sample(stab: data.stab, setLog: log, hist: hist, tFirst: tFirst, tLast: tLast, lensAt: lensAt, boundaries: bounds)
      DispatchQueue.main.async { self.zoomAutoAdd(g) }
    }
  }
  func zoomAutoAdd(_ g: GestureSample) {
    let mv = ZoomCalibMath.moving(g)
    guard mv >= 6 else { Diag.step("zoom-auto", ["gesto": "pouca medida (\(g.pairs.count) pares, \(mv) com zoom andando) — escuro/liso ou troca de lente"]); return }
    autoSamples.append(g); if autoSamples.count > 12 { autoSamples.removeFirst() }
    let samples = autoSamples, current = ZoomLag.load()
    DispatchQueue.global(qos: .utility).async {
      if let lag = current {
        let v = ZoomCalibMath.stillGood(Array(samples.suffix(4)), lag: lag)
        DispatchQueue.main.async {
          if !v.ok { ZoomLag.save(nil); self.setFrameLag(nil); self.autoSamples = [] }
          Diag.step("zoom-auto", ["resultado": v.ok ? "ligada e conferida" : "DESLIGOU (errando mais que a antiga)", "trava_ms": String(format: "%.0f", lag * 1000),
            "conferencia": String(format: "pares %d erro nova %.2e antiga %.2e", v.n, v.eNew, v.eOld)])
        }
      } else {
        let d = ZoomCalibMath.decide(samples)
        DispatchQueue.main.async {
          if let lag = d.lag, ZoomLag.load() == nil { ZoomLag.save(lag); self.setFrameLag(lag) }
          Diag.step("zoom-auto", ["resultado": d.txt])
        }
      }
    }
  }
}
