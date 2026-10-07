import CoreImage
import CoreMedia
import CoreVideo
import Metal

// ARQUIVO FINAL EM REC.709 + LOOK, feito no iPhone durante a gravação: cada quadro Apple Log (10 bits, Rec.2020) passa pela
// curva OFICIAL do Apple Log -> luz linear -> Rec.2020->709 -> tom -> gama 709 (ColorMath, a mesma conta da VPS) e depois pelo
// look escolhido, em ponto flutuante na GPU, e sai num quadro 10 bits Rec.709 de verdade (etiquetado BT.709) pro codificador.
// Não é a prévia: é o sinal do sensor convertido, quadro a quadro, na resolução e no qps cheios.
final class LutBaker: @unchecked Sendable {
  private let context: CIContext
  private let cube: Data
  private let size: Int
  private var pool: CVPixelBufferPool?
  private var format: CMVideoFormatDescription?
  private var dims = (0, 0)
  private(set) var failures = 0

  init?(transform: (SIMD3<Double>) -> SIMD3<Double>, size: Int = 33) {
    guard let device = MTLCreateSystemDefaultDevice() else { return nil }
    context = CIContext(mtlDevice: device, options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false, .workingFormat: CIFormat.RGBAh])
    let floats = ColorMath.cubeFloats(size: size, transform)
    cube = floats.withUnsafeBufferPointer { Data(buffer: $0) }
    self.size = size
  }

  private func makePool(_ w: Int, _ h: Int) {
    let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
    var p: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary, attrs as CFDictionary, &p)
    pool = p; dims = (w, h); format = nil
  }

  // quadro convertido com o mesmo tempo do original; nil = não deu (quem chama grava o original e conta a falha)
  func convert(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
    guard let src = CMSampleBufferGetImageBuffer(sample) else { return nil }
    let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
    if pool == nil || dims != (w, h) { makePool(w, h) }
    guard let pool else { failures += 1; return nil }
    var out: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { failures += 1; return nil }
    CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    let image = PreviewRenderer.filtered(CIImage(cvPixelBuffer: src, options: [.colorSpace: NSNull()]), cube: cube, size: size)
    context.render(image, to: out, bounds: CGRect(x: 0, y: 0, width: w, height: h), colorSpace: nil)
    if format == nil {
      var f: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: out, formatDescriptionOut: &f)
      format = f
    }
    guard let format else { failures += 1; return nil }
    var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), decodeTimeStamp: .invalid)
    var result: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: out, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result) == noErr else { failures += 1; return nil }
    return result
  }
}
