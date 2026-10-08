import CoreVideo
import Foundation

// ESTABILIZAÇÃO DA TELA PRÓPRIA (sem atraso, cega ao zoom). Medido 08/10: com a estabilização de prévia da Apple, depois de
// soltar a pinça a ESCALA da imagem ia e voltava ±0,5% com o zoom comandado parado (ela trata o zoom como movimento).
// Aqui: a tela recebe o quadro CRU da câmera; a cada quadro mede-se só o DESLOCAMENTO (lados/cima/baixo) em relação ao
// anterior numa miniatura 96×54 lida direto do plano de luz (Y) do sensor (~1 ms, sem GPU); o caminho da câmera é suavizado
// (segue movimento intencional) e a diferença vira a correção — nunca escala, então o zoom entra e para exatamente como
// comandado. O arquivo continua com a estabilização escolhida (Extrema/Cinematic).
final class PreviewEIS: @unchecked Sendable {
  static let w = 96, h = 54
  private var prev: [Float]?
  private var pathX = 0.0, pathY = 0.0      // caminho acumulado (fração do quadro)
  private var smX = 0.0, smY = 0.0          // caminho suavizado
  private var lastT = 0.0
  var margin = 0.035                         // quanto a tela pode deslocar (cabe no corte do estabilizador do arquivo)

  // pequena (luma 0–1) direto do plano Y — 8 ou 10 bits
  static func luma(_ buffer: CVPixelBuffer) -> [Float]? {
    guard CVPixelBufferGetPlaneCount(buffer) >= 1 else { return nil }
    CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
    let W = CVPixelBufferGetWidthOfPlane(buffer, 0), H = CVPixelBufferGetHeightOfPlane(buffer, 0), row = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
    let fmt = CVPixelBufferGetPixelFormatType(buffer)
    let sixteen = LutBaker.tenBit.contains(fmt)
    var out = [Float](repeating: 0, count: w * h)
    let sx = W / w, sy = H / h
    for y in 0..<h {
      for x in 0..<w {
        var acc: Float = 0
        for dy in 0..<2 { for dx in 0..<2 {
          let px = x * sx + sx / 4 + dx * (sx / 2), py = y * sy + sy / 4 + dy * (sy / 2)
          if sixteen { acc += Float(base.load(fromByteOffset: py * row + px * 2, as: UInt16.self)) / 65535 }
          else { acc += Float(base.load(fromByteOffset: py * row + px, as: UInt8.self)) / 255 }
        } }
        out[y * w + x] = acc / 4
      }
    }
    return out
  }
  private static func cost(_ a: [Float], _ b: [Float], _ dx: Int, _ dy: Int) -> Float {
    var s: Float = 0; var n = 0
    let x0 = max(8, 8 + dx), x1 = min(w - 8, w - 8 + dx), y0 = max(6, 6 + dy), y1 = min(h - 6, h - 6 + dy)
    guard x1 > x0, y1 > y0 else { return .infinity }
    for y in y0..<y1 { let ra = y * w, rb = (y - dy) * w
      for x in x0..<x1 { let d = a[ra + x] - b[rb + x - dx]; s += d * d; n += 1 } }
    return n > 0 ? s / Float(n) : .infinity
  }
  // deslocamento do quadro atual em relação ao anterior (fração do quadro), com subpixel pela parábola
  private static func shift(_ a: [Float], _ b: [Float]) -> (Double, Double)? {
    var best = (dx: 0, dy: 0, e: Float.infinity)
    for dy in -6...6 { for dx in -6...6 { let e = cost(a, b, dx, dy); if e < best.e { best = (dx, dy, e) } } }
    guard best.e.isFinite, abs(best.dx) < 6, abs(best.dy) < 6 else { return nil }
    func sub(_ m: Float, _ c: Float, _ p: Float) -> Double { let d = m - 2 * c + p; return d > 1e-6 ? Double(0.5 * (m - p) / d) : 0 }
    let fx = Double(best.dx) + sub(cost(a, b, best.dx - 1, best.dy), best.e, cost(a, b, best.dx + 1, best.dy))
    let fy = Double(best.dy) + sub(cost(a, b, best.dx, best.dy - 1), best.e, cost(a, b, best.dx, best.dy + 1))
    return (fx / Double(w), fy / Double(h))
  }
  func reset() { prev = nil; pathX = 0; pathY = 0; smX = 0; smY = 0; lastT = 0 }
  // correção do quadro (coordenadas do sensor, fração): aplicar como deslocamento da imagem
  func process(_ buffer: CVPixelBuffer, t: Double, hold: Bool = false) -> (Double, Double) {
    guard let cur = Self.luma(buffer) else { return (0, 0) }
    let dt = lastT == 0 ? 1.0 / 60 : min(0.1, max(0.004, t - lastT)); lastT = t
    if !hold, let p = prev, let s = Self.shift(cur, p) { pathX += s.0; pathY += s.1 }   // a cena andou s -> a câmera andou −s
    prev = cur
    let k = 1 - exp(-dt / 0.33)
    smX += (pathX - smX) * k; smY += (pathY - smY) * k
    // segura dentro da margem: movimento grande (panorâmica) arrasta o suavizado junto
    if pathX - smX > margin { smX = pathX - margin } else if smX - pathX > margin { smX = pathX + margin }
    if pathY - smY > margin { smY = pathY - margin } else if smY - pathY > margin { smY = pathY + margin }
    return (smX - pathX, smY - pathY)
  }
}
