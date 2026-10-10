import CoreImage
import Foundation

// VINHETA DA ULTRA NO APPLE LOG (0.10.5) — o filmmaker via "sombra em cima e embaixo, na 0,5×". Medido em 2.285 quadros da
// tela (trechos 08–10/10, zoom de base, cenas variadas): a ultra perde ~0,8–1,5 stop nas pontas COMPRIDAS do sensor (em pé =
// topo e rodapé), canto ≈ meio da borda (vinheta radial de sensor 4:3 recortado em 16:9); principal e tele ≈ 0 na metade de
// cima (o escuro de baixo nelas é cena: teclado/mesa). O Apple Log entrega sem a correção que a câmera original aplica.
// Correção = ganho radial 2^(k·r⁴) (k um pouco ABAIXO do medido: nunca clarear borda demais), r = raio do quadro mostrado
// (1 = canto) ÷ zoom dentro da lente (no 0,7× aparece menos borda do sensor). Aplicado na cor de tela (gama), como o
// ganho linear numa curva ~2,4: m = 2^(k·r⁴/2,4). Mesma conta na tela (Core Image) e no arquivo (shader do LutBaker).
enum LensShading {
  static func k(lens: String?) -> Double { lens == "ultra" ? 2.0 : 0 }
  private static let lock = NSLock()
  private static var cache: (key: String, image: CIImage)?
  /// mapa de ganho pequeno (48 colunas), esticado no tamanho da imagem
  static func gain(extent e: CGRect, k: Double, zoom: Double) -> CIImage? {
    guard k > 0, e.width > 2, e.height > 2, e.width.isFinite, e.height.isFinite else { return nil }
    let z = max(1, zoom)
    let key = "\(Int(e.width))x\(Int(e.height))k\(Int(k * 100))z\(Int((z * 50).rounded()))"
    lock.lock(); defer { lock.unlock() }
    let small: CIImage
    if let c = cache, c.key == key { small = c.image } else {
      let w = 48, h = max(2, Int((48 * e.height / e.width).rounded()))
      let diag = sqrt(e.width * e.width + e.height * e.height)
      var px = [Float16](repeating: 1, count: w * h * 4)
      for y in 0..<h { for x in 0..<w {
        let dx = (Double(x) + 0.5) / Double(w) * 2 - 1, dy = (Double(y) + 0.5) / Double(h) * 2 - 1
        let r = sqrt(pow(dx * e.width / diag, 2) + pow(dy * e.height / diag, 2)) / z
        let m = Float16(pow(2, k * r * r * r * r / 2.4))
        let i = (y * w + x) * 4; px[i] = m; px[i + 1] = m; px[i + 2] = m; px[i + 3] = 1
      } }
      let data = px.withUnsafeBytes { Data($0) }
      small = CIImage(bitmapData: data, bytesPerRow: w * 8, size: CGSize(width: w, height: h), format: .RGBAh, colorSpace: nil)
      cache = (key, small)
    }
    let s = small.extent
    return small.transformed(by: CGAffineTransform(scaleX: e.width / s.width, y: e.height / s.height).concatenating(CGAffineTransform(translationX: e.minX, y: e.minY)))
  }
  static func apply(_ image: CIImage, lens: String?, zoom: Double) -> CIImage {
    let e = image.extent
    guard let g = gain(extent: e, k: k(lens: lens), zoom: zoom) else { return image }
    return g.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: image]).cropped(to: e)
  }
}
