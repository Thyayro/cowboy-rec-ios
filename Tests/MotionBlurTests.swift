import Foundation

// Teste do build: a conta do desfoque de movimento (tela, arquivo e render da VPS usam a mesma) tem que pôr o rastro no
// EIXO certo do quadro do sensor, no tamanho do obturador, SÓ em movimento rápido (calor) e liso no rastro longo (duas
// etapas). Se não passar, o app não sai.
func check(_ ok: Bool, _ msg: String) { if ok { print("OK   " + msg) } else { print("FALHA " + msg); exit(1) } }

@main struct MotionBlurTests {
  static func main() {
    let W = 3840.0, H = 2160.0, frame = 1.0 / 60
    let sh = MotionBlur.shutter(angle: 180, frameDuration: frame, exposure: 1.0 / 2000)
    check(abs(sh - (1.0 / 120 - 1.0 / 2000)) < 1e-9, "obturador 180° menos a exposição real")
    check(MotionBlur.shutter(angle: 180, frameDuration: frame, exposure: 1.0 / 60) == 0, "de noite (exposição ≥ obturador) não soma rastro")
    check(abs(MotionBlur.shutter(angle: 720, frameDuration: frame, exposure: 0) - 2.0 / 60) < 1e-12, "pesado 720° = dois quadros de rastro")
    let f1 = MotionBlur.focalNorm(fovDegrees: 106, zoomRaw: 2, crop: 1.06, digital: 1)   // 1× na traseira
    check(abs(f1 - 2 * 1.06 / (2 * tan(53 * Double.pi / 180))) < 1e-9, "distância focal do quadro (zoom × corte)")
    let f5 = MotionBlur.focalNorm(fovDegrees: 106, zoomRaw: 10, crop: 1.06, digital: 1)

    // CALOR: mão parada/andando devagar — nada, nem no 5× com o obturador pesado
    let still = MotionBlur.params(zoomSpeed: 0, omega: (x: 0.15, y: -0.2, z: 0.1), shutter: 2.0 / 60, focalNorm: f5, width: W, height: H)
    check(!still.active && still.samples(max: 12) == 1 && still.stages() == (1, 1), "mão normal no 5× (0,25 rad/s): sem desfoque, sem custo")
    let slowZoom = MotionBlur.params(zoomSpeed: 0.5, omega: (x: 0, y: 0, z: 0), shutter: 2.0 / 60, focalNorm: f1, width: W, height: H)
    check(!slowZoom.active, "pinça devagar (0,5 ln/s): sem desfoque")

    // panorâmica RÁPIDA (girar em volta do eixo y do aparelho em pé) = horizontal da tela = eixo y do buffer
    let pan = MotionBlur.params(zoomSpeed: 0, omega: (x: 0, y: 1.5, z: 0), shutter: 1.0 / 120, focalNorm: f1, width: W, height: H)
    let expect = 1.5 / 120 * f1 * W
    check(pan.mx == 0 && abs(pan.my) > 0, "panorâmica vira rastro no eixo y do buffer (horizontal da tela em pé)")
    check(abs(pan.trail - expect) < 0.01, String(format: "panorâmica 1,5 rad/s no 1×: rastro %.1f px (esperado %.1f)", pan.trail, expect))
    check(abs(abs(pan.my) * H - expect) < 1e-6, "rastro em pixels igual nos dois eixos (pixel quadrado)")
    let half = MotionBlur.params(zoomSpeed: 0, omega: (x: 0, y: 0.9, z: 0), shutter: 1.0 / 120, focalNorm: f1, width: W, height: H)
    check(half.active && half.trail < 0.9 / 120 * f1 * W * 0.6, "entre os limites o rastro entra SUAVE (sem estalo)")
    let tilt = MotionBlur.params(zoomSpeed: 0, omega: (x: 1.5, y: 0, z: 0), shutter: 1.0 / 120, focalNorm: f1, width: W, height: H)
    check(tilt.my == 0 && tilt.mx > 0, "inclinar vira rastro no eixo x do buffer (vertical da tela em pé)")
    let diag = MotionBlur.params(zoomSpeed: 0, omega: (x: 1.5, y: 1.5, z: 0), shutter: 1.0 / 120, focalNorm: f1, width: W, height: H)
    check(diag.mx > 0 && diag.my < 0, "diagonal: (ω_x, −ω_y) no quadro do sensor")
    let pan5 = MotionBlur.params(zoomSpeed: 0, omega: (x: 0, y: 1.5, z: 0), shutter: 1.0 / 120, focalNorm: f5, width: W, height: H)
    check(abs(pan5.trail / pan.trail - 5) < 1e-6, "no 5× o mesmo giro deixa rastro 5× maior")
    let roll = MotionBlur.params(zoomSpeed: 0, omega: (x: 0, y: 0, z: 2), shutter: 1.0 / 120, focalNorm: f1, width: W, height: H)
    check(roll.active && roll.mx == 0 && roll.my == 0 && abs(roll.roll - 2.0 / 120) < 1e-12, "giro no eixo da lente vira rastro circular")

    // zoom de edição (rápido): rastro radial = velocidade × obturador × meia diagonal
    let zoom = MotionBlur.params(zoomSpeed: 2, omega: (x: 0, y: 0, z: 0), shutter: 1.0 / 120, focalNorm: f1, width: W, height: H)
    let corner = 2.0 / 120 * 0.5 * (W * W + H * H).squareRoot()
    check(abs(zoom.trail - corner) < 1e-6 && abs(zoom.trail - 36.7) < 0.1, String(format: "zoom 2 ln/s: rastro no canto %.1f px", zoom.trail))
    check(zoom.samples(max: 12) == 10 && zoom.samples(max: 6) == 6, "amostras: 1 a cada 4 px, com teto")
    // pesado: zoom de 0,5→5× em ~0,15 s (pico ~20 ln/s) com 720°: rastro enorme -> duas etapas
    let edit = MotionBlur.params(zoomSpeed: 20, omega: (x: 0, y: 0, z: 0), shutter: 2.0 / 60, focalNorm: f1, width: W, height: H)
    let st = edit.stages(cap: 12)
    check(st.0 >= 8 && st.1 >= 8 && st.0 <= 12 && st.1 <= 12, "rastro de \(Int(edit.trail)) px em duas etapas \(st.0)×\(st.1)")
    let zs = zoom.stages(cap: 12)
    check(zs.0 * zs.1 >= 13 && zs.0 <= 12, "rastro médio coberto (\(zs.0)×\(zs.1))")
    check(MotionBlur.params(zoomSpeed: 1.2, omega: (x: 0, y: 0, z: 0), shutter: 1.0 / 120, focalNorm: f1, width: W, height: H).stages().1 == 1, "rastro curto: uma etapa só")

    // ruído por pixel em [−0,5; 0,5) e amostras centradas no pixel (rastro simétrico, sem deslocar a imagem)
    var lo = 1.0, hi = -1.0
    for y in 0..<64 { for x in 0..<64 { let j = MotionBlur.jitter(x: x, y: y); lo = min(lo, j); hi = max(hi, j) } }
    check(lo >= -0.5 && hi < 0.5 && hi - lo > 0.9, "ruído intercalado cobre o passo inteiro")
    var cx = 0.0, cy = 0.0
    let n = 8
    for i in 0..<n { let s = MotionBlur.source(0.3, 0.7, pan, MotionBlur.u(i, n)); cx += s.0; cy += s.1 }
    check(abs(cx / Double(n) - 0.3) < 1e-9 && abs(cy / Double(n) - 0.7) < 1e-9, "média das amostras = o próprio pixel")
    let c0 = MotionBlur.source(0.5, 0.5, roll, 0.4)
    check(abs(c0.0 - 0.5) < 1e-12 && abs(c0.1 - 0.5) < 1e-12, "o centro não gira")

    // referência na CPU (a mesma do shader e do fxblur.c): linha clara de 1 px, rastro horizontal de ~20 px
    let w = 200, h = 64   // 64 linhas: o ruído muda por linha; o perfil médio é o rastro que o olho vê
    var img = [Double](repeating: 0, count: w * h)
    for y in 0..<h { img[y * w + 100] = 1 }
    let p = BlurParams(zoom: 0, mx: 20.0 / Double(w), my: 0, roll: 0, trail: 20)
    let ns = p.samples(max: 12)
    var out = [Double](repeating: 0, count: w * h)
    for y in 0..<h { for x in 0..<w {
      let j = MotionBlur.jitter(x: x, y: y)
      var acc = 0.0
      for i in 0..<ns {
        let s = MotionBlur.source((Double(x) + 0.5) / Double(w), (Double(y) + 0.5) / Double(h), p, MotionBlur.u(i, ns, jitter: j), aspect: Double(w) / Double(h))
        let fx = s.0 * Double(w) - 0.5, ix = Int(fx.rounded(.down)), ax = fx - Double(ix)   // bilinear (borda presa)
        let a = img[y * w + max(0, min(w - 1, ix))], b = img[y * w + max(0, min(w - 1, ix + 1))]
        acc += a * (1 - ax) + b * ax
      }
      out[y * w + x] = acc / Double(ns)
    } }
    var row = [Double](repeating: 0, count: w)
    for y in 0..<h { for x in 0..<w { row[x] += out[y * w + x] / Double(h) } }
    let energy = row.reduce(0, +), lit = row.filter { $0 > 0.01 }.count
    check(abs(energy - 1) < 0.08, String(format: "rastro conserva a luz (soma %.3f)", energy))
    check(lit >= 16 && lit <= 24, "rastro com ~20 px de largura (\(lit))")
    check(row.max()! < 0.2, "linha espalhada (pico \(String(format: "%.2f", row.max()!)))")

    let line = MotionBlur.line(t: 1.5, zoom, stages: (10, 1))
    let parts = line.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",")
    check(parts.count == 7 && parts[0] == "1500.0" && parts[4] == "10" && parts[5] == "1", "linha do arquivo de efeitos: \(line.trimmingCharacters(in: .newlines))")
    print("DESFOQUE OK")
  }
}
