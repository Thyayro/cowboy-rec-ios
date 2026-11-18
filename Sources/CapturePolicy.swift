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

// PRORES LOG EXTRA (0.13.0, pedido do operador 17/11): chave em Ajustes, LIGADA por padrão, que grava um mestre ProRes
// JUNTO da gravação de sempre (não muda formato, codec, Rec.709, taxa nem o envio ao vivo). Sem SSD no celular: o mestre
// sai em pedaços de 2 s — em casa direto pro PC pelo Wi-Fi (422 LT), fora pra VPS (422 HQ, o máximo) — e cada pedaço só
// sai do iPhone com recibo. Puro (sem AVFoundation) pra rodar no CI.
enum ProResFlavor: String, CaseIterable, Sendable {
  case hq = "apch", standard = "apcn", lt = "apcs"
  var label: String { switch self { case .hq: return "422 HQ"; case .standard: return "422"; case .lt: return "422 LT" } }
  /// taxa de referência da Apple em 3840×2160 a 29,97 qps (white paper do ProRes)
  var mbps4K30: Double { switch self { case .hq: return 707; case .standard: return 471; case .lt: return 328 } }
}
enum ProResPolicy {
  /// mestre ProRes até 30 qps (regra da Apple sem SSD): gravando a 60, entra um quadro sim, um não. Devolve o passo.
  static func step(fps: Double) -> Int { fps > 30.5 ? max(1, Int((fps / 30).rounded())) : 1 }
  static func masterFPS(_ fps: Double) -> Double { fps / Double(step(fps: fps)) }
  static func mbps(_ f: ProResFlavor, width: Int, height: Int, fps: Double) -> Double {
    f.mbps4K30 * Double(width * height) * masterFPS(fps) / (3840.0 * 2160.0 * 29.97)
  }
  static func gbPerMinute(_ f: ProResFlavor, width: Int, height: Int, fps: Double) -> Double { mbps(f, width: width, height: height, fps: fps) * 60 / 8 / 1000 }
  static let segmentSeconds = 2.0
  /// livre mínimo no iPhone pra continuar o ProRes (abaixo disso o mestre para e a gravação de sempre segue)
  static let minFreeBytes: Int64 = 3_000_000_000
}
