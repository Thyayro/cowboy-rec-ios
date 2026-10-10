import CoreImage

// NÉVOA "dream" (0.10.3) — a receita do DaVinci/Premiere do filmmaker: uma cópia DESFOCADA da imagem por cima no modo
// ESCURECER (darken = min(original, desfocada)), na intensidade do nível. As partes escuras espalham uma névoa suave e limpa
// sobre as claras, sem levantar o preto nem estourar as luzes. Desligada por padrão. Mesma conta na tela (Core Image) e no
// arquivo (shader Metal do LutBaker, sobre a cor final): sigma = fração do LADO MAIOR do quadro, então tela e arquivo batem.
enum Mist {
  struct Level: Sendable { let id: Int; let label: String; let icon: String; let sigma: Double; let amount: Double }
  static let levels: [Level] = [
    Level(id: 1, label: "Leve", icon: "cloud.fog", sigma: 0.004, amount: 0.35),
    Level(id: 2, label: "Média", icon: "cloud.fog.fill", sigma: 0.007, amount: 0.55),
    Level(id: 3, label: "Pesada", icon: "smoke.fill", sigma: 0.011, amount: 0.8),
  ]
  static func level(_ id: Int) -> Level? { levels.first { $0.id == id } }
  /// tela: blur gaussiano + Escurecer, misturado pela intensidade
  static func apply(_ image: CIImage, level id: Int) -> CIImage {
    guard let m = level(id) else { return image }
    let e = image.extent
    guard e.width > 1, e.height > 1, e.width.isFinite, e.height.isFinite else { return image }
    let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: m.sigma * Double(max(e.width, e.height))).cropped(to: e)
    let dark = blurred.applyingFilter("CIDarkenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    return image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: dark, kCIInputTimeKey: m.amount]).cropped(to: e)
  }
}
