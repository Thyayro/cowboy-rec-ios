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
  // FREIO SEM TREMOR: ao soltar os dedos eles não saem juntos e a distância entre eles muda nos últimos milissegundos — o
  // iOS entrega isso como um vai-e-volta da pinça (pior no zoom IN, dedos afastados). Inversão de direção pequena (< 4%)
  // é ignorada; inversão de verdade (o filmmaker decidiu voltar) passa.
  private var gestureDir: Double = 0
  private var gestureRef: CGFloat = 0

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
    var z = clamp(d, factor)
    if let cur = target, gestureRef > 0 {
      let step = log(Double(z / gestureRef))
      if gestureDir != 0 && step * gestureDir < 0 && abs(step) < 0.04 { z = cur }      // tremor de soltar: segura
      else if abs(step) > 0.004 { gestureDir = step > 0 ? 1 : -1; gestureRef = z }
    } else { gestureRef = z; gestureDir = 0 }
    target = z
    // sem quadro há mais de 120 ms (saída parada): o gesto não pode "travar" — aplica direto
    if CACurrentMediaTime() - lastTickWall > 0.25 { configure(d) { d.videoZoomFactor = z } }
  }
  private var stuck = 0
  private var lastCur: CGFloat = 0
  var onStuck: ((String) -> Void)?
  private var trace: [String] = []
  private var traceUntil = 0.0
  var onTrace: ((String) -> Void)?
  func endFollow() { lock.lock(); gestureDir = 0; gestureRef = 0; traceUntil = lastTick + 1.2; trace = []; lock.unlock() }   // soltou o dedo: o zoom termina de chegar no alvo (amortecido) e para sozinho
  // lente: rampa nativa única
  @discardableResult func glide(to factor: CGFloat, seconds: Double = 0.42) -> Double {
    lock.lock(); target = nil; gestureDir = 0; gestureRef = 0; let d = device; lock.unlock()
    guard let d else { return 0 }
    let to = clamp(d, factor), from = d.videoZoomFactor
    let stops = abs(log2(Double(to / from)))
    guard stops > 0.003 else { return 0 }
    let spread: Double = 0.6 + 0.4 * min(1.0, stops / 2.0)
    let duration: Double = max(0.2, seconds * spread)
    let rate = Float(max(0.8, stops / duration))
    configure(d) { d.ramp(toVideoZoomFactor: to, withRate: rate) }
    return stops / Double(rate)
  }
  // um passo por quadro capturado (fila da saída de vídeo)
  func frameTick(_ t: Double) {
    lock.lock()
    guard let d = device, let tgt = target else { lock.unlock(); return }
    let dt = lastTick == 0 ? 1.0 / 60 : min(0.05, max(0.004, t - lastTick)); lastTick = t; lastTickWall = CACurrentMediaTime()
    lock.unlock()
    let cur = d.videoZoomFactor
    lock.lock()
    if traceUntil > 0 {
      if t < traceUntil { trace.append(String(format: "%.4f", Double(cur))) }
      else { let txt = "alvo \(String(format: "%.4f", Double(tgt))) | " + trace.joined(separator: " "); trace = []; traceUntil = 0; lock.unlock(); onTrace?(txt); lock.lock() }
    }
    lock.unlock()
    let diff = log(Double(tgt / cur))
    guard abs(diff) > 0.0006 else { stuck = 0; lastCur = cur; return }
    // zoom que NÃO anda: alvo longe e o zoom real parado quadro após quadro (ex.: limite digital da ultra travada)
    if abs(diff) > 0.03 && abs(cur - lastCur) < cur * 0.0004 { stuck += 1 } else { stuck = 0 }
    lastCur = cur
    if stuck == 8 {
      stuck = -60   // espera ~1 s antes de avisar de novo
      onStuck?("alvo \(tgt) atual \(cur) min \(d.minAvailableVideoZoomFactor) max \(d.maxAvailableVideoZoomFactor) rampa \(d.isRampingVideoZoom) lente \(d.activePrimaryConstituent?.deviceType.rawValue ?? "-") troca \(d.primaryConstituentDeviceSwitchingBehavior.rawValue)")
    }
    let next = clamp(d, CGFloat(exp(log(Double(cur)) + diff * (1 - exp(-dt / 0.07)))))
    configure(d) { d.videoZoomFactor = next }
  }
}
