import CoreMotion
import Foundation
import simd

// Gyroscope/attitude for the level, the 3D floor and the Gyroflow log (.gcsv) of every take.
final class MotionHub: @unchecked Sendable {
  static let shared = MotionHub()
  struct Snapshot {
    let deviceToWorld: simd_quatd   // world: z up (gravity), x arbitrary horizontal
    let gravity: SIMD3<Double>      // device axes, in g
  }
  private let manager = CMMotionManager()
  private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .userInitiated; return q }()
  private let lock = NSLock()
  private var latest: CMDeviceMotion?
  private var flipped: Bool?
  private var log: GyroLog?

  func start() {
    lock.lock(); defer { lock.unlock() }
    guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
    manager.deviceMotionUpdateInterval = 1.0 / 100
    manager.startDeviceMotionUpdates(using: .xArbitraryCorrectedZVertical, to: queue) { [weak self] motion, _ in
      guard let self, let motion else { return }
      self.lock.lock(); self.latest = motion; let log = self.log; self.lock.unlock()
      log?.write(motion)
    }
  }
  // velocidade de giro do aparelho agora (rad/s)
  func rotationSpeed() -> Double {
    lock.lock(); let m = latest; lock.unlock()
    guard let r = m?.rotationRate else { return 0 }
    return (r.x * r.x + r.y * r.y + r.z * r.z).squareRoot()
  }
  func stop() { lock.lock(); manager.stopDeviceMotionUpdates(); latest = nil; lock.unlock() }
  func attach(_ log: GyroLog?) { lock.lock(); self.log = log; lock.unlock() }

  func snapshot() -> Snapshot? {
    lock.lock(); let motion = latest; lock.unlock()
    guard let motion else { return nil }
    let a = motion.attitude.quaternion
    let q = simd_quatd(ix: a.x, iy: a.y, iz: a.z, r: a.w)
    let g = SIMD3(motion.gravity.x, motion.gravity.y, motion.gravity.z)
    // Resolve CoreMotion's quaternion direction once from gravity: world "up" seen from the device must be -gravity.
    if flipped == nil, simd_length(g) > 0.5 {
      let target = -simd_normalize(g)
      let a1 = simd_dot(q.inverse.act(SIMD3(0, 0, 1)), target), a2 = simd_dot(q.act(SIMD3(0, 0, 1)), target)
      if abs(a1 - a2) > 0.2 { flipped = a2 > a1 }
    }
    return Snapshot(deviceToWorld: flipped == true ? q.inverse : q, gravity: g)
  }
}

// Gyroflow IMU log, written to disk while recording and uploaded with the take (kind gcsv).
final class GyroLog: @unchecked Sendable {
  let url: URL
  private let handle: FileHandle?
  private let lock = NSLock()
  private var t0: Double?
  private var buffer = ""
  private(set) var lines = 0
  init(url: URL, lens: String) {
    self.url = url
    let head = ["GYROFLOW IMU LOG", "version,1.3", "id,cowboy_ios_native", "orientation,XYZ",
      "note,CoreMotion rotationRate (rad/s) e aceleracao com gravidade (g); eixos do iPhone (x direita, y topo, z pra fora da tela); t a partir do 1o quadro do video",
      "vendor,cowboy", "lens_info,\(lens)", "tscale,0.001", "gscale,1", "ascale,1", "t,gx,gy,gz,ax,ay,az"].joined(separator: "\n") + "\n"
    FileManager.default.createFile(atPath: url.path, contents: head.data(using: .utf8))
    handle = try? FileHandle(forWritingTo: url)
    _ = try? handle?.seekToEnd()
  }
  func begin(at seconds: Double) { lock.lock(); t0 = seconds; lock.unlock() }
  func write(_ m: CMDeviceMotion) {
    lock.lock(); defer { lock.unlock() }
    guard let t0 else { return }
    let t = (m.timestamp - t0) * 1000
    guard t >= 0 else { return }
    let r = m.rotationRate, u = m.userAcceleration, g = m.gravity
    buffer += String(format: "%.2f,%.5f,%.5f,%.5f,%.4f,%.4f,%.4f\n", t, r.x, r.y, r.z, -(u.x + g.x), -(u.y + g.y), -(u.z + g.z))
    lines += 1
    if buffer.utf8.count > 32768 { flushLocked() }
  }
  private func flushLocked() { if let data = buffer.data(using: .utf8) { try? handle?.write(contentsOf: data) }; buffer = "" }
  func close() { lock.lock(); flushLocked(); try? handle?.close(); lock.unlock() }
}
