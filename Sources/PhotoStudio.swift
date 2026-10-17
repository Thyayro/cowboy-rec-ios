import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// REVELAÇÃO DA FOTO (0.11.0): ajustes "Lumetri clássico" + filtros de filme + edição por prompt com IA.
// Ordem (igual à de um revelador): RAW decodificado em luz linear (CIRAWFilter, exposição nativa do RAW) → exposição →
// balanço (temperatura/matiz em luz linear) → realces/sombras → [espaço com gama] curva (contraste, brancos, pretos,
// desbotar) → vibração/saturação → FILTRO (cubo 3D 33³, intensidade) → clareza/nitidez → vinheta → grão → [linear de novo].
// A mesma receita roda na prévia (cópia reduzida, raios escalados) e na exportação em resolução cheia.
struct PhotoAdjust: Equatable, Codable {
  var exposure = 0.0, contrast = 0.0, highlights = 0.0, shadows = 0.0, whites = 0.0, blacks = 0.0
  var temperature = 0.0, tint = 0.0, vibrance = 0.0, saturation = 0.0
  var sharpness = 0.0, clarity = 0.0, fade = 0.0, vignette = 0.0, grain = 0.0
  var look = "natural", lookAmount = 1.0
  var isNeutral: Bool { self == PhotoAdjust() }

  struct Slider: Identifiable { let id: String; let label: String; let group: String; let range: ClosedRange<Double>; let path: WritableKeyPath<PhotoAdjust, Double> }
  static let sliders: [Slider] = [
    Slider(id: "exposure", label: "Exposição", group: "Luz", range: -3...3, path: \.exposure),
    Slider(id: "contrast", label: "Contraste", group: "Luz", range: -1...1, path: \.contrast),
    Slider(id: "highlights", label: "Realces", group: "Luz", range: -1...1, path: \.highlights),
    Slider(id: "shadows", label: "Sombras", group: "Luz", range: -1...1, path: \.shadows),
    Slider(id: "whites", label: "Brancos", group: "Luz", range: -1...1, path: \.whites),
    Slider(id: "blacks", label: "Pretos", group: "Luz", range: -1...1, path: \.blacks),
    Slider(id: "temperature", label: "Temperatura", group: "Cor", range: -1...1, path: \.temperature),
    Slider(id: "tint", label: "Matiz", group: "Cor", range: -1...1, path: \.tint),
    Slider(id: "vibrance", label: "Vibração", group: "Cor", range: -1...1, path: \.vibrance),
    Slider(id: "saturation", label: "Saturação", group: "Cor", range: -1...1, path: \.saturation),
    Slider(id: "sharpness", label: "Nitidez", group: "Efeitos", range: 0...1, path: \.sharpness),
    Slider(id: "clarity", label: "Clareza", group: "Efeitos", range: -1...1, path: \.clarity),
    Slider(id: "fade", label: "Desbotar", group: "Efeitos", range: 0...1, path: \.fade),
    Slider(id: "vignette", label: "Vinheta", group: "Efeitos", range: -1...1, path: \.vignette),
    Slider(id: "grain", label: "Grão", group: "Efeitos", range: 0...1, path: \.grain),
  ]
}

// filtros (cubo 3D em espaço com gama): os looks do vídeo + emulações de filme feitas pra foto
struct PhotoLook: Identifiable {
  let id: String, label: String
  let p: [String: Double]
  var shadowTint = SIMD3<Double>(0, 0, 0), highTint = SIMD3<Double>(0, 0, 0)
  var curveS = 0.0   // curva em S extra (densidade de filme)
  static let all: [PhotoLook] = [
    PhotoLook(id: "natural", label: "Natural", p: [:]),
    PhotoLook(id: "cowboy", label: "Cowboy", p: LookPreset.named("cowboy").p),
    PhotoLook(id: "portra", label: "Retrato 400", p: ["temp": 0.15, "contrast": -0.06, "saturation": -0.08, "vibrance": 0.12, "fade": 0.12, "shadows": 0.1],
      shadowTint: SIMD3(-0.008, 0.012, 0.018), highTint: SIMD3(0.03, 0.014, -0.012), curveS: 0.08),
    PhotoLook(id: "chrome", label: "Chrome Clássico", p: ["contrast": 0.18, "saturation": -0.32, "highlights": -0.12],
      shadowTint: SIMD3(-0.01, 0.004, 0.026), highTint: SIMD3(0.012, 0.008, -0.006), curveS: 0.2),
    PhotoLook(id: "velvia", label: "Slide Vivo", p: ["saturation": 0.32, "contrast": 0.14, "vibrance": 0.2, "highlights": -0.08], curveS: 0.18),
    PhotoLook(id: "ouro", label: "Hora Dourada", p: ["temp": 0.45, "contrast": 0.06, "highlights": -0.12, "vibrance": 0.1],
      highTint: SIMD3(0.04, 0.02, -0.025)),
    PhotoLook(id: "teal", label: "Teal & Laranja", p: ["teal": 0.9, "contrast": 0.14, "saturation": 0.04], curveS: 0.1),
    PhotoLook(id: "cinema", label: "Cinema", p: LookPreset.named("cinema").p),
    PhotoLook(id: "setenta", label: "Anos 70", p: ["fade": 0.42, "temp": 0.25, "contrast": -0.1, "saturation": -0.2],
      shadowTint: SIMD3(-0.01, 0.03, 0.0), highTint: SIMD3(0.03, 0.01, -0.03)),
    PhotoLook(id: "suave", label: "Suave", p: LookPreset.named("suave").p),
    PhotoLook(id: "noite", label: "Noite Neon", p: ["contrast": 0.12, "temp": -0.3, "tint": -0.15, "saturation": 0.15, "highlights": -0.2],
      shadowTint: SIMD3(0.01, -0.01, 0.04), highTint: SIMD3(0.03, -0.01, 0.02), curveS: 0.12),
    PhotoLook(id: "pb", label: "P&B", p: LookPreset.named("pb").p),
    PhotoLook(id: "hp5", label: "P&B 400", p: ["bw": 1, "contrast": 0.12, "fade": 0.12], curveS: 0.15),
    PhotoLook(id: "noir", label: "Noir", p: ["bw": 1, "contrast": 0.45, "highlights": -0.1, "shadows": -0.15], curveS: 0.25),
  ]
  static func named(_ id: String) -> PhotoLook { all.first { $0.id == id } ?? all[0] }
  func apply(_ c: SIMD3<Double>) -> SIMD3<Double> {
    var o = p.isEmpty ? c : ColorMath.grade(c, p)
    if curveS != 0 { o = SIMD3(Self.s(o.x, curveS), Self.s(o.y, curveS), Self.s(o.z, curveS)) }
    let y = 0.2126 * o.x + 0.7152 * o.y + 0.0722 * o.z
    o += shadowTint * ((1 - y) * (1 - y)) + highTint * (y * y)
    return SIMD3(min(1, max(0, o.x)), min(1, max(0, o.y)), min(1, max(0, o.z)))
  }
  private static func s(_ x: Double, _ k: Double) -> Double { let t = x * x * (3 - 2 * x); return x + (t - x) * k }
}

final class PhotoDeveloper: @unchecked Sendable {
  let context = CIContext(options: [.cacheIntermediates: false])
  private var cubes: [String: Data] = [:]
  private let lock = NSLock()

  // imagem de partida: RAW (linear, latitude total) ou HEIF/JPEG, já orientada. maxSide = cópia reduzida pra prévia
  func load(_ url: URL, maxSide: CGFloat? = nil, exposure: Double = 0) -> (image: CIImage, rawEV: Bool)? {
    if url.pathExtension.lowercased() == "dng", let data = try? Data(contentsOf: url), let raw = CIRAWFilter(imageData: data, identifierHint: "com.adobe.raw-image") {
      if let maxSide { let full = raw.nativeSize; let m = max(full.width, full.height); if m > maxSide { raw.scaleFactor = Float(maxSide / m) } ; raw.isDraftModeEnabled = false }
      raw.exposure = Float(exposure)
      if let out = raw.outputImage { return (out, true) }
    }
    guard var img = CIImage(contentsOf: url, options: [.applyOrientationProperty: true]) else { return nil }
    if let maxSide { let m = max(img.extent.width, img.extent.height); if m > maxSide { img = img.transformed(by: CGAffineTransform(scaleX: maxSide / m, y: maxSide / m)) } }
    return (img, false)
  }

  private func cube(_ look: PhotoLook, amount: Double) -> Data {
    let key = look.id + String(format: "%.2f", amount)
    lock.lock(); if let c = cubes[key] { lock.unlock(); return c }; lock.unlock()
    let f = ColorMath.cubeFloats(size: 33) { c in let o = look.apply(c); return c + (o - c) * amount }
    let d = f.withUnsafeBufferPointer { Data(buffer: $0) }
    lock.lock(); cubes[key] = d; if cubes.count > 40 { cubes.removeAll() }; lock.unlock()
    return d
  }

  // receita inteira; `scale` = tamanho desta cópia ÷ resolução cheia (raios de nitidez/clareza/grão acompanham)
  func develop(_ input: CIImage, _ a: PhotoAdjust, rawEV: Bool, scale: CGFloat = 1) -> CIImage {
    let ext = input.extent
    var img = input
    if a.exposure != 0 && !rawEV { let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(a.exposure); img = f.outputImage ?? img }
    if a.temperature != 0 || a.tint != 0 {
      let t = a.temperature, m = a.tint
      let f = CIFilter.colorMatrix(); f.inputImage = img
      f.rVector = CIVector(x: CGFloat(1 + 0.22 * t + 0.06 * m), y: 0, z: 0, w: 0)
      f.gVector = CIVector(x: 0, y: CGFloat(1 - 0.16 * m), z: 0, w: 0)
      f.bVector = CIVector(x: 0, y: 0, z: CGFloat(1 - 0.22 * t + 0.06 * m), w: 0)
      img = f.outputImage ?? img
    }
    if a.highlights < 0 || a.shadows != 0 {
      let f = CIFilter.highlightShadowAdjust(); f.inputImage = img
      f.highlightAmount = Float(1 + min(0, a.highlights)); f.shadowAmount = Float(a.shadows)
      f.radius = Float(max(1, 0.012 * max(ext.width, ext.height)))
      img = f.outputImage ?? img
    }
    // daqui em diante em valores com gama (curva e cubo pensados assim, como no Lumetri)
    img = img.applyingFilter("CILinearToSRGBToneCurve")
    let hiUp = max(0, a.highlights) * 0.08
    let c = a.contrast * 0.09
    let p0 = CGPoint(x: 0, y: max(0, a.blacks * 0.1 + a.fade * 0.12)), p4 = CGPoint(x: 1, y: min(1.1, 1 + a.whites * 0.1 - a.fade * 0.04))
    if c != 0 || hiUp != 0 || p0.y != 0 || p4.y != 1 || a.blacks < 0 || a.whites != 0 {
      let f = CIFilter.toneCurve(); f.inputImage = img
      let x0 = a.blacks < 0 ? CGFloat(-a.blacks * 0.06) : 0, x4 = a.whites > 0 ? CGFloat(1 - a.whites * 0.06) : 1
      f.point0 = CGPoint(x: x0, y: p0.y)
      f.point1 = CGPoint(x: 0.25, y: 0.25 - c + p0.y * 0.5)
      f.point2 = CGPoint(x: 0.5, y: 0.5 + hiUp * 0.3)
      f.point3 = CGPoint(x: 0.75, y: 0.75 + c + hiUp)
      f.point4 = CGPoint(x: x4, y: p4.y)
      img = f.outputImage ?? img
    }
    if a.vibrance != 0 { let f = CIFilter.vibrance(); f.inputImage = img; f.amount = Float(a.vibrance); img = f.outputImage ?? img }
    if a.saturation != 0 { let f = CIFilter.colorControls(); f.inputImage = img; f.saturation = Float(1 + a.saturation); f.contrast = 1; f.brightness = 0; img = f.outputImage ?? img }
    let look = PhotoLook.named(a.look)
    if look.id != "natural" && a.lookAmount > 0 {
      let f = CIFilter.colorCube(); f.inputImage = img; f.cubeDimension = 33; f.cubeData = cube(look, amount: min(1, max(0, a.lookAmount)))
      img = f.outputImage ?? img
    }
    let side = max(ext.width, ext.height)
    if a.clarity > 0 {
      let f = CIFilter.unsharpMask(); f.inputImage = img; f.radius = Float(max(2, side * 0.012)); f.intensity = Float(a.clarity * 0.7); img = f.outputImage ?? img
    } else if a.clarity < 0 {
      let blur = img.clampedToExtent().applyingGaussianBlur(sigma: Double(max(2, side * 0.006))).cropped(to: ext)
      let f = CIFilter.dissolveTransition(); f.inputImage = img; f.targetImage = blur; f.time = Float(-a.clarity * 0.5); img = f.outputImage ?? img
    }
    if a.sharpness > 0 {
      let f = CIFilter.sharpenLuminance(); f.inputImage = img; f.sharpness = Float(a.sharpness * 1.2); f.radius = Float(max(0.6, 1.6 * scale)); img = f.outputImage ?? img
    }
    if a.vignette != 0 {
      let f = CIFilter.vignetteEffect(); f.inputImage = img
      f.center = CGPoint(x: ext.midX, y: ext.midY); f.radius = Float(hypot(ext.width, ext.height) * 0.42)
      f.intensity = Float(a.vignette * 0.9); f.falloff = 0.6
      img = f.outputImage ?? img
    }
    if a.grain > 0 {
      // grão monocromático do tamanho de um grão de filme (~1/1800 do lado maior), mistura em luz suave
      let size = max(1, side / 1800)
      var noise = CIFilter.randomGenerator().outputImage ?? CIImage(color: .gray)
      let m = CIFilter.colorMatrix(); m.inputImage = noise
      let k = CGFloat(a.grain * 0.55)
      let v = CIVector(x: k / 3, y: k / 3, z: k / 3, w: 0)
      m.rVector = v; m.gVector = v; m.bVector = v; m.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
      m.biasVector = CIVector(x: 0.5 - k / 2, y: 0.5 - k / 2, z: 0.5 - k / 2, w: 0)
      noise = (m.outputImage ?? noise).transformed(by: CGAffineTransform(scaleX: size, y: size)).transformed(by: CGAffineTransform(translationX: ext.minX, y: ext.minY)).cropped(to: ext)
      let b = CIFilter.softLightBlendMode(); b.inputImage = noise; b.backgroundImage = img
      img = b.outputImage ?? img
    }
    img = img.applyingFilter("CISRGBToneCurveToLinear")
    return img.cropped(to: ext)
  }

  func cgImage(_ img: CIImage) -> CGImage? {
    context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.displayP3))
  }
  func jpeg(_ img: CIImage, maxSide: CGFloat, quality: CGFloat = 0.9) -> Data? {
    var i = img
    let m = max(i.extent.width, i.extent.height)
    if m > maxSide { i = i.transformed(by: CGAffineTransform(scaleX: maxSide / m, y: maxSide / m)) }
    i = i.transformed(by: CGAffineTransform(translationX: -i.extent.minX, y: -i.extent.minY))
    guard let cs = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return context.jpegRepresentation(of: i, colorSpace: cs, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: quality])
  }
  // exportação: HEIF 10 bits em P3 (cai pra 8 bits se o aparelho recusar)
  func heif(_ img: CIImage) -> Data? {
    let i = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))
    guard let cs = CGColorSpace(name: CGColorSpace.displayP3) else { return nil }
    if let d = try? context.heif10Representation(of: i, colorSpace: cs, options: [:]) { return d }
    return context.heifRepresentation(of: i, format: .RGBA8, colorSpace: cs, options: [:])
  }
}

// edição por PROMPT: manda a foto (como está na tela, até 1536 px) pro servidor, que tenta o pool grátis (Gemini Nano Banana)
// e depois o pago (OpenAI gpt-image-1.5). A resposta volta no enquadramento original (a IA pode devolver outra proporção).
enum PhotoAI {
  enum Engine: String, CaseIterable, Identifiable { case auto, gratis, openai
    var id: String { rawValue }
    var label: String { self == .auto ? "Grátis primeiro" : self == .gratis ? "Só grátis" : "OpenAI" }
  }
  struct Result { let image: CIImage; let engine: String; let model: String; let tried: [String] }
  @MainActor static func edit(jpeg: Data, prompt: String, engine: Engine, cookie: String?) async throws -> Result {
    var req = URLRequest(url: URL(string: "/api/rec/foto-ia", relativeTo: CowboyCloud.origin)!.absoluteURL)
    req.httpMethod = "POST"; req.timeoutInterval = 300
    if let cookie { req.setValue(cookie, forHTTPHeaderField: "Cookie") }
    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    req.httpBody = try JSONSerialization.data(withJSONObject: ["image": "data:image/jpeg;base64," + jpeg.base64EncodedString(), "prompt": prompt, "engine": engine.rawValue])
    let cfg = URLSessionConfiguration.ephemeral; cfg.httpShouldSetCookies = false; cfg.timeoutIntervalForRequest = 300; cfg.timeoutIntervalForResource = 320
    let session = URLSession(configuration: cfg)
    defer { session.finishTasksAndInvalidate() }
    let (body, resp) = try await session.data(for: req)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    let j = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    let tried = j["tried"] as? [String] ?? []
    if code == 401 { throw CowboyCloud.CloudError.message("Entre na conta Cowboy pelo app") }
    guard code == 200, let s = j["image"] as? String, let comma = s.firstIndex(of: ","), let data = Data(base64Encoded: String(s[s.index(after: comma)...])), let img = CIImage(data: data) else {
      throw CowboyCloud.CloudError.message((j["error"] as? String ?? "HTTP \(code)") + (tried.isEmpty ? "" : " · " + (tried.last ?? "")))
    }
    return Result(image: img, engine: j["engine"] as? String ?? "?", model: j["model"] as? String ?? "?", tried: tried)
  }
  // cobre o quadro original (mesma proporção), centralizado
  static func fit(_ img: CIImage, toAspectOf ref: CGRect) -> CIImage {
    let e = img.extent, want = ref.width / max(1, ref.height), have = e.width / max(1, e.height)
    var r = e
    if have > want { let w = e.height * want; r = CGRect(x: e.midX - w / 2, y: e.minY, width: w, height: e.height) }
    else if have < want { let h = e.width / want; r = CGRect(x: e.minX, y: e.midY - h / 2, width: e.width, height: h) }
    let c = img.cropped(to: r)
    return c.transformed(by: CGAffineTransform(translationX: -c.extent.minX, y: -c.extent.minY))
  }
}
