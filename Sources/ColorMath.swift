import Foundation

// Same math as the VPS (server/colorluts.js) and the web looks (public/js/rec/look.js): the preview on the phone,
// the thumbnail and the Rec.709 copy made in the cloud all agree.
struct LookPreset: Identifiable, Hashable, Sendable {
  let id: String
  let label: String
  let p: [String: Double]
  var neutral: Bool { p.values.allSatisfy { $0 == 0 } }
  static let all: [LookPreset] = [
    LookPreset(id: "natural", label: "Natural", p: [:]),
    LookPreset(id: "cowboy", label: "Cowboy", p: ["temp": 0.35, "contrast": 0.15, "saturation": 0.08, "teal": 0.25, "shadows": 0.08]),
    LookPreset(id: "cinema", label: "Cinema", p: ["contrast": 0.22, "saturation": -0.12, "teal": 0.6, "fade": 0.18, "highlights": -0.2]),
    LookPreset(id: "vivo", label: "Vivo", p: ["vibrance": 0.5, "contrast": 0.1, "saturation": 0.08]),
    LookPreset(id: "suave", label: "Suave", p: ["contrast": -0.12, "fade": 0.35, "saturation": -0.15, "temp": 0.1, "shadows": 0.12]),
    LookPreset(id: "noite", label: "Noite", p: ["exposure": 0.35, "shadows": 0.25, "highlights": -0.25, "temp": -0.15, "contrast": 0.05]),
    LookPreset(id: "pb", label: "P&B", p: ["bw": 1, "contrast": 0.25]),
  ]
  static func named(_ id: String) -> LookPreset { all.first { $0.id == id } ?? all[0] }
}

enum SourceColor: String, Sendable { case sdr, hlg, appleLog }

enum ColorMath {
  // Apple Log Profile White Paper (09/2023)
  static let logR0 = -0.05641088, logRt = 0.01, logC = 47.28711236, logB = 0.00964052, logG = 0.08550479, logD = 0.69336945
  static let logPt = logC * (logRt - logR0) * (logRt - logR0)
  static func appleLogDecode(_ v: Double) -> Double {
    if v < 0 { return logR0 }
    if v < logPt { return (v / logC).squareRoot() + logR0 }
    return pow(2, (v - logD) / logG) - logB
  }
  // Rec.2020 linear -> Rec.709 linear (D65)
  static let m2020to709: [[Double]] = [[1.6605, -0.5876, -0.0728], [-0.1246, 1.1329, -0.0083], [-0.0182, -0.1006, 1.1187]]
  static func tone(_ x: Double) -> Double { max(0, (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14)) }
  private static func to709(_ linear: SIMD3<Double>, exposure: Double) -> SIMD3<Double> {
    let l = [linear.x, linear.y, linear.z]
    let o = m2020to709.map { row in row[0] * l[0] + row[1] * l[1] + row[2] * l[2] }
    let e = o.map { min(1, pow(min(1, tone(max(0, $0) * exposure)), 1 / 2.4)) }
    return SIMD3(e[0], e[1], e[2])
  }
  static func appleLogTo709(_ c: SIMD3<Double>) -> SIMD3<Double> {
    to709(SIMD3(appleLogDecode(c.x), appleLogDecode(c.y), appleLogDecode(c.z)), exposure: 0.6)
  }
  static func hlgDecode(_ v: Double) -> Double {
    let a = 0.17883277, b = 0.28466892, c = 0.55991073
    return v <= 0.5 ? v * v / 3 : (exp((v - c) / a) + b) / 12
  }
  static func hlgTo709(_ c: SIMD3<Double>) -> SIMD3<Double> { to709(SIMD3(hlgDecode(c.x), hlgDecode(c.y), hlgDecode(c.z)), exposure: 2.6) }

  static func grade(_ input: SIMD3<Double>, _ p: [String: Double]) -> SIMD3<Double> {
    func v(_ k: String) -> Double { p[k] ?? 0 }
    func s2l(_ x: Double) -> Double { x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
    func l2s(_ x: Double) -> Double { x <= 0.0031308 ? x * 12.92 : 1.055 * pow(x, 1 / 2.4) - 0.055 }
    func cl(_ x: Double) -> Double { min(1, max(0, x)) }
    var r = s2l(input.x), g = s2l(input.y), b = s2l(input.z)
    let e = pow(2, v("exposure")); r *= e; g *= e; b *= e
    r *= 1 + 0.12 * v("temp"); b *= 1 - 0.12 * v("temp"); g *= 1 - 0.08 * v("tint")
    r = l2s(cl(r)); g = l2s(cl(g)); b = l2s(cl(b))
    let co = v("contrast")
    r = (r - 0.5) * (1 + co) + 0.5; g = (g - 0.5) * (1 + co) + 0.5; b = (b - 0.5) * (1 + co) + 0.5
    var l = cl(0.2126 * r + 0.7152 * g + 0.0722 * b)
    let sh = v("shadows") * 0.25 * (1 - l) * (1 - l), hi = v("highlights") * 0.25 * l * l
    r += sh + hi; g += sh + hi; b += sh + hi
    l = 0.2126 * r + 0.7152 * g + 0.0722 * b
    let sat = cl(max(r, g, b) - min(r, g, b))
    let k = (1 + v("saturation")) * (1 + v("vibrance") * (1 - sat))
    r = l + (r - l) * k; g = l + (g - l) * k; b = l + (b - l) * k
    let t = v("teal")
    r += t * (-0.06 * (1 - l) + 0.08 * l); g += t * (0.03 * (1 - l) + 0.02 * l); b += t * (0.07 * (1 - l) - 0.06 * l)
    let fa = v("fade")
    r = r * (1 - fa * 0.15) + fa * 0.07; g = g * (1 - fa * 0.15) + fa * 0.07; b = b * (1 - fa * 0.15) + fa * 0.07
    let bw = v("bw")
    if bw != 0 { let y = 0.2126 * r + 0.7152 * g + 0.0722 * b; r += (y - r) * bw; g += (y - g) * bw; b += (y - b) * bw }
    return SIMD3(cl(r), cl(g), cl(b))
  }

  // Preview transform: source code values -> Rec.709 display (LUT "puxando do Log") -> look.
  static func previewTransform(source: SourceColor, rawLog: Bool, look: LookPreset) -> ((SIMD3<Double>) -> SIMD3<Double>)? {
    let convert: ((SIMD3<Double>) -> SIMD3<Double>)?
    switch source {
    case .appleLog: convert = rawLog ? nil : appleLogTo709
    case .hlg: convert = rawLog ? nil : hlgTo709
    case .sdr: convert = nil
    }
    if look.neutral { return convert }
    if let convert { return { grade(convert($0), look.p) } }
    return { grade($0, look.p) }
  }
  // RGBA Float32, red varies fastest (CIColorCube and .cube share this order).
  static func cubeFloats(size: Int = 33, _ fn: (SIMD3<Double>) -> SIMD3<Double>) -> [Float] {
    var out = [Float](); out.reserveCapacity(size * size * size * 4)
    let n = Double(size - 1)
    for bi in 0..<size { for gi in 0..<size { for ri in 0..<size {
      let o = fn(SIMD3(Double(ri) / n, Double(gi) / n, Double(bi) / n))
      out.append(Float(o.x)); out.append(Float(o.y)); out.append(Float(o.z)); out.append(1)
    } } }
    return out
  }
  static func cubeText(title: String, size: Int = 33, _ fn: (SIMD3<Double>) -> SIMD3<Double>) -> String {
    var lines = ["TITLE \"\(title)\"", "LUT_3D_SIZE \(size)", "DOMAIN_MIN 0 0 0", "DOMAIN_MAX 1 1 1"]
    let n = Double(size - 1)
    for bi in 0..<size { for gi in 0..<size { for ri in 0..<size {
      let o = fn(SIMD3(Double(ri) / n, Double(gi) / n, Double(bi) / n))
      lines.append(String(format: "%.6f %.6f %.6f", o.x, o.y, o.z))
    } } }
    return lines.joined(separator: "\n") + "\n"
  }
}

// Zoom on the virtual (0,5×–5×) camera. Display scale: 1× = main lens; the device factor = display × base.
enum ZoomMath {
  static func presets(base: Double, switchOvers: [Double], minDisplay: Double, maxDisplay: Double) -> [Double] {
    var values: [Double] = [0.5, 1, 2]
    for s in switchOvers.dropFirst() { values.append((s / base * 10).rounded() / 10) }
    let unique = Array(Set(values)).sorted()
    return unique.filter { $0 >= minDisplay - 0.01 && $0 <= maxDisplay + 0.01 }
  }
  // AVCaptureDevice.ramp rate is in powers of two per second: constant perceived speed across lens switch-overs.
  static func rampRate(from: Double, to: Double, seconds: Double) -> Double {
    guard from > 0, to > 0 else { return 4 }
    return max(0.6, abs(log2(to / from)) / max(0.05, seconds))
  }
  static func label(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    let text = rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
    return text.replacingOccurrences(of: ".", with: ",") + "×"
  }
}

// Aspect crop used by the framing guide (same as the web cropRect).
enum Framing {
  static let options: [(id: String, label: String, ratio: Double)] = [("9:16", "9:16", 9.0 / 16), ("4:5", "4:5", 0.8), ("1:1", "1:1", 1), ("16:9", "16:9", 16.0 / 9), ("cine", "2,39", 2.39), ("livre", "Livre", 0)]
  static func ratio(_ id: String) -> Double { options.first { $0.id == id }?.ratio ?? 0 }
  static func crop(width: Double, height: Double, ratio: Double) -> (x: Double, y: Double, w: Double, h: Double) {
    guard ratio > 0 else { return (0, 0, width, height) }
    var w = width, h = width / ratio
    if h > height { h = height; w = height * ratio }
    return ((width - w) / 2, (height - h) / 2, w, h)
  }
}
