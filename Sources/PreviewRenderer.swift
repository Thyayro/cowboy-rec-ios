import CoreImage
import Metal
import MetalKit
import QuartzCore
import SwiftUI
import Vision

// Preview drawn from the SAME stabilized frames that go to the file (what you see is what is recorded), with the
// display LUT (Apple Log/HLG -> Rec.709 + look) applied on the GPU. No color management: code values in, code values out,
// exactly like the .cube the cloud uses.
final class PreviewRenderer: NSObject, MTKViewDelegate, @unchecked Sendable {
  let device: MTLDevice?
  private let commandQueue: MTLCommandQueue?
  let context: CIContext
  private let lock = NSLock()
  private var pending: CVPixelBuffer?
  private var pendingPTS: Double?
  private var frozen = false
  private var dropFrames = 0
  // zoom sem atraso: a estabilização entrega o quadro ~0,3–1 s depois; o zoom da tela usa o zoom de AGORA sobre o quadro
  // atrasado (escala = zoom agora ÷ zoom no instante em que o quadro foi captado). O arquivo não muda.
  var zoomNow: (() -> Double?)?
  private var zoomHistory: [(Double, Double)] = []
  // ZOOM PERFEITO: enquanto o zoom se mexe, a tela mostra a saída SEM estabilização (tempo real, quadro inteiro, sem borda
  // inventada), no mesmo enquadramento do estabilizado (corte do estabilizador medido sozinho pelo Vision); parou e o quadro
  // estabilizado alcançou -> volta pra ele. O arquivo é sempre o estabilizado.
  private var fastBuffer: CVPixelBuffer?
  private var fastPTS: Double?
  private var fastUntil = 0.0
  private var crop = 1.12
  private var cropSamples: [Double] = []
  private var calibFast: (pts: Double, image: CGImage)?
  private var calibBusy = false
  private var nextCalib = 0.0
  private let calibQueue = DispatchQueue(label: "cowboy.preview.calib", qos: .utility)
  var onCrop: ((Double) -> Void)?
  var hasFast: Bool { lock.lock(); defer { lock.unlock() }; return fastBuffer != nil }
  private var cube: Data?
  private var cubeSize = 33
  private var orientation: CGImagePropertyOrientation = .right
  private var mirrored = false
  private(set) var frames = 0

  override init() {
    device = MTLCreateSystemDefaultDevice()
    commandQueue = device?.makeCommandQueue()
    let options: [CIContextOption: Any] = [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false]
    if let device { context = CIContext(mtlDevice: device, options: options) } else { context = CIContext(options: options) }
    super.init()
  }
  func push(_ buffer: CVPixelBuffer, pts: Double? = nil) {
    lock.lock()
    if frozen { lock.unlock(); return }
    if dropFrames > 0 { dropFrames -= 1; lock.unlock(); return }
    pending = buffer; pendingPTS = pts
    var match: (pts: Double, image: CGImage)?
    if let cf = calibFast, let pts {
      if abs(cf.pts - pts) < 0.004 { match = cf; calibFast = nil } else if pts > cf.pts + 0.1 { calibFast = nil; calibBusy = false }
    }
    lock.unlock()
    if let match { calibQueue.async { self.register(stabilized: buffer, fast: match.image) } }
  }
  func pushFast(_ buffer: CVPixelBuffer, pts: Double) {
    lock.lock()
    if frozen { lock.unlock(); return }
    fastBuffer = buffer; fastPTS = pts
    let now = CACurrentMediaTime()
    let calm = now - fastUntil > 1.2   // zoom parado há um tempo: dá pra medir o corte
    let go = calm && !calibBusy && now >= nextCalib
    if go { calibBusy = true; nextCalib = now + (cropSamples.count < 3 ? 0.6 : 3) }
    lock.unlock()
    if go { calibQueue.async { if let img = self.small(buffer) { self.lock.lock(); self.calibFast = (pts, img); self.lock.unlock() } else { self.lock.lock(); self.calibBusy = false; self.lock.unlock() } } }
  }
  private func small(_ buffer: CVPixelBuffer) -> CGImage? {
    var img = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()])
    let s = 480 / max(1, img.extent.width)
    img = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
    return context.createCGImage(img, from: img.extent, format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
  }
  // mesma hora de captura nas duas saídas -> homografia entre o quadro estabilizado e o cru -> escala = corte do estabilizador
  private func register(stabilized: CVPixelBuffer, fast: CGImage) {
    defer { lock.lock(); calibBusy = false; lock.unlock() }
    guard let stab = small(stabilized) else { return }
    let request = VNHomographicImageRegistrationRequest(targetedCGImage: fast, options: [:])
    guard (try? VNImageRequestHandler(cgImage: stab, options: [:]).perform([request])) != nil,
      let obs = request.results?.first as? VNImageHomographicAlignmentObservation else { return }
    let m = obs.warpTransform
    let det = Double(abs(m.columns.0.x * m.columns.1.y - m.columns.1.x * m.columns.0.y))
    guard det > 0.0001 else { return }
    var c = det.squareRoot(); if c < 1 { c = 1 / c }
    guard c >= 1, c <= 1.8 else { return }
    lock.lock()
    cropSamples.append(c); if cropSamples.count > 7 { cropSamples.removeFirst() }
    let sorted = cropSamples.sorted(); crop = sorted[sorted.count / 2]
    let value = crop, first = cropSamples.count == 3
    lock.unlock()
    if first { onCrop?(value) }
  }
  // troca de câmera/formato: a tela segura o último quadro (sem piscar deitado) até chegarem quadros da configuração nova
  func freeze() { lock.lock(); frozen = true; pending = nil; fastBuffer = nil; lock.unlock() }
  func thaw(drop: Int = 4) { lock.lock(); frozen = false; dropFrames = drop; zoomHistory.removeAll(); cropSamples.removeAll(); crop = 1.12; nextCalib = 0; calibFast = nil; calibBusy = false; lock.unlock() }
  private func zoomAt(_ t: Double) -> Double? {
    guard let first = zoomHistory.first else { return nil }
    if t <= first.0 { return first.1 }
    var last = first
    for e in zoomHistory { if e.0 > t { let k = (t - last.0) / max(0.0001, e.0 - last.0); return last.1 + (e.1 - last.1) * k }; last = e }
    return last.1
  }
  func setCube(_ data: Data?, size: Int) { lock.lock(); cube = data; cubeSize = size; lock.unlock() }
  func setOrientation(_ value: CGImagePropertyOrientation, mirrored mirror: Bool) { lock.lock(); orientation = value; mirrored = mirror; lock.unlock() }
  func currentCube() -> (Data?, Int) { lock.lock(); defer { lock.unlock() }; return (cube, cubeSize) }

  static func filtered(_ image: CIImage, cube: Data?, size: Int) -> CIImage {
    guard let cube, let filter = CIFilter(name: "CIColorCube") else { return image }
    filter.setValue(image, forKey: kCIInputImageKey)
    filter.setValue(size, forKey: "inputCubeDimension")
    filter.setValue(cube, forKey: "inputCubeData")
    return filter.outputImage ?? image
  }
  static func oriented(_ buffer: CVPixelBuffer, _ orientation: CGImagePropertyOrientation, mirrored: Bool) -> CIImage {
    var image = CIImage(cvPixelBuffer: buffer, options: [.colorSpace: NSNull()]).oriented(orientation)
    if mirrored { image = image.transformed(by: CGAffineTransform(scaleX: -1, y: 1)) }
    return image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
  func draw(in view: MTKView) {
    let now = CACurrentMediaTime()
    let zNow = zoomNow?()
    lock.lock()
    if let zNow, zNow > 0 { zoomHistory.append((now, zNow)); if zoomHistory.count > 600 { zoomHistory.removeFirst(zoomHistory.count - 600) } }
    let buffer = pending, pts = pendingPTS; pending = nil; let cube = self.cube, size = cubeSize, orient = orientation, mirror = mirrored
    let zFrame = pts.flatMap { zoomAt($0) }
    let fast = fastBuffer, zFast = fastPTS.flatMap { zoomAt($0) }, cropNow = crop
    lock.unlock()
    guard let buffer, let commandQueue, let drawable = view.currentDrawable, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    let target = view.drawableSize
    guard target.width > 0, target.height > 0 else { return }
    var image = Self.oriented(buffer, orient, mirrored: mirror)
    var k = 1.0
    if let zNow, let zFrame, zFrame > 0 { k = max(0.3, min(6, zNow / zFrame)); if abs(k - 1) < 0.004 { k = 1 } }
    // scale first: the LUT runs on screen pixels, not on 4K
    let scale = min(target.width / image.extent.width, target.height / image.extent.height)
    let fit = CGRect(x: (target.width - image.extent.width * scale) / 2, y: (target.height - image.extent.height * scale) / 2, width: image.extent.width * scale, height: image.extent.height * scale)
    if k != 1 { lock.lock(); fastUntil = now + 0.15; lock.unlock() }
    lock.lock(); let useFast = now < fastUntil && fast != nil; lock.unlock()
    if useFast, let fast {
      // zoom em movimento: quadro de AGORA, sem estabilização, cortado igual ao estabilizado
      var f = Self.oriented(fast, orient, mirrored: mirror)
      let kf = (zNow != nil && zFast != nil && zFast! > 0) ? max(0.5, min(3, zNow! / zFast!)) : 1
      let sF = min(target.width / f.extent.width, target.height / f.extent.height) * cropNow * max(1, kf)
      f = f.transformed(by: CGAffineTransform(scaleX: sF, y: sF))
      image = f.transformed(by: CGAffineTransform(translationX: fit.midX - f.extent.midX, y: fit.midY - f.extent.midY))
    } else {
      let kk = max(1, k)   // sem fonte rápida: só o zoom in é adiantado (o out espera o quadro real — nunca borda inventada)
      image = image.transformed(by: CGAffineTransform(scaleX: scale * kk, y: scale * kk))
      image = image.transformed(by: CGAffineTransform(translationX: fit.midX - image.extent.midX, y: fit.midY - image.extent.midY))
    }
    image = image.cropped(to: fit)
    image = Self.filtered(image, cube: cube, size: size)
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: target))
    image = image.composited(over: black)
    let destination = CIRenderDestination(width: Int(target.width), height: Int(target.height), pixelFormat: view.colorPixelFormat, commandBuffer: commandBuffer) { drawable.texture }
    destination.isFlipped = true
    _ = try? context.startTask(toRender: image, to: destination)
    commandBuffer.present(drawable)
    commandBuffer.commit()
    frames += 1
  }

  // First frame of a take -> small JPEG for the cloud library (with the same LUT, so Log takes show in Rec.709).
  func thumbnail(_ buffer: CVPixelBuffer, orientation: CGImagePropertyOrientation, mirrored: Bool, applyCube: Bool = true) -> Data? {
    var image = Self.oriented(buffer, orientation, mirrored: mirrored)
    let scale = 360 / max(1, image.extent.width)
    image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
    if applyCube { let (cube, size) = currentCube(); image = Self.filtered(image, cube: cube, size: size) }
    image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
    return context.jpegRepresentation(of: image, colorSpace: space, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.8])
  }
}

struct MetalPreview: UIViewRepresentable {
  let renderer: PreviewRenderer
  func makeUIView(context: Context) -> MTKView {
    let view = MTKView(frame: .zero, device: renderer.device)
    view.framebufferOnly = false
    view.colorPixelFormat = .bgra8Unorm
    view.enableSetNeedsDisplay = false
    view.isPaused = false
    view.preferredFramesPerSecond = 60
    view.autoResizeDrawable = true
    view.backgroundColor = .black
    view.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
    view.isUserInteractionEnabled = false
    view.delegate = renderer
    return view
  }
  func updateUIView(_ view: MTKView, context: Context) {}
}
