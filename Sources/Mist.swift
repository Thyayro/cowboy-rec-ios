import CoreImage

// NÉVOA "dream" — a receita do DaVinci/Premiere do filmmaker: uma cópia DESFOCADA da imagem por cima no modo TELA
// (screen = 1 − (1 − original)·(1 − desfocada)), na intensidade do nível. As luzes espalham uma névoa brilhante e limpa
// (glow dream) sem mexer na cor de base. 0.10.3 saiu em Escurecer por engano; 0.10.4 = Tela, como ele faz.
// Desligada por padrão. Mesma conta na tela (Core Image) e no arquivo (shader Metal do LutBaker, sobre a cor final):
// sigma = fração do LADO MAIOR do quadro, então tela e arquivo batem.
enum Mist {
  struct Level: Sendable { let id: Int; let label: String; let icon: String; let sigma: Double; let amount: Double }
  static let levels: [Level] = [
    Level(id: 1, label: "Leve", icon: "cloud.fog", sigma: 0.004, amount: 0.25),
    Level(id: 2, label: "Média", icon: "cloud.fog.fill", sigma: 0.007, amount: 0.4),
    Level(id: 3, label: "Pesada", icon: "smoke.fill", sigma: 0.011, amount: 0.6),
  ]
  static func level(_ id: Int) -> Level? { levels.first { $0.id == id } }
  /// tela: blur gaussiano + modo Tela, misturado pela intensidade
  static func apply(_ image: CIImage, level id: Int) -> CIImage {
    guard let m = level(id) else { return image }
    let e = image.extent
    guard e.width > 1, e.height > 1, e.width.isFinite, e.height.isFinite else { return image }
    // 0.10.5: o gaussiano roda numa cópia de 1/4 (desfoque grande = igual no olho) — em resolução cheia travava o zoom
    let q: CGFloat = 0.25
    let small = image.clampedToExtent().transformed(by: CGAffineTransform(scaleX: q, y: q))
    let blurred = small.applyingGaussianBlur(sigma: m.sigma * Double(max(e.width, e.height)) * Double(q))
      .transformed(by: CGAffineTransform(scaleX: 1 / q, y: 1 / q)).cropped(to: e)
    let screen = blurred.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    return image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: screen, kCIInputTimeKey: m.amount]).cropped(to: e)
  }
}
