import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers

// O QUE A TELA MOSTROU (0.7.7) — diagnóstico do "estacionar" sem pedir teste: em volta de cada zoom (do início até 2,5 s
// depois de parar), a prévia ESTABILIZADA guarda o próprio quadro desenhado em miniatura (cinza, 160 px de largura, 30
// qps) com a ampliação usada, a da conta antiga, o zoom, a lente e as horas; ao fim, sobe pra VPS (/api/rec-diag-clip).
// Lá o quadro a quadro mostra exatamente o que o filmmaker viu — escala, posição, troca de lente — pra medir antes de
// mexer. No máximo 8 trechos por abertura; nunca gravando.
final class PreviewTap: @unchecked Sendable {
  struct Frame { let at: Double; let pts: Double; let k: Double; let kOld: Double; let g: Double; let z: Double; let lens: String; let jpg: Data }
  private let queue = DispatchQueue(label: "cowboy.previewtap", qos: .utility)
  private(set) var active = false
  private var start = 0.0, lastMove = 0.0, skip = false
  private var frames: [Frame] = []
  private var clipsLeft = 3
  var allowed: () -> Bool = { false }
  var onClip: ((Data) -> Void)?

  // thread da tela, a cada desenho
  func tick(now: Double, moving: Bool) {
    if moving { lastMove = now }
    if !active {
      if moving && clipsLeft > 0 && allowed() { active = true; start = now; frames = []; skip = false }
      return
    }
    if now - lastMove > 2.5 || now - start > 8 || !allowed() { finish() }
  }
  // thread da tela: o quadro que acabou de ir pra tela (imagem final, no tamanho da tela)
  func offer(_ image: CIImage, size: CGSize, context: CIContext, at: Double, pts: Double, k: Double, kOld: Double, g: Double, z: Double, lens: String) {
    guard active else { return }
    skip.toggle(); if skip { return }   // 30 qps
    let s = 160 / max(1, size.width)
    let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
    let rect = CGRect(x: 0, y: 0, width: 160, height: (size.height * s).rounded(.down))
    guard let cg = context.createCGImage(small, from: rect, format: .L8, colorSpace: CGColorSpaceCreateDeviceGray()) else { return }
    queue.async {
      let data = NSMutableData()
      guard let dst = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return }
      CGImageDestinationAddImage(dst, cg, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
      guard CGImageDestinationFinalize(dst) else { return }
      let f = Frame(at: at, pts: pts, k: k, kOld: kOld, g: g, z: z, lens: lens, jpg: data as Data)
      DispatchQueue.main.async { if self.active { self.frames.append(f) } }
    }
  }
  private func finish() {
    active = false; clipsLeft -= 1
    let start = self.start, lastMove = self.lastMove
    queue.async {   // depois das miniaturas que ainda estão sendo comprimidas
      DispatchQueue.main.async {
        let fr = self.frames; self.frames = []
        guard fr.count > 10 else { return }
        let body: [String: Any] = ["app": "cowboy-rec-ios " + Diag.version, "inicio": start, "parou": lastMove,
          "quadros": fr.map { ["at": $0.at, "pts": $0.pts, "k": $0.k, "ko": $0.kOld, "g": $0.g, "z": $0.z, "lente": $0.lens, "img": $0.jpg.base64EncodedString()] }]
        guard let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        self.onClip?(data)
      }
    }
  }
}
