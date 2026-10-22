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
  /// imagem + as 8 cópias espelhadas em volta (cortada na margem pedida; além dela repete a borda)
  static func mirrorPad(_ img: CIImage, pad: CGFloat) -> CIImage {
    let e = img.extent
    var out = img
    for dx in -1...1 { for dy in -1...1 where dx != 0 || dy != 0 {
      let ax: CGFloat = dx < 0 ? 2 * e.minX : dx > 0 ? 2 * e.maxX : 0
      let ay: CGFloat = dy < 0 ? 2 * e.minY : dy > 0 ? 2 * e.maxY : 0
      let t = CGAffineTransform(a: dx == 0 ? 1 : -1, b: 0, c: 0, d: dy == 0 ? 1 : -1, tx: ax, ty: ay)
      out = img.transformed(by: t).composited(over: out)
    } }
    return out.cropped(to: e.insetBy(dx: -pad, dy: -pad)).clampedToExtent()
  }
  /// tela: blur gaussiano + modo Tela, misturado pela intensidade
  static func apply(_ image: CIImage, level id: Int) -> CIImage {
    guard let m = level(id) else { return image }
    let e = image.extent
    guard e.width > 1, e.height > 1, e.width.isFinite, e.height.isFinite else { return image }
    // 0.10.5: o gaussiano roda numa cópia de 1/4 (desfoque grande = igual no olho) — em resolução cheia travava o zoom
    let q: CGFloat = 0.25
    // 0.11.9: a borda era "comida" (repetir o último pixel virava faixa de fumaça na Pesada) — agora a imagem continua
    // ESPELHADA além da borda por 3,5σ, então o desfoque perto da borda vê conteúdo de verdade, como no meio do quadro
    let sig = m.sigma * Double(max(e.width, e.height)) * Double(q)
    let small = mirrorPad(image.transformed(by: CGAffineTransform(scaleX: q, y: q)), pad: CGFloat(sig * 3.5 + 2))
    let blurred = small.applyingGaussianBlur(sigma: sig)
      .transformed(by: CGAffineTransform(scaleX: 1 / q, y: 1 / q)).cropped(to: e)
    let screen = blurred.applyingFilter("CIScreenBlendMode", parameters: [kCIInputBackgroundImageKey: image])
    return image.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: screen, kCIInputTimeKey: m.amount]).cropped(to: e)
  }
}
