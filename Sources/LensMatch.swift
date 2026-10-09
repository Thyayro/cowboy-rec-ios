import AVFoundation
import Foundation
import QuartzCore
import simd

// IGUALAR CÂMERAS — cada lente (ultra f/2.2, principal f/1.78, tele f/2.8) tem sensor, abertura e cor próprios, e na troca a
// lente nova ainda CONVERGE a exposição/balanço por ~1 s (medido 07/10: a mesma troca deu escala 1,17 e 1,36). Duas camadas:
//  1) TRANSIÇÃO (anti-salto): no quadro da troca, a lente nova é corrigida pra ficar IGUAL ao último quadro da anterior
//     (cor, luz p25/p75, média) e essa correção solta suavemente em 1,2 s — a troca não dá degrau, a exposição se acomoda;
//  2) FIXA (aprendida): a diferença que SOBRA com a lente já convergida (medida 1,0–1,6 s depois, câmera parada) vira a
//     correção permanente da lente em relação à principal (referência), guardada por aparelho.
// Aplicadas depois do LUT, na tela e no arquivo Rec.709 (o quadro atrasado do arquivo procura pelo próprio horário).
struct LensCorrection: Codable, Equatable {
  var gain: SIMD3<Float> = SIMD3(1, 1, 1)
  var gamma: Float = 1
  var scale: Float = 1
  var samples = 0
  static let identity = LensCorrection()
  var isIdentity: Bool { abs(gamma - 1) < 0.002 && abs(scale - 1) < 0.002 && abs(gain.x - 1) < 0.002 && abs(gain.y - 1) < 0.002 && abs(gain.z - 1) < 0.002 }
  // b(self(x))
  func then(_ b: LensCorrection) -> LensCorrection {
    LensCorrection(gain: gain * b.gain, gamma: gamma * b.gamma, scale: b.scale * pow(scale, b.gamma), samples: samples)
  }
  func mix(_ k: Float) -> LensCorrection {   // k=1 -> self, k=0 -> identidade
    LensCorrection(gain: SIMD3<Float>(1, 1, 1) + (gain - SIMD3<Float>(1, 1, 1)) * k, gamma: 1 + (gamma - 1) * k, scale: 1 + (scale - 1) * k, samples: samples)
  }
  func apply(_ s: FrameStats) -> FrameStats {
    func f(_ v: Float) -> Float { scale * pow(max(v, 0.0005), gamma) }
    let m = SIMD3<Float>(f(s.mean.x), f(s.mean.y), f(s.mean.z)) * gain
    return FrameStats(mean: m, p25: f(s.p25), p75: f(s.p75))
  }
  // correção que leva a imagem "b" a ficar igual à "a" (mesma cena)
  static func fit(from b: FrameStats, to a: FrameStats) -> LensCorrection? {
    guard a.p75 > 0.06, b.p75 > 0.06, a.p75 < 0.97, b.p75 < 0.97 else { return nil }
    var gamma: Float = 1
    if a.p25 > 0.02, b.p25 > 0.02, b.p75 / b.p25 > 1.2, a.p75 / a.p25 > 1.2 { gamma = log(a.p75 / a.p25) / log(b.p75 / b.p25) }
    gamma = max(0.85, min(1.18, gamma))
    let scale = max(0.75, min(1.33, a.p75 / pow(b.p75, gamma)))
    let bm = SIMD3<Float>(scale * pow(max(b.mean.x, 0.001), gamma), scale * pow(max(b.mean.y, 0.001), gamma), scale * pow(max(b.mean.z, 0.001), gamma))
    let w = SIMD3<Float>(0.2126, 0.7152, 0.0722)
    let la = max(0.001, (a.mean * w).sum()), lb = max(0.001, (bm * w).sum())
    var gain = (a.mean / la) / (bm / lb)
    gain = SIMD3<Float>(max(0.88, min(1.12, gain.x)), max(0.88, min(1.12, gain.y)), max(0.88, min(1.12, gain.z)))
    return LensCorrection(gain: gain, gamma: gamma, scale: scale, samples: 1)
  }
}
struct FrameStats { let mean: SIMD3<Float>; let p25: Float; let p75: Float }

final class LensMatch: @unchecked Sendable {
  static let reference = "wide"
  static let fade = 1.2
  private let lock = NSLock()
  private var history: [(Double, String)] = []
  private var table: [String: LensCorrection] = [:]
  private var last: (lens: String, t: Double, s: FrameStats)?
  private var transitions: [(t0: Double, lens: String, c: LensCorrection)] = []
  private var pendingLearn: (lens: String, t0: Double, before: FrameStats, beforeLens: String)?
  private var still = true
  private(set) var enabled = UserDefaults.standard.object(forKey: "lensMatch") as? Bool ?? true
  private let key: String
  var onLearn: ((String, LensCorrection) -> Void)?
  var motion: (() -> Double)?   // giro do aparelho (rad/s) — aprender a fixa só parado

  init(deviceKey: String) {
    key = "lensMatch2_" + deviceKey
    if let d = UserDefaults.standard.data(forKey: key), let t = try? JSONDecoder().decode([String: LensCorrection].self, from: d) { table = t }
  }
  static func name(_ t: AVCaptureDevice.DeviceType?) -> String {
    switch t { case .builtInUltraWideCamera?: return "ultra"; case .builtInTelephotoCamera?: return "tele"; default: return "wide" }
  }
  func setEnabled(_ v: Bool) { lock.lock(); enabled = v; lock.unlock(); UserDefaults.standard.set(v, forKey: "lensMatch") }
  func reset() { lock.lock(); table = [:]; transitions = []; lock.unlock(); UserDefaults.standard.removeObject(forKey: key) }
  func status() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return table.mapValues { $0.samples } }
  func lensChanged(_ lens: String, at t: Double = CACurrentMediaTime()) {
    lock.lock(); history.append((t, lens)); if history.count > 300 { history.removeFirst(history.count - 300) }; lock.unlock()
  }
  private func lensLocked(at t: Double) -> String {
    var l = history.first?.1 ?? Self.reference
    for e in history { if e.0 <= t { l = e.1 } else { break } }
    return l
  }
  func lens(at t: Double) -> String { lock.lock(); defer { lock.unlock() }; return lensLocked(at: t) }
  private func staticLocked(_ l: String) -> LensCorrection { l == Self.reference ? .identity : (table[l] ?? .identity) }

  // correção do quadro captado em t: fixa da lente + transição da última troca (se ainda soltando). lens = a lente que o
  // PRÓPRIO quadro diz que o fez (0.8.1); sem ela, a do horário (aviso do iOS, que pode errar 1–3 quadros na troca)
  func correction(at t: Double, lens: String? = nil) -> LensCorrection {
    lock.lock(); defer { lock.unlock() }
    guard enabled else { return .identity }
    let l = lens ?? lensLocked(at: t)
    var c = staticLocked(l)
    if let tr = transitions.last(where: { $0.t0 <= t }), tr.lens == l, t - tr.t0 < Self.fade {
      let k = Float(1 - (t - tr.t0) / Self.fade)
      c = c.then(tr.c.mix(k * k * (3 - 2 * k)))   // solta com curva suave (smoothstep)
    }
    return c
  }

  // TROCA NO QUADRO EXATO (0.8.1): o último quadro da lente velha e o 1º da nova (sensor de cada quadro) — a nova fica
  // igual à velha desde o 1º quadro e solta em 1,2 s. Antes a troca era vista na amostra de 10×/s: a correção entrava
  // até 6 quadros depois (cor crua da lente nova, depois "voltava" pra da velha = piscada).
  func switched(at t: Double, from: String, before: FrameStats, to: String, after: FrameStats) {
    let rot = motion?() ?? 0
    lock.lock()
    let b = staticLocked(from).apply(before), a = staticLocked(to).apply(after)
    if let c = LensCorrection.fit(from: a, to: b) { transitions.append((t, to, c)); if transitions.count > 20 { transitions.removeFirst() } }
    pendingLearn = (to, t, before, from); still = rot < 0.35
    lock.unlock()
  }

  // amostra do quadro em tempo real (30×/s): detecta a troca, monta a transição e aprende a fixa
  func observe(_ s: FrameStats, at t: Double) {
    let rot = motion?() ?? 0
    lock.lock()
    let l = lensLocked(at: t)
    if rot > 0.35 { still = false }
    if let p = last, p.lens != l, t - p.t < 0.2, !transitions.contains(where: { $0.lens == l && abs($0.t0 - t) < 0.35 }) {
      // TROCA: a lente nova (com a fixa) fica igual ao último quadro da anterior (com a fixa dela) e solta em 1,2 s
      let before = staticLocked(p.lens).apply(p.s), after = staticLocked(l).apply(s)
      if let c = LensCorrection.fit(from: after, to: before) {
        transitions.append((t, l, c)); if transitions.count > 20 { transitions.removeFirst() }
      }
      pendingLearn = (l, t, p.s, p.lens); still = rot < 0.35
    }
    // FIXA: 1,0–1,6 s depois da troca, lente convergida, câmera parada -> o que ainda difere é da lente
    var learned: (String, LensCorrection, [String: LensCorrection])?
    if let pl = pendingLearn, l == pl.lens, t - pl.t0 > 1.0 {
      if t - pl.t0 < 1.6 && still {
        let want = staticLocked(pl.beforeLens).apply(pl.before)   // como a lente anterior aparecia (já igualada)
        let learnLens = pl.lens != Self.reference ? pl.lens : pl.beforeLens
        // lente nova não-principal: corrige ela pra ficar como a anterior; voltando pra principal: corrige a que saiu
        let rel = pl.lens != Self.reference ? LensCorrection.fit(from: s, to: want) : LensCorrection.fit(from: pl.before, to: s)
        if learnLens != Self.reference, let rel {
          var cur = table[learnLens] ?? .identity
          let k: Float = cur.samples == 0 ? 0.6 : 0.25
          cur.gain = cur.gain + (rel.gain - cur.gain) * k
          cur.gamma = cur.gamma + (rel.gamma - cur.gamma) * k
          cur.scale = cur.scale + (rel.scale - cur.scale) * k
          cur.samples += 1
          table[learnLens] = cur; learned = (learnLens, cur, table)
        }
      }
      pendingLearn = nil
    }
    last = (l, t, s)
    lock.unlock()
    if let learned {
      if let d = try? JSONEncoder().encode(learned.2) { UserDefaults.standard.set(d, forKey: key) }
      onLearn?(learned.0, learned.1)
    }
  }
}
