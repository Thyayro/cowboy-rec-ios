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
