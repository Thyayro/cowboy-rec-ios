import CoreMedia
import CoreVideo
import Metal

// ARQUIVO FINAL EM REC.709 + LOOK, feito no iPhone durante a gravação, em tempo real.
// Cada quadro do sensor (Apple Log/HLG 10 bits Rec.2020, ou SDR 8 bits) é lido DIRETO dos planos Y e CbCr na GPU, vira R'G'B'
// pela matriz da fonte, passa pelo cubo 3D da MESMA conta da VPS (ColorMath: curva oficial do Apple Log -> linear ->
// Rec.2020->709 -> tom -> gama 709 -> look) com interpolação trilinear em ponto flutuante e é gravado num quadro 10 bits
// Rec.709 (matriz BT.709, faixa de vídeo) etiquetado BT.709. Shader Metal próprio: ~2 ms por quadro 4K (a 0.5.4 usava
// Core Image e perdia ~14 quadros/s em 4K60).
final class LutBaker: @unchecked Sendable {
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private let lut: MTLTexture
  private let lutN: Int
  private var cache: CVMetalTextureCache?
  private var pool: CVPixelBufferPool?
  private var format: CMVideoFormatDescription?
  private var dims = (0, 0)
  private(set) var failures = 0
  private(set) var lastError = ""

  static let shader = """
  #include <metal_stdlib>
  using namespace metal;
  kernel void bake(texture2d<float, access::read> yIn [[texture(0)]],
                   texture2d<float, access::read> cIn [[texture(1)]],
                   texture3d<float, access::sample> lut [[texture(2)]],
                   texture2d<float, access::write> yOut [[texture(3)]],
                   texture2d<float, access::write> cOut [[texture(4)]],
                   constant float4 *prm [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= cOut.get_width() || gid.y >= cOut.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float4 a = prm[0];   // escala Y, piso Y, escala C, centro C (faixa de vídeo da fonte)
    float4 m = prm[1];   // matriz da fonte: Cr->R, Cb->G, Cr->G, Cb->B
    float n = prm[2].x;  // lado do cubo
    float2 cc = cIn.read(gid).rg;
    float cb = (cc.r - a.w) * a.z, cr = (cc.g - a.w) * a.z;
    float sumCb = 0.0, sumCr = 0.0;
    for (uint dy = 0; dy < 2; dy++) {
      for (uint dx = 0; dx < 2; dx++) {
        uint2 p = gid * 2 + uint2(dx, dy);
        float y = (yIn.read(p).r - a.y) * a.x;
        float3 rgb = clamp(float3(y + m.x * cr, y - m.y * cb - m.z * cr, y + m.w * cb), 0.0, 1.0);
        float3 o = lut.sample(s, (rgb * (n - 1.0) + 0.5) / n).rgb;
        float Y = dot(o, float3(0.2126, 0.7152, 0.0722));
        yOut.write(float4((64.0 + 876.0 * Y) / 1023.0), p);
        sumCb += (o.b - Y) / 1.8556; sumCr += (o.r - Y) / 1.5748;
      }
    }
    cOut.write(float4((512.0 + 896.0 * sumCb * 0.25) / 1023.0, (512.0 + 896.0 * sumCr * 0.25) / 1023.0, 0.0, 0.0), gid);
  }
  """

  init?(transform: (SIMD3<Double>) -> SIMD3<Double>, size: Int = 33) {
    guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
      let library = try? device.makeLibrary(source: Self.shader, options: nil), let fn = library.makeFunction(name: "bake"),
      let pipeline = try? device.makeComputePipelineState(function: fn) else { return nil }
    self.device = device; self.queue = queue; self.pipeline = pipeline; self.lutN = size
    let d = MTLTextureDescriptor()
    d.textureType = .type3D; d.pixelFormat = .rgba16Float; d.width = size; d.height = size; d.depth = size; d.usage = .shaderRead
    guard let tex = device.makeTexture(descriptor: d) else { return nil }
    let floats = ColorMath.cubeFloats(size: size, transform).map { Float16($0) }
    floats.withUnsafeBytes { raw in
      tex.replace(region: MTLRegionMake3D(0, 0, 0, size, size, size), mipmapLevel: 0, slice: 0, withBytes: raw.baseAddress!, bytesPerRow: size * 8, bytesPerImage: size * size * 8)
    }
    lut = tex
    CVMetalTextureCacheCreate(nil, nil, device, nil, &cache)
  }

  private func makePool(_ w: Int, _ h: Int) {
    let attrs: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
      kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:], kCVPixelBufferMetalCompatibilityKey as String: true]
    var p: CVPixelBufferPool?
    CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 8] as CFDictionary, attrs as CFDictionary, &p)
    pool = p; dims = (w, h); format = nil
  }
  private func texture(_ buffer: CVPixelBuffer, plane: Int, format: MTLPixelFormat, write: Bool) -> CVMetalTexture? {
    guard let cache else { return nil }
    let w = CVPixelBufferGetWidthOfPlane(buffer, plane), h = CVPixelBufferGetHeightOfPlane(buffer, plane)
    let attrs = write ? [kCVMetalTextureUsage as String: MTLTextureUsage([.shaderRead, .shaderWrite]).rawValue] as CFDictionary : nil
    var t: CVMetalTexture?
    guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, buffer, attrs, format, w, h, plane, &t) == kCVReturnSuccess else { return nil }
    return t
  }
  private func fail(_ why: String) -> CMSampleBuffer? { failures += 1; lastError = why; return nil }

  // quadro convertido com o mesmo tempo do original; nil = não deu (quem chama grava o original e conta a falha)
  func convert(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
    guard let src = CMSampleBufferGetImageBuffer(sample) else { return fail("sem imagem") }
    let fmt = CVPixelBufferGetPixelFormatType(src)
    let ten = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    let eight = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    guard ten || eight, CVPixelBufferGetPlaneCount(src) == 2 else { return fail("formato \(fmt)") }
    let full = fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange || fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
    let w = CVPixelBufferGetWidth(src), h = CVPixelBufferGetHeight(src)
    if pool == nil || dims != (w, h) { makePool(w, h) }
    guard let pool else { return fail("sem pool") }
    var out: CVPixelBuffer?
    guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return fail("pool cheio") }
    CVBufferSetAttachment(out, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(out, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
    CVBufferSetAttachment(out, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
    let pf: (MTLPixelFormat, MTLPixelFormat) = ten ? (.r16Unorm, .rg16Unorm) : (.r8Unorm, .rg8Unorm)
    guard let ty = texture(src, plane: 0, format: pf.0, write: false), let tc = texture(src, plane: 1, format: pf.1, write: false),
      let oy = texture(out, plane: 0, format: .r16Unorm, write: true), let oc = texture(out, plane: 1, format: .rg16Unorm, write: true),
      let yIn = CVMetalTextureGetTexture(ty), let cIn = CVMetalTextureGetTexture(tc), let yOut = CVMetalTextureGetTexture(oy), let cOut = CVMetalTextureGetTexture(oc)
    else { return fail("textura") }
    // faixa da fonte (normalizada pelo máximo do código) e matriz: Rec.2020 nas fontes 10 bits (Log/HLG), Rec.709 no SDR
    let maxCode: Float = ten ? 1023 : 255
    let center: Float = (ten ? 512 : 128) / maxCode
    var range = SIMD4<Float>(1, 0, 1, center)
    if !full && ten { range = SIMD4<Float>(1023.0 / 876.0, 64.0 / 1023.0, 1023.0 / 896.0, 512.0 / 1023.0) }
    if !full && !ten { range = SIMD4<Float>(255.0 / 219.0, 16.0 / 255.0, 255.0 / 224.0, 128.0 / 255.0) }
    let rec2020 = SIMD4<Float>(1.4746, 0.16455, 0.57135, 1.8814), rec709 = SIMD4<Float>(1.5748, 0.1873, 0.4681, 1.8556)
    let matrix = ten ? rec2020 : rec709
    var prm: [SIMD4<Float>] = [range, matrix, SIMD4(Float(lutN), 0, 0, 0)]
    guard let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return fail("comando") }
    enc.setComputePipelineState(pipeline)
    enc.setTexture(yIn, index: 0); enc.setTexture(cIn, index: 1); enc.setTexture(lut, index: 2); enc.setTexture(yOut, index: 3); enc.setTexture(cOut, index: 4)
    enc.setBytes(&prm, length: MemoryLayout<SIMD4<Float>>.stride * 3, index: 0)
    let tg = MTLSize(width: 16, height: 16, depth: 1)
    enc.dispatchThreads(MTLSize(width: cOut.width, height: cOut.height, depth: 1), threadsPerThreadgroup: tg)
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    _ = (ty, tc, oy, oc)   // texturas vivas até a GPU terminar
    if cb.status != .completed { return fail("gpu \(cb.error?.localizedDescription ?? "")") }
    if format == nil {
      var f: CMVideoFormatDescription?
      CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: out, formatDescriptionOut: &f)
      format = f
    }
    guard let format else { return fail("descrição") }
    var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sample), presentationTimeStamp: CMSampleBufferGetPresentationTimeStamp(sample), decodeTimeStamp: .invalid)
    var result: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: out, formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result) == noErr else { return fail("amostra") }
    return result
  }
}
