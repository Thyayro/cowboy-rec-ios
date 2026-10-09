import CoreMedia
import CoreVideo
import Metal

// ARQUIVO FINAL EM REC.709 + LOOK, feito no iPhone durante a gravação, em tempo real.
// Cada quadro do sensor (Apple Log/HLG 10 bits Rec.2020, ou SDR 8 bits) é lido DIRETO dos planos Y e CbCr na GPU, vira R'G'B'
// pela matriz da fonte, passa pelo cubo 3D da MESMA conta da VPS (ColorMath: curva oficial do Apple Log -> linear ->
// Rec.2020->709 -> tom -> gama 709 -> look) com interpolação trilinear em ponto flutuante e é gravado num quadro 10 bits
// Rec.709 (matriz BT.709, faixa de vídeo) etiquetado BT.709. Shader Metal próprio: ~2 ms por quadro 4K (a 0.5.4 usava
// Core Image e perdia ~14 quadros/s em 4K60).
// 0.9.0: desfoque de movimento em DUAS etapas quando o rastro é longo (n1 leituras no caminho inteiro -> textura do meio ->
// n2 leituras no passo da 1ª = n1×n2 amostras: rastro liso de zoom de edição) e dissolve curto na troca de lente parada.
final class LutBaker: @unchecked Sendable {
  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private let pipeline: MTLComputePipelineState
  private let streakPipeline: MTLComputePipelineState
  private let lut: MTLTexture
  private let lutN: Int
  private var cache: CVMetalTextureCache?
  private var pool: CVPixelBufferPool?
  private var format: CMVideoFormatDescription?
  private var dims = (0, 0)
  private var tmp: (y: MTLTexture, c: MTLTexture)?
  private(set) var failures = 0
  private(set) var lastError = ""

  static let shader = """
  #include <metal_stdlib>
  using namespace metal;
  // caminho do rastro: amostra de posição u (−0,5…0,5) = giro no eixo (roll) + escala radial do zoom + deslocamento do giro
  static float2 streakPath(float2 uv, float u, float4 b, float roll, float2 size) {
    float2 d = (uv - 0.5) * size;
    float an = roll * u, c = cos(an), sn = sin(an);
    d = float2(d.x * c - d.y * sn, d.x * sn + d.y * c);
    return 0.5 + d / size * exp(b.x * u) + b.yz * u;
  }
  // ruído intercalado: cada pixel desloca as amostras um pouco (rastro liso, sem cópias em degrau)
  static float streakJitter(uint2 p) { float f = 0.06711056 * float(p.x) + 0.00583715 * float(p.y); return fract(52.9829189 * fract(f)) - 0.5; }
  // 1ª etapa do rastro longo: n leituras espaçadas no caminho inteiro (valores da FONTE, antes da cor)
  kernel void streak(texture2d<float, access::sample> yIn [[texture(0)]],
                     texture2d<float, access::sample> cIn [[texture(1)]],
                     texture2d<float, access::write> yT [[texture(2)]],
                     texture2d<float, access::write> cT [[texture(3)]],
                     constant float4 *prm [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= cT.get_width() || gid.y >= cT.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float4 g = prm[5];
    float4 b = prm[6];
    float roll = prm[7].x;
    int n = max(1, int(b.w + 0.5));
    float2 size = float2(yT.get_width(), yT.get_height());
    for (uint dy = 0; dy < 2; dy++) {
      for (uint dx = 0; dx < 2; dx++) {
        uint2 p = gid * 2 + uint2(dx, dy);
        float2 uv = (float2(p) + 0.5) / size;
        float j = streakJitter(p), acc = 0.0;
        for (int i = 0; i < n; i++) {
          float u = (float(i) + 0.5 + j) / float(n) - 0.5;
          float2 src = (streakPath(uv, u, b, roll, size) - 0.5 - g.yz) / (g.x * g.w) + 0.5;
          acc += yIn.sample(s, src).r;
        }
        yT.write(float4(acc / float(n)), p);
      }
    }
    float2 uvc = (float2(gid) + 0.5) / float2(cT.get_width(), cT.get_height());
    float jc = streakJitter(gid * 2);
    float2 accC = float2(0.0);
    for (int i = 0; i < n; i++) {
      float u = (float(i) + 0.5 + jc) / float(n) - 0.5;
      float2 src = (streakPath(uvc, u, b, roll, size) - 0.5 - g.yz) / (g.x * g.w) + 0.5;
      accC += cIn.sample(s, src).rg;
    }
    cT.write(float4(accC / float(n), 0.0, 0.0), gid);
  }
  kernel void bake(texture2d<float, access::sample> yIn [[texture(0)]],
                   texture2d<float, access::sample> cIn [[texture(1)]],
                   texture3d<float, access::sample> lut [[texture(2)]],
                   texture2d<float, access::write> yOut [[texture(3)]],
                   texture2d<float, access::write> cOut [[texture(4)]],
                   texture2d<float, access::sample> yOld [[texture(5)]],
                   texture2d<float, access::sample> cOld [[texture(6)]],
                   constant float4 *prm [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= cOut.get_width() || gid.y >= cOut.get_height()) return;
    constexpr sampler s(filter::linear, address::clamp_to_edge, coord::normalized);
    float4 a = prm[0];   // escala Y, piso Y, escala C, centro C (faixa de vídeo da fonte)
    float4 m = prm[1];   // matriz da fonte: Cr->R, Cb->G, Cr->G, Cb->B
    float n = prm[2].x;  // lado do cubo
    float4 g = prm[5];   // troca de lente/zoom digital: escala, deslocamento x, y (coordenadas do quadro) e zoom de cobertura
    float4 b = prm[6];   // desfoque de movimento: ln(escala) do rastro radial, deslocamento x/y, amostras (1 = sem)
    float roll = prm[7].x, blend = prm[7].y, jit = prm[7].z;   // giro no eixo, peso do quadro da lente velha, ruído on/off
    float4 go = prm[8];  // geometria do quadro da lente velha (dissolve da troca)
    int nb = max(1, int(b.w + 0.5));
    float2 size = float2(yOut.get_width(), yOut.get_height());
    float sumCb = 0.0, sumCr = 0.0;
    for (uint dy = 0; dy < 2; dy++) {
      for (uint dx = 0; dx < 2; dx++) {
        uint2 p = gid * 2 + uint2(dx, dy);
        float2 uv = (float2(p) + 0.5) / size;
        float yv = 0.0;
        float2 cc = float2(0.0);
        if (nb > 1) {
          // rastro: nb leituras ao longo do caminho; média nos valores da fonte e a cor UMA vez depois (mesma conta da tela e da VPS)
          float j = jit > 0.5 ? streakJitter(p) : 0.0;
          for (int i = 0; i < nb; i++) {
            float u = (float(i) + 0.5 + j) / float(nb) - 0.5;
            float2 src = (streakPath(uv, u, b, roll, size) - 0.5 - g.yz) / (g.x * g.w) + 0.5;
            yv += yIn.sample(s, src).r;
            cc += cIn.sample(s, src).rg;
          }
          yv /= float(nb); cc /= float(nb);
        } else {
          float2 src = (uv - 0.5 - g.yz) / (g.x * g.w) + 0.5;   // 4:2:0 e 4:2:2 caem certo: coordenada normalizada
          yv = yIn.sample(s, src).r;
          cc = cIn.sample(s, src).rg;
        }
        if (blend > 0.0) {   // troca de lente com o zoom parado: dissolve curto do último quadro da lente velha pra nova
          float2 so = (uv - 0.5 - go.yz) / (go.x * go.w) + 0.5;
          yv = mix(yv, yOld.sample(s, so).r, blend);
          cc = mix(cc, cOld.sample(s, so).rg, blend);
        }
        float cb = (cc.r - a.w) * a.z, cr = (cc.g - a.w) * a.z;
        float y = (yv - a.y) * a.x;
        float3 rgb = clamp(float3(y + m.x * cr, y - m.y * cb - m.z * cr, y + m.w * cb), 0.0, 1.0);
        float3 o = lut.sample(s, (rgb * (n - 1.0) + 0.5) / n).rgb;
        o = clamp(prm[4].x * pow(max(o, 0.0), float3(prm[3].w)) * prm[3].rgb, 0.0, 1.0);   // igualar câmeras (lente do quadro)
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
      let pipeline = try? device.makeComputePipelineState(function: fn), let sf = library.makeFunction(name: "streak"),
      let streakPipeline = try? device.makeComputePipelineState(function: sf) else { return nil }
    self.device = device; self.queue = queue; self.pipeline = pipeline; self.streakPipeline = streakPipeline; self.lutN = size
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
    pool = p; dims = (w, h); format = nil; tmp = nil
  }
  // texturas do meio do rastro em duas etapas (só criadas no 1º movimento rápido; mesmo tamanho da saída)
  private func streakTextures(_ w: Int, _ h: Int) -> (y: MTLTexture, c: MTLTexture)? {
    if let tmp { return tmp }
    let dy = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r16Unorm, width: w, height: h, mipmapped: false)
    dy.usage = [.shaderRead, .shaderWrite]; dy.storageMode = .private
    let dc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rg16Unorm, width: (w + 1) / 2, height: (h + 1) / 2, mipmapped: false)
    dc.usage = [.shaderRead, .shaderWrite]; dc.storageMode = .private
    guard let ty = device.makeTexture(descriptor: dy), let tc = device.makeTexture(descriptor: dc) else { return nil }
    tmp = (ty, tc); return tmp
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
  static let tenBit: Set<OSType> = [kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange]
  static let eightBit: Set<OSType> = [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange]
  static let fullRange: Set<OSType> = [kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange]
  static let is422: Set<OSType> = [kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr10BiPlanarFullRange, kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_422YpCbCr8BiPlanarFullRange]
  // o formato dos quadros que a câmera vai entregar é conferido ANTES de gravar: sem suporte, o arquivo sobe como Log
  static func supports(_ f: OSType) -> Bool { tenBit.contains(f) || eightBit.contains(f) }

  // quadro convertido com o mesmo tempo do original; nil = não deu (quem chama grava o original e conta a falha)
  // stages = (n1, n2): n2 > 1 = rastro em duas etapas; old/blend/oldGeo = dissolve da troca de lente parada
  func convert(_ sample: CMSampleBuffer, match: LensCorrection = .identity, geo: SwitchGeometry = .identity, blur: BlurParams = .none, stages: (Int, Int) = (1, 1),
               old: CVPixelBuffer? = nil, blend: Float = 0, oldGeo: SwitchGeometry = .identity) -> CMSampleBuffer? {
    guard let src = CMSampleBufferGetImageBuffer(sample) else { return fail("sem imagem") }
    let fmt = CVPixelBufferGetPixelFormatType(src)
    let ten = Self.tenBit.contains(fmt), eight = Self.eightBit.contains(fmt)
    guard ten || eight, CVPixelBufferGetPlaneCount(src) == 2 else { return fail("formato \(fmt)") }
    let full = Self.fullRange.contains(fmt), four22 = Self.is422.contains(fmt)
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
    // quadro da lente velha (dissolve): mesmo formato da fonte; sem ele, a própria fonte ocupa o lugar (peso 0)
    var oldTex: (CVMetalTexture, CVMetalTexture)?
    if let old, blend > 0, CVPixelBufferGetPixelFormatType(old) == fmt, CVPixelBufferGetWidth(old) == w, CVPixelBufferGetHeight(old) == h,
      let a = texture(old, plane: 0, format: pf.0, write: false), let b = texture(old, plane: 1, format: pf.1, write: false) { oldTex = (a, b) }
    let yOld = oldTex.flatMap { CVMetalTextureGetTexture($0.0) } ?? yIn, cOld = oldTex.flatMap { CVMetalTextureGetTexture($0.1) } ?? cIn
    let useBlend: Float = oldTex != nil ? max(0, min(1, blend)) : 0
    // faixa da fonte (normalizada pelo máximo do código) e matriz: Rec.2020 nas fontes 10 bits (Log/HLG), Rec.709 no SDR
    let maxCode: Float = ten ? 1023 : 255
    let center: Float = (ten ? 512 : 128) / maxCode
    var range = SIMD4<Float>(1, 0, 1, center)
    if !full && ten { range = SIMD4<Float>(1023.0 / 876.0, 64.0 / 1023.0, 1023.0 / 896.0, 512.0 / 1023.0) }
    if !full && !ten { range = SIMD4<Float>(255.0 / 219.0, 16.0 / 255.0, 255.0 / 224.0, 128.0 / 255.0) }
    let rec2020 = SIMD4<Float>(1.4746, 0.16455, 0.57135, 1.8814), rec709 = SIMD4<Float>(1.5748, 0.1873, 0.4681, 1.8556)
    let matrix = ten ? rec2020 : rec709
    let n1 = blur.active ? max(1, stages.0) : 1, n2 = blur.active ? max(1, stages.1) : 1
    let geoV = SIMD4<Float>(geo.s, geo.tx, geo.ty, geo.cover), oldV = SIMD4<Float>(oldGeo.s, oldGeo.tx, oldGeo.ty, oldGeo.cover)
    let base: [SIMD4<Float>] = [range, matrix, SIMD4(Float(lutN), four22 ? 1 : 2, 0, 0), SIMD4(match.gain.x, match.gain.y, match.gain.z, match.gamma), SIMD4(match.scale, 0, 0, 0)]
    guard let cb = queue.makeCommandBuffer() else { return fail("comando") }
    let tg = MTLSize(width: 16, height: 16, depth: 1), grid = MTLSize(width: cOut.width, height: cOut.height, depth: 1)
    var bakeY = yIn, bakeC = cIn
    var prm: [SIMD4<Float>]
    if n2 > 1, let t = streakTextures(w, h) {
      // 1ª etapa: caminho inteiro com n1 leituras (com ruído) -> textura do meio, já na geometria da saída
      var p1 = base + [geoV, SIMD4(Float(blur.zoom), Float(blur.mx), Float(blur.my), Float(n1)), SIMD4(Float(blur.roll), 0, 1, 0), oldV]
      guard let e1 = cb.makeComputeCommandEncoder() else { return fail("comando") }
      e1.setComputePipelineState(streakPipeline)
      e1.setTexture(yIn, index: 0); e1.setTexture(cIn, index: 1); e1.setTexture(t.y, index: 2); e1.setTexture(t.c, index: 3)
      e1.setBytes(&p1, length: MemoryLayout<SIMD4<Float>>.stride * p1.count, index: 0)
      e1.dispatchThreads(grid, threadsPerThreadgroup: tg)
      e1.endEncoding()
      // 2ª etapa: o passo da 1ª com n2 leituras, sem geometria (a textura do meio já está no quadro da saída)
      let k = Float(n1)
      prm = base + [SIMD4<Float>(1, 0, 0, 1), SIMD4(Float(blur.zoom) / k, Float(blur.mx) / k, Float(blur.my) / k, Float(n2)), SIMD4(Float(blur.roll) / k, useBlend, 0, 0), oldV]
      bakeY = t.y; bakeC = t.c
    } else {
      prm = base + [geoV, SIMD4(Float(blur.zoom), Float(blur.mx), Float(blur.my), Float(n1)), SIMD4(Float(blur.roll), useBlend, 1, 0), oldV]
    }
    guard let enc = cb.makeComputeCommandEncoder() else { return fail("comando") }
    enc.setComputePipelineState(pipeline)
    enc.setTexture(bakeY, index: 0); enc.setTexture(bakeC, index: 1); enc.setTexture(lut, index: 2); enc.setTexture(yOut, index: 3); enc.setTexture(cOut, index: 4)
    enc.setTexture(yOld, index: 5); enc.setTexture(cOld, index: 6)
    enc.setBytes(&prm, length: MemoryLayout<SIMD4<Float>>.stride * prm.count, index: 0)
    enc.dispatchThreads(grid, threadsPerThreadgroup: tg)
    enc.endEncoding()
    cb.commit(); cb.waitUntilCompleted()
    _ = (ty, tc, oy, oc, oldTex)   // texturas vivas até a GPU terminar
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
