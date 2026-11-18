import Foundation

struct NativeCaptureProfile: Hashable, Identifiable, Sendable {
  let width: Int
  let height: Int
  let fps: Double
  var id: String { "\(width)x\(height)@\(fps)" }
  var label: String {
    let resolution = width == 3840 && height == 2160 ? "4K" : width == 1920 && height == 1080 ? "1080p" : width == 1280 && height == 720 ? "720p" : "\(width)×\(height)"
    return "\(resolution) · \(String(format: "%g", fps)) fps"
  }
  var short: String {
    let resolution = width == 3840 ? "4K" : width == 1920 ? "HD" : width == 1280 ? "720" : "\(height)p"
    return "\(resolution) · \(String(format: "%g", fps.rounded()))"
  }
  static let main = NativeCaptureProfile(width: 3840,height: 2160,fps: 60)
}
struct NativeFrameRange: Sendable { let min: Double; let max: Double }
struct NativeFormatDescriptor: Sendable {
  let index: Int
  let width: Int
  let height: Int
  let ranges: [NativeFrameRange]
  let hdr: Bool
  let stabilized: Bool
  var log: Bool = false
  var tenBit: Bool = false
  func supports(_ p: NativeCaptureProfile,hdr requestedHDR: Bool,log requestedLog: Bool = false) -> Bool {
    width == p.width && height == p.height && (!requestedHDR || hdr) && (!requestedLog || log) && ranges.contains { $0.min <= p.fps+0.001 && $0.max >= p.fps-0.001 }
  }
}
enum NativeCapturePolicy {
  static func profiles(_ formats: [NativeFormatDescriptor],hdr: Bool,log: Bool = false) -> [NativeCaptureProfile] {
    var choices=Set<NativeCaptureProfile>()
    for f in formats where (!hdr || f.hdr) && (!log || f.log) {
      for range in f.ranges {
        let common: [Double] = [24,25,30,48,50,60,90,100,120,144,180,200,240]
        for fps in Set(common+[range.min,range.max]) where fps >= range.min-0.001 && fps <= range.max+0.001 && fps >= 1 {
          choices.insert(NativeCaptureProfile(width:f.width,height:f.height,fps:fps))
        }
      }
    }
    return choices.sorted { a,b in a.width*a.height == b.width*b.height ? a.fps < b.fps : a.width*a.height > b.width*b.height }
  }
  // Never trades resolution/fps for stabilization. Among formats that give exactly the profile: the one that supports the
  // strongest stabilization first, then 10-bit only when Log/HDR needs it (8-bit SDR is lighter for the encoder and upload).
  static func select(_ profile: NativeCaptureProfile,hdr: Bool,formats: [NativeFormatDescriptor],log: Bool = false) -> Int? {
    let wantTen = hdr || log
    let score = { (f: NativeFormatDescriptor) -> Int in (f.stabilized ? 2 : 0) + (f.tenBit == wantTen ? 1 : 0) }
    let matches=formats.filter { $0.supports(profile,hdr:hdr,log:log) }
    return matches.sorted { a,b in score(a) == score(b) ? a.index < b.index : score(a) > score(b) }.first?.index
  }
}

struct NativeCaptureMetadata: Codable, Sendable {
  let width: Int
  let height: Int
  let frameRate: Double
  let hdr: Bool
  let codec: String
  let lens: String
  let stabilization: String
  var colorProfile: String? = nil
  var convertRec709: Bool? = nil
  var captureMode: String? = nil
  var settings: [String:Any] { ["width":width,"height":height,"frameRate":frameRate,"hdr":hdr,"codec":codec,"lens":lens,"native_stabilization":stabilization,"capture_mode":captureMode ?? "avfoundation","color_profile":colorProfile ?? (hdr ? "hlg" : "rec709")] }
}

// PRORES (0.13.0): o iPhone 16 Pro grava ProRes (422 HQ / 422 / 422 LT) com Apple Log. Regra da Apple: no armazenamento
// INTERNO vai até 4K30; 4K60 (e acima) só gravando direto num SSD externo pelo USB-C. A conta é por taxa de pixels
// (largura × altura × qps ≤ 4K30), então 1080p60 continua valendo no iPhone. Puro (sem AVFoundation) pra rodar no CI.
enum ProResFlavor: String, CaseIterable, Sendable {
  case hq = "apch", standard = "apcn", lt = "apcs"
  var label: String { switch self { case .hq: return "422 HQ"; case .standard: return "422"; case .lt: return "422 LT" } }
  /// taxa de referência da Apple em 3840×2160 a 29,97 qps (white paper do ProRes)
  var mbps4K30: Double { switch self { case .hq: return 707; case .standard: return 471; case .lt: return 328 } }
}
enum ProResPolicy {
  static let internalPixelRate = 3840.0 * 2160.0 * 30.5
  static func pixelRate(_ p: NativeCaptureProfile) -> Double { Double(p.width * p.height) * p.fps }
  /// Formato que vale de verdade: o escolhido, ou — sem SSD — o mais rápido do MESMO tamanho que cabe no limite interno.
  static func cap(_ p: NativeCaptureProfile, external: Bool, options: [NativeCaptureProfile]) -> NativeCaptureProfile {
    guard !external, pixelRate(p) > internalPixelRate else { return p }
    let fits = options.filter { pixelRate($0) <= internalPixelRate }
    if let same = fits.filter({ $0.width == p.width && $0.height == p.height }).max(by: { $0.fps < $1.fps }) { return same }
    return fits.max { a, b in a.width * a.height == b.width * b.height ? a.fps < b.fps : a.width * a.height < b.width * b.height } ?? p
  }
  static func mbps(_ f: ProResFlavor, _ p: NativeCaptureProfile) -> Double { f.mbps4K30 * pixelRate(p) / (3840.0 * 2160.0 * 29.97) }
  /// gigabytes por minuto de gravação (vídeo; o áudio PCM soma ~17 MB/min)
  static func gbPerMinute(_ f: ProResFlavor, _ p: NativeCaptureProfile) -> Double { mbps(f, p) * 60 / 8 / 1000 }
  /// proxy que sobe ao vivo enquanto o mestre ProRes grava no aparelho: 1080p HEVC Log (decisão do operador 17/11)
  static func proxySize(width: Int, height: Int) -> (Int, Int) {
    let long = 1920, short = max(2, Int((Double(long) * Double(min(width, height)) / Double(max(1, max(width, height))) / 2).rounded()) * 2)
    return width >= height ? (long, short) : (short, long)
  }
  static func proxyBitrate(fps: Double) -> Int { fps > 31 ? 24_000_000 : 20_000_000 }
}
