import AVFoundation
import QuartzCore
import UIKit

// ZOOM COMO O DA CÂMERA DO IPHONE, no ritmo dos QUADROS da câmera (não da tela):
// - toque numa lente: UMA rampa nativa do AVFoundation (o ISP aplica em sincronia com cada quadro, escala progressiva e
//   contínua, velocidade constante em escala logarítmica); nunca é reiniciada no meio;
// - pinça/roda: o alvo segue o dedo e o zoom anda um passo amortecido POR QUADRO capturado (chamado pela saída de vídeo).
// 0.5.9 atualizava a 120 Hz pela tela com a câmera a 60 qps: passos irregulares no meio da escala.
final class ZoomDriver: @unchecked Sendable {
  weak var device: AVCaptureDevice?
  private let lock = NSLock()
  private var target: CGFloat?
  private var lastTick = 0.0
  private var lastTickWall = 0.0   // quando o último quadro CHEGOU (relógio de agora)

  func attach(_ d: AVCaptureDevice) { lock.lock(); device = d; target = nil; lock.unlock() }
  private func clamp(_ d: AVCaptureDevice, _ z: CGFloat) -> CGFloat { max(d.minAvailableVideoZoomFactor, min(d.maxAvailableVideoZoomFactor, z)) }
  private func configure(_ d: AVCaptureDevice, _ body: () -> Void) {
    _ = CowboyObjC.catching { if (try? d.lockForConfiguration()) != nil { body(); d.unlockForConfiguration() } }
  }
  // gesto: só atualiza o alvo; quem anda é o tick de cada quadro
  func follow(_ factor: CGFloat) {
    lock.lock(); defer { lock.unlock() }
    guard let d = device else { return }
    if target == nil { configure(d) { if d.isRampingVideoZoom { d.cancelVideoZoomRamp() } } }
    let z = clamp(d, factor)
    target = z
    // sem quadro há mais de 120 ms (saída parada): o gesto não pode "travar" — aplica direto
    if CACurrentMediaTime() - lastTickWall > 0.25 { configure(d) { d.videoZoomFactor = z } }
  }
  func endFollow() {}   // soltou o dedo: o zoom termina de chegar no alvo (amortecido) e para sozinho
  // lente: rampa nativa única
  func glide(to factor: CGFloat, seconds: Double = 0.42) {
    lock.lock(); target = nil; let d = device; lock.unlock()
    guard let d else { return }
    let to = clamp(d, factor), from = d.videoZoomFactor
    let stops = abs(log2(Double(to / from)))
    guard stops > 0.003 else { return }
    let spread: Double = 0.6 + 0.4 * min(1.0, stops / 2.0)
    let duration: Double = max(0.2, seconds * spread)
    let rate = Float(max(0.8, stops / duration))
    configure(d) { d.ramp(toVideoZoomFactor: to, withRate: rate) }
  }
  // um passo por quadro capturado (fila da saída de vídeo)
  func frameTick(_ t: Double) {
    lock.lock()
    guard let d = device, let tgt = target else { lock.unlock(); return }
    let dt = lastTick == 0 ? 1.0 / 60 : min(0.05, max(0.004, t - lastTick)); lastTick = t; lastTickWall = CACurrentMediaTime()
    lock.unlock()
    let cur = d.videoZoomFactor
    let diff = log(Double(tgt / cur))
    guard abs(diff) > 0.0006 else { return }
    let next = clamp(d, CGFloat(exp(log(Double(cur)) + diff * (1 - exp(-dt / 0.07)))))
    configure(d) { d.videoZoomFactor = next }
  }
}
