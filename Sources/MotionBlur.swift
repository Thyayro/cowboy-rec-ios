import Foundation

// DESFOQUE DE MOVIMENTO (0.8.9) — o rastro que uma câmera de cinema deixa com o obturador a 180° (ou 360° no "forte",
// estilo After Effects), feito pela MESMA conta na tela, no arquivo (shader) e no render da VPS (fxblur.c):
//  - zoom: rastro RADIAL a partir do centro do quadro = velocidade do zoom (ln/s) × tempo do obturador;
//  - movimento: rastro na direção do giro do aparelho (giroscópio, média de ±0,25 s ≈ o caminho que a estabilização segue —
//    o tremor que ela tira não vira rastro), em pixels = giro × obturador × distância focal do quadro.
// O "obturador" é o sintético MENOS a exposição real (de noite a exposição já deixa o rastro natural: não soma).
// Coordenadas: as do quadro do sensor (x = largura do buffer, y = linhas pra baixo), normalizadas 0…1.
struct BlurParams: Equatable {
  var zoom: Double = 0      // ln(escala) total do rastro radial (centro do quadro)
  var mx: Double = 0        // deslocamento total em x (fração da largura)
  var my: Double = 0        // deslocamento total em y (fração da altura)
  var trail: Double = 0     // maior rastro em pixels do quadro (canto no zoom + movimento)
  static let none = BlurParams()
  var active: Bool { trail >= MotionBlur.minTrail }
  // amostras pra um quadro onde 1 px do quadro vale `pxScale` px de quem desenha (tela: < 1); passo ≤ ~4 px, com teto
  func samples(pxScale: Double = 1, spacing: Double = 4, max cap: Int) -> Int {
    guard active, cap >= 2 else { return 1 }
    return min(cap, max(2, Int((trail * pxScale / spacing).rounded(.up))))
  }
}

enum MotionBlur {
  static let minTrail = 3.0          // abaixo de 3 px (no quadro 4K) o rastro não se vê: desligado (sem custo)
  // omega: giro do aparelho (rad/s, eixos do CoreMotion: x direita, y topo, z pra fora da tela) já suavizado
  // zoomSpeed: d ln(zoom)/dt do conteúdo do quadro (aparelho × digital)
  // shutter: tempo do obturador sintético (s), já sem a exposição real
  // focalNorm: distância focal do quadro em larguras do quadro (= 1 / (2·tan(campo horizontal / 2)))
  static func params(zoomSpeed: Double, omega: (x: Double, y: Double, z: Double), shutter: Double, focalNorm: Double, width: Double, height: Double) -> BlurParams {
    guard shutter > 0, width > 0, height > 0, focalNorm > 0 else { return .none }
    let z = zoomSpeed * shutter
    // ponto parado no mundo, aparelho girando com ω: a direção dele no aparelho anda (ω_y, −ω_x); no quadro do sensor
    // da traseira (deitado: x do buffer = −y do aparelho, y do buffer = −x do aparelho) isso vira (ω_x, −ω_y)·f
    let mx = omega.x * shutter * focalNorm
    let my = -omega.y * shutter * focalNorm * width / height
    let corner = abs(z) * 0.5 * (width * width + height * height).squareRoot()
    let pan = ((mx * width) * (mx * width) + (my * height) * (my * height)).squareRoot()
    var p = BlurParams(zoom: z, mx: mx, my: my, trail: corner + pan)
    if !p.active { p = .none }
    return p
  }
  // obturador sintético: ângulo/360 do tempo de um quadro, menos o que a exposição real já borra
  static func shutter(angle: Double, frameDuration: Double, exposure: Double) -> Double {
    max(0, angle / 360 * frameDuration - max(0, exposure))
  }
  // distância focal do quadro estabilizado: campo do formato no zoom 1 do aparelho ÷ zoom do aparelho ÷ corte da
  // estabilização ÷ zoom digital
  static func focalNorm(fovDegrees: Double, zoomRaw: Double, crop: Double, digital: Double) -> Double {
    let half = max(0.01, min(1.5, fovDegrees * .pi / 360))
    return max(1, zoomRaw) * max(1, crop) * max(1, digital) / (2 * tan(half))
  }
  // posição (fração 0…1 do caminho, centrada) da amostra i de n com o deslocamento j ∈ [−0,5; 0,5) do pixel
  @inline(__always) static func u(_ i: Int, _ n: Int, jitter j: Double = 0) -> Double { (Double(i) + 0.5 + j) / Double(n) - 0.5 }
  // ruído intercalado (Jimenez): cada pixel desloca as amostras um pouco — o rastro sai liso, sem "cópias" em degrau
  @inline(__always) static func jitter(x: Int, y: Int) -> Double {
    let f = 0.06711056 * Double(x) + 0.00583715 * Double(y)
    let g = 52.9829189 * (f - f.rounded(.down))
    return g - g.rounded(.down) - 0.5
  }
  // ponto do quadro (0…1) que a amostra de posição u lê
  @inline(__always) static func source(_ uvx: Double, _ uvy: Double, _ p: BlurParams, _ u: Double) -> (Double, Double) {
    let s = exp(p.zoom * u)
    return (0.5 + (uvx - 0.5) * s + p.mx * u, 0.5 + (uvy - 0.5) * s + p.my * u)
  }
  // linha do arquivo de efeitos (render na VPS): t (ms desde o 1º quadro), zoom, mx, my, amostras
  static func line(t: Double, _ p: BlurParams, samples n: Int) -> String {
    String(format: "%.1f,%.6f,%.6f,%.6f,%d\n", t * 1000, p.zoom, p.mx, p.my, n)
  }
}
