import AVFoundation
import Foundation
import QuartzCore

// IGUALAR CÂMERAS: cada lente do iPhone (ultra-angular f/2.2, principal f/1.78, tele f/2.8) tem sensor, abertura e cor próprios —
// na troca de lente a luz, a sombra e a cor "pulam". No instante da troca as duas lentes mostram o MESMO enquadramento (a
// câmera virtual troca exatamente no ponto em que os campos de visão casam), então dá pra medir a diferença de verdade:
// pico de sombra (p20), de luz (p80) e a média de cor de cada lado da troca -> correção da lente nova em relação à anterior,
// encadeada até a PRINCIPAL (1×, referência). Aprende sozinho a cada troca (média móvel) e guarda por aparelho.
// A correção (ganho de cor + curva de luz/sombra) é aplicada depois do LUT: na tela e no arquivo Rec.709 + look.
struct LensCorrection: Codable, Equatable {
  var gain: SIMD3<Float> = SIMD3(1, 1, 1)
  var gamma: Float = 1
  var scale: Float = 1
  var samples = 0
  static let identity = LensCorrection()
  var isIdentity: Bool { abs(gamma - 1) < 0.002 && abs(scale - 1) < 0.002 && abs(gain.x - 1) < 0.002 && abs(gain.y - 1) < 0.002 && abs(gain.z - 1) < 0.002 }
  // aplica b depois de self: b(self(x))
  func then(_ b: LensCorrection) -> LensCorrection {
    LensCorrection(gain: gain * b.gain, gamma: gamma * b.gamma, scale: b.scale * pow(scale, b.gamma), samples: 0)
  }
}
struct FrameStats { let mean: SIMD3<Float>; let p20: Float; let p80: Float }

final class LensMatch: @unchecked Sendable {
  static let reference = "wide"
  private let lock = NSLock()
  private var history: [(Double, String)] = []
  private var table: [String: LensCorrection] = [:]
  private var lastSample: (lens: String, t: Double, s: FrameStats)?
  private(set) var enabled = UserDefaults.standard.object(forKey: "lensMatch") as? Bool ?? true
  private let key: String
  var onLearn: ((String, LensCorrection) -> Void)?

  init(deviceKey: String) {
    key = "lensMatch_" + deviceKey
    if let d = UserDefaults.standard.data(forKey: key), let t = try? JSONDecoder().decode([String: LensCorrection].self, from: d) { table = t }
  }
  static func name(_ t: AVCaptureDevice.DeviceType?) -> String {
    switch t { case .builtInUltraWideCamera?: return "ultra"; case .builtInTelephotoCamera?: return "tele"; default: return "wide" }
  }
  func setEnabled(_ v: Bool) { lock.lock(); enabled = v; lock.unlock(); UserDefaults.standard.set(v, forKey: "lensMatch") }
  func reset() { lock.lock(); table = [:]; lock.unlock(); UserDefaults.standard.removeObject(forKey: key) }
  func status() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return table.mapValues { $0.samples } }
  func lensChanged(_ lens: String, at t: Double = CACurrentMediaTime()) {
    lock.lock(); history.append((t, lens)); if history.count > 200 { history.removeFirst(history.count - 200) }; lock.unlock()
  }
  func lens(at t: Double) -> String {
    lock.lock(); defer { lock.unlock() }
    var l = history.first?.1 ?? Self.reference
    for e in history { if e.0 <= t { l = e.1 } else { break } }
    return l
  }
  // correção do quadro captado no instante t (vale pro quadro atrasado do arquivo também)
  func correction(at t: Double) -> LensCorrection {
    let l = lens(at: t)
    lock.lock(); defer { lock.unlock() }
    guard enabled, l != Self.reference else { return .identity }
    return table[l] ?? .identity
  }
  // amostra de cor/luz de um quadro (tempo real) — na troca de lente vira aprendizado
  func observe(_ s: FrameStats, at t: Double) {
    let l = lens(at: t)
    lock.lock()
    let prev = lastSample; lastSample = (l, t, s)
    guard let prev, prev.lens != l, t - prev.t < 0.35, s.p80 > 0.08, prev.s.p80 > 0.08, s.p80 < 0.98, prev.s.p80 < 0.98 else { lock.unlock(); return }
    // qual lente aprende: a que NÃO é a principal; "a" = lado de referência, "b" = lado da lente que aprende
    let learn: String, a: FrameStats, b: FrameStats, chain: LensCorrection?
    if l != Self.reference { learn = l; a = prev.s; b = s; chain = prev.lens == Self.reference ? LensCorrection.identity : table[prev.lens] }
    else { learn = prev.lens; a = s; b = prev.s; chain = LensCorrection.identity }
    guard let chain else { lock.unlock(); return }
    var gamma = Float(1)
    if a.p20 > 0.02, b.p20 > 0.02, b.p80 / b.p20 > 1.15 { gamma = log(a.p80 / a.p20) / log(b.p80 / b.p20) }
    gamma = max(0.8, min(1.25, gamma))
    let scale = max(0.7, min(1.4, a.p80 / pow(b.p80, gamma)))
    let bm = SIMD3<Float>(scale * pow(max(b.mean.x, 0.001), gamma), scale * pow(max(b.mean.y, 0.001), gamma), scale * pow(max(b.mean.z, 0.001), gamma))
    let w = SIMD3<Float>(0.2126, 0.7152, 0.0722)
    let la = max(0.001, (a.mean * w).sum()), lb = max(0.001, (bm * w).sum())
    var gain = (a.mean / la) / (bm / lb)
    gain = SIMD3(max(0.85, min(1.15, gain.x)), max(0.85, min(1.15, gain.y)), max(0.85, min(1.15, gain.z)))
    let measured = LensCorrection(gain: gain, gamma: gamma, scale: scale, samples: 1).then(chain)
    var cur = table[learn] ?? .identity
    let k: Float = cur.samples == 0 ? 1 : 0.3
    cur.gain = cur.gain + (measured.gain - cur.gain) * k
    cur.gamma = cur.gamma + (measured.gamma - cur.gamma) * k
    cur.scale = cur.scale + (measured.scale - cur.scale) * k
    cur.samples += 1
    table[learn] = cur
    let snapshot = table
    lock.unlock()
    if let d = try? JSONEncoder().encode(snapshot) { UserDefaults.standard.set(d, forKey: key) }
    onLearn?(learn, cur)
  }
}
