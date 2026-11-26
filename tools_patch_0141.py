# 0.14.1: troca de lente na tela SEM ATRASO (padrão desde o modo mestre 0.13.8) sem quebra de posição
import io
def patch(path, reps):
    s = io.open(path, encoding='utf-8').read()
    for a, b in reps:
        assert s.count(a) == 1, (path, a[:90])
        s = s.replace(a, b)
    io.open(path, 'w', encoding='utf-8', newline='\n').write(s)

patch('Sources/PreviewEIS.swift', [
("  private var lastT = 0.0\n",
 "  private var lastT = 0.0\n  private var lastSensor = 0                 // 0.14.1: lente do quadro anterior\n"),
("  func reset() { prev = nil; pathX = 0; pathY = 0; smX = 0; smY = 0; lastT = 0 }",
 "  func reset() { prev = nil; pathX = 0; pathY = 0; smX = 0; smY = 0; lastT = 0; lastSensor = 0 }"),
("  func process(_ buffer: CVPixelBuffer, t: Double, hold: Bool = false) -> (Double, Double) {\n    guard let cur = Self.luma(buffer) else { return (0, 0) }\n    let dt = lastT == 0 ? 1.0 / 60 : min(0.1, max(0.004, t - lastT)); lastT = t\n    if !hold, let p = prev, let s = Self.shift(cur, p) { pathX += s.0; pathY += s.1 }   // a cena andou s -> a câmera andou −s",
 "  func process(_ buffer: CVPixelBuffer, t: Double, hold: Bool = false, sensor: Int = 0) -> (Double, Double) {\n    guard let cur = Self.luma(buffer) else { return (0, 0) }\n    let dt = lastT == 0 ? 1.0 / 60 : min(0.1, max(0.004, t - lastT)); lastT = t\n    // 0.14.1: quadro de OUTRA lente não é tremor da mão. Antes o pulo da troca entrava como movimento e a tela\n    // \"corrigia\" até 3,5% (a quebra de posição grosseira saindo do 0,5x; 0,5x->5x = 2 trocas = 2 quebras)\n    let switched = sensor != 0 && lastSensor != 0 && sensor != lastSensor\n    if sensor != 0 { lastSensor = sensor }\n    if !hold, !switched, let p = prev, let s = Self.shift(cur, p) { pathX += s.0; pathY += s.1 }   // a cena andou s -> a câmera andou −s"),
])

patch('Sources/PreviewRenderer.swift', [
("  private var fastCorr = (0.0, 0.0)\n",
 "  private var fastCorr = (0.0, 0.0)\n  private var fastSid = 0                                   // 0.14.1: lente do quadro rápido\n  private var prevLive: (image: CIImage, sid: Int)?        // 0.14.1: último quadro mostrado na tela sem atraso\n  private var liveXfade: (image: CIImage, t0: Double)?\n"),
("    let corr = lightPreview ? eis.process(buffer, t: pts, hold: zooming) : (0, 0)",
 "    let corr = lightPreview ? eis.process(buffer, t: pts, hold: zooming, sensor: sid) : (0, 0)"),
("    fastBuffer = buffer; fastPTS = pts; fastFresh = true; fastCorr = corr\n",
 "    fastBuffer = buffer; fastPTS = pts; fastFresh = true; fastCorr = corr; fastSid = sid\n"),
("    let livePTS = fastPTS\n",
 "    let livePTS = fastPTS, liveSid = fastSid\n"),
("        geo: aligner?.geometry(\"fast\", at: livePTS ?? now) ?? .identity, shake: corrNow, pts: livePTS)",
 "        geo: .identity, shake: corrNow, pts: livePTS, sid: liveSid, now: now)   // 0.14.1: sem o alinhador antigo (empurrava ~3% + ampliava na troca)"),
("  private func drawLive(_ view: MTKView, _ buffer: CVPixelBuffer, crop: Double, cube: Data?, size: Int, orient: CGImagePropertyOrientation, mirror: Bool, match: LensCorrection, geo: SwitchGeometry, shake: (Double, Double) = (0, 0), pts: Double? = nil) {",
 "  private func drawLive(_ view: MTKView, _ buffer: CVPixelBuffer, crop: Double, cube: Data?, size: Int, orient: CGImagePropertyOrientation, mirror: Bool, match: LensCorrection, geo: SwitchGeometry, shake: (Double, Double) = (0, 0), pts: Double? = nil, sid: Int = 0, now: Double = CACurrentMediaTime()) {"),
("    image = image.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: target)))\n    let destination = CIRenderDestination(width: Int(target.width), height: Int(target.height), pixelFormat: view.colorPixelFormat, commandBuffer: commandBuffer) { drawable.texture }\n    destination.isFlipped = true\n    _ = try? context.startTask(toRender: image, to: destination)\n    commandBuffer.present(drawable)\n    commandBuffer.commit()\n    frames += 1\n  }",
 "    image = image.composited(over: CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: target)))\n    // 0.14.1: troca de lente = o mesmo dissolve curto da tela estabilizada (0,18 s), sem deslocar nem ampliar\n    if let pv = prevLive, pv.sid != 0, sid != 0, pv.sid != sid { liveXfade = (pv.image, now) }\n    let fresh = image\n    if let x = liveXfade {\n      let a = (now - x.t0) / Self.xfadeDur\n      if a >= 1 || a < 0 { liveXfade = nil } else { image = x.image.applyingFilter(\"CIDissolveTransition\", parameters: [kCIInputTargetImageKey: image, kCIInputTimeKey: a * a * (3 - 2 * a)]) }\n    }\n    prevLive = (fresh, sid)\n    let destination = CIRenderDestination(width: Int(target.width), height: Int(target.height), pixelFormat: view.colorPixelFormat, commandBuffer: commandBuffer) { drawable.texture }\n    destination.isFlipped = true\n    _ = try? context.startTask(toRender: image, to: destination)\n    commandBuffer.present(drawable)\n    commandBuffer.commit()\n    frames += 1\n  }"),
("  func freeze() { lock.lock(); frozen = true; pending = nil; prevShown = nil; xfade = nil;",
 "  func freeze() { lock.lock(); frozen = true; pending = nil; prevShown = nil; xfade = nil; prevLive = nil; liveXfade = nil;"),
])

s = io.open('project.yml', encoding='utf-8').read()
s = s.replace('MARKETING_VERSION: "0.14.0"', 'MARKETING_VERSION: "0.14.1"').replace('CURRENT_PROJECT_VERSION: "93"', 'CURRENT_PROJECT_VERSION: "94"')
io.open('project.yml', 'w', encoding='utf-8', newline='\n').write(s)
print('ok')
