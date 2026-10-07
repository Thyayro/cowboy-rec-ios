import AVFoundation
import QuartzCore
import UIKit

// ZOOM COMO O DA CÂMERA DO IPHONE: um controlador preso ao relógio da tela (60–120 Hz) ajusta o zoom A CADA QUADRO.
// - pinça/roda: segue o dedo com amortecimento crítico em escala logarítmica (velocidade constante entre 0,5×, 1× e 5×);
// - toque numa lente: curva suave (acelera e freia) de ~0,45 s.
// Antes cada movimento do dedo reiniciava um `ramp` do AVFoundation — cada recomeço era um degrau ("tremendo escala").
final class ZoomDriver: NSObject {
  weak var device: AVCaptureDevice?
  private var link: CADisplayLink?
  private var target: CGFloat = 1
  private var path: (from: CGFloat, to: CGFloat, t0: CFTimeInterval, dur: Double)?
  private var last: CFTimeInterval = 0
  var onChange: ((CGFloat) -> Void)?

  func attach(_ d: AVCaptureDevice) {
    device = d; target = d.videoZoomFactor; path = nil
  }
  private func clamp(_ z: CGFloat) -> CGFloat {
    guard let d = device else { return z }
    return max(d.minAvailableVideoZoomFactor, min(d.maxAvailableVideoZoomFactor, z))
  }
  // segue (gesto): o alvo muda continuamente e o zoom acompanha amortecido
  func follow(_ factor: CGFloat) { path = nil; target = clamp(factor); start() }
  // vai até (lente): curva com aceleração e freio
  func glide(to factor: CGFloat, seconds: Double = 0.45) {
    guard let d = device else { return }
    let to = clamp(factor), from = d.videoZoomFactor
    guard abs(log(Double(to / from))) > 0.002 else { return }
    let dur = max(0.18, min(0.7, seconds * (0.55 + 0.45 * min(1, abs(log2(Double(to / from))) / 2))))
    path = (from, to, CACurrentMediaTime(), dur); target = to; start()
  }
  private func start() {
    if link == nil {
      let l = CADisplayLink(target: self, selector: #selector(tick(_:)))
      l.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
      l.add(to: .main, forMode: .common); link = l; last = CACurrentMediaTime()
    }
  }
  func stop() { link?.invalidate(); link = nil; path = nil }
  @objc private func tick(_ l: CADisplayLink) {
    guard let d = device else { stop(); return }
    let now = CACurrentMediaTime(), dt = min(0.05, max(0.001, now - last)); last = now
    let current = d.videoZoomFactor
    var next: CGFloat
    if let p = path {
      let k = min(1, (now - p.t0) / p.dur)
      let e = k < 0.5 ? 4 * k * k * k : 1 - pow(-2 * k + 2, 3) / 2   // easeInOutCubic
      next = CGFloat(exp(log(Double(p.from)) + (log(Double(p.to)) - log(Double(p.from))) * e))
      if k >= 1 { path = nil }
    } else {
      let diff = log(Double(target / current))
      if abs(diff) < 0.0008 { stop(); return }
      next = CGFloat(exp(log(Double(current)) + diff * (1 - exp(-dt / 0.075))))
    }
    next = clamp(next)
    guard abs(next - current) > 0.00005 else { if path == nil { stop() }; return }
    _ = CowboyObjC.catching {
      if (try? d.lockForConfiguration()) != nil {
        if d.isRampingVideoZoom { d.cancelVideoZoomRamp() }
        d.videoZoomFactor = next
        d.unlockForConfiguration()
      }
    }
    onChange?(next)
  }
}
