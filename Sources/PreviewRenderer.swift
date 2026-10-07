import CoreImage
import Metal
import MetalKit
import QuartzCore
import SwiftUI

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
    lock.lock(); defer { lock.unlock() }
    if frozen { return }
    if dropFrames > 0 { dropFrames -= 1; return }
    pending = buffer; pendingPTS = pts
  }
  // troca de câmera/formato: a tela segura o último quadro (sem piscar deitado) até chegarem quadros da configuração nova
  func freeze() { lock.lock(); frozen = true; pending = nil; lock.unlock() }
  func thaw(drop: Int = 4) { lock.lock(); frozen = false; dropFrames = drop; zoomHistory.removeAll(); lock.unlock() }
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
    image = image.transformed(by: CGAffineTransform(scaleX: scale * k, y: scale * k))
    image = image.transformed(by: CGAffineTransform(translationX: fit.midX - image.extent.midX, y: fit.midY - image.extent.midY))
    if k < 1 { image = image.clampedToExtent() }
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
