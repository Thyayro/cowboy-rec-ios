import Accelerate
import CoreMedia
import Foundation

// REDUTOR DE RUÍDO que não distorce: subtração espectral suave (tipo Wiener) com PISO — o ruído de fundo (chiado, vento leve,
// ar-condicionado, rua) é estimado continuamente por faixa de frequência (rastreio de mínimo) e cada faixa só é ABAIXADA até
// um limite: leve −6 dB, médio −12 dB, pesado −18 dB. Nunca zera (zerar é o que dá som "metálico"/"de água"), o ganho é
// suavizado no tempo e entre faixas vizinhas, e a voz (bem acima do ruído) passa com ganho 1. FFT 1024 / salto 512 com janela
// raiz-de-Hann (reconstrução perfeita); o atraso de 512 amostras é descontado no horário do áudio (continua em sincronia).
final class NoiseReducer: @unchecked Sendable {
  enum Level: Int, CaseIterable { case off = 0, light, medium, heavy
    var label: String { ["Desligado", "Leve", "Médio", "Pesado"][rawValue] }
    var floor: Float { [1, 0.5, 0.25, 0.125][rawValue] }
    var over: Float { [0, 1.0, 1.4, 1.9][rawValue] }
  }
  private let n = 1024, hop = 512
  private let log2n = vDSP_Length(10)
  private let fft: FFTSetup
  private var window = [Float]()
  private final class Channel {
    var ring = [Float](repeating: 0, count: 1024)      // últimas n amostras de entrada (circular)
    var pos = 0
    var fill = 512                                       // amostras novas desde o último quadro de análise
    var outAcc = [Float](repeating: 0, count: 1024)    // soma das janelas (overlap-add)
    var ready = [Float]()                                // saída pronta, na ordem
    var noise = [Float](repeating: 0, count: 513)
    var gain = [Float](repeating: 1, count: 513)
    var frames = 0
  }
  private var channels: [Channel] = []
  private let lock = NSLock()
  private var level: Level
  var latencySeconds: Double { Double(hop) / sampleRate }
  private var sampleRate = 48000.0

  init(level: Level) {
    self.level = level
    fft = vDSP_create_fftsetup(10, FFTRadix(kFFTRadix2))!
    window = (0..<n).map { i in Float(sin(Double.pi * (Double(i) + 0.5) / Double(n))) }   // raiz de Hann (sin)
  }
  deinit { vDSP_destroy_fftsetup(fft) }
  func setLevel(_ l: Level) { lock.lock(); level = l; lock.unlock() }
  var current: Level { lock.lock(); defer { lock.unlock() }; return level }

  // processa um quadro de análise de um canal (inBuf completo) e acumula a saída
  private func analyze(_ c: Channel, _ lv: Level) {
    var re = [Float](repeating: 0, count: n / 2), im = [Float](repeating: 0, count: n / 2)
    var x = [Float](repeating: 0, count: n)
    var lin = [Float](repeating: 0, count: n)
    for i in 0..<n { lin[i] = c.ring[(c.pos + i) & (n - 1)] }   // mais antiga primeiro
    vDSP_vmul(lin, 1, window, 1, &x, 1, vDSP_Length(n))
    re.withUnsafeMutableBufferPointer { rp in im.withUnsafeMutableBufferPointer { ip in
      var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
      x.withUnsafeBufferPointer { xp in xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ctoz($0, 2, &split, 1, vDSP_Length(n / 2)) } }
      vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_FORWARD))
      // potência por faixa (0 = DC em re[0], 512 = Nyquist em im[0])
      var p = [Float](repeating: 0, count: n / 2 + 1)
      p[0] = rp[0] * rp[0]; p[n / 2] = ip[0] * ip[0]
      for k in 1..<(n / 2) { p[k] = rp[k] * rp[k] + ip[k] * ip[k] }
      // ruído: desce rápido até o mínimo, sobe devagar (~2 dB/s) — fala não "puxa" a estimativa
      for k in 0...(n / 2) {
        if c.frames == 0 || p[k] < c.noise[k] { c.noise[k] = c.frames == 0 ? p[k] : 0.8 * c.noise[k] + 0.2 * p[k] }
        else { c.noise[k] *= 1.005 }
      }
      c.frames += 1
      var g = [Float](repeating: 1, count: n / 2 + 1)
      if lv != .off && c.frames > 8 {
        for k in 0...(n / 2) {
          let snr = c.noise[k] / max(p[k], 1e-12)
          let target = max(lv.floor, 1 - lv.over * snr)
          // sobe rápido (fala entra inteira), desce devagar (sem "bombear")
          g[k] = target > c.gain[k] ? target : max(target, c.gain[k] * 0.86)
        }
        // suaviza entre faixas vizinhas (sem tom "metálico")
        var sm = g
        for k in 1..<(n / 2) { sm[k] = 0.25 * g[k - 1] + 0.5 * g[k] + 0.25 * g[k + 1] }
        g = sm.map { max(lv.floor, min(1, $0)) }
        c.gain = g
      } else { c.gain = [Float](repeating: 1, count: n / 2 + 1) }
      rp[0] *= g[0]; ip[0] *= g[n / 2]
      for k in 1..<(n / 2) { rp[k] *= g[k]; ip[k] *= g[k] }
      vDSP_fft_zrip(fft, &split, 1, log2n, FFTDirection(FFT_INVERSE))
      x.withUnsafeMutableBufferPointer { xp in xp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(n / 2)) } }
    } }
    var scale = 1 / Float(2 * n)
    var y = [Float](repeating: 0, count: n), z = [Float](repeating: 0, count: n)
    vDSP_vsmul(x, 1, &scale, &y, 1, vDSP_Length(n))
    vDSP_vmul(y, 1, window, 1, &z, 1, vDSP_Length(n))
    let acc = c.outAcc
    var sum = [Float](repeating: 0, count: n)
    vDSP_vadd(acc, 1, z, 1, &sum, 1, vDSP_Length(n))
    c.outAcc = sum
    // os primeiros "hop" estão completos -> saem
    c.ready.append(contentsOf: c.outAcc[0..<hop])
    c.outAcc.removeFirst(hop); c.outAcc.append(contentsOf: [Float](repeating: 0, count: hop))
  }
  private func push(_ c: Channel, _ samples: ArraySlice<Float>, _ lv: Level) -> [Float] {
    var out = [Float](); out.reserveCapacity(samples.count)
    for s in samples {
      c.ring[c.pos] = s; c.pos = (c.pos + 1) & (n - 1); c.fill += 1
      if c.fill >= hop { c.fill = 0; analyze(c, lv) }
    }
    let take = min(samples.count, c.ready.count)
    out.append(contentsOf: c.ready[0..<take]); c.ready.removeFirst(take)
    if out.count < samples.count { out.append(contentsOf: [Float](repeating: 0, count: samples.count - out.count)) }
    return out
  }

  // amostra de áudio da câmera -> mesma amostra processada (mesmo formato), horário recuado pelo atraso
  func process(_ sample: CMSampleBuffer) -> CMSampleBuffer? {
    lock.lock(); let lv = level; lock.unlock()
    guard lv != .off, let desc = CMSampleBufferGetFormatDescription(sample), let asbdP = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return nil }
    let asbd = asbdP.pointee
    let isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, bits = Int(asbd.mBitsPerChannel)
    let interleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    let ch = Int(asbd.mChannelsPerFrame)
    guard asbd.mFormatID == kAudioFormatLinearPCM, ch >= 1, ch <= 8, (isFloat && bits == 32) || (!isFloat && bits == 16), interleaved || ch == 1 else { return nil }
    sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
    guard let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
    let length = CMBlockBufferGetDataLength(block)
    var bytes = [UInt8](repeating: 0, count: length)
    guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &bytes) == noErr else { return nil }
    let frames = CMSampleBufferGetNumSamples(sample)
    guard frames > 0, length >= frames * ch * bits / 8 else { return nil }
    if channels.count != ch { channels = (0..<ch).map { _ in Channel() } }
    // separa canais em Float
    var planes = [[Float]](repeating: [Float](repeating: 0, count: frames), count: ch)
    bytes.withUnsafeBytes { raw in
      if isFloat { let p = raw.bindMemory(to: Float.self); for i in 0..<frames { for c in 0..<ch { planes[c][i] = p[i * ch + c] } } }
      else { let p = raw.bindMemory(to: Int16.self); for i in 0..<frames { for c in 0..<ch { planes[c][i] = Float(p[i * ch + c]) / 32768 } } }
    }
    let outPlanes = (0..<ch).map { push(channels[$0], planes[$0][...], lv) }
    bytes.withUnsafeMutableBytes { raw in
      if isFloat { let p = raw.bindMemory(to: Float.self); for i in 0..<frames { for c in 0..<ch { p[i * ch + c] = outPlanes[c][i] } } }
      else { let p = raw.bindMemory(to: Int16.self); for i in 0..<frames { for c in 0..<ch { p[i * ch + c] = Int16(max(-32768, min(32767, (outPlanes[c][i] * 32768).rounded()))) } } }
    }
    var newBlock: CMBlockBuffer?
    guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: nil, customBlockSource: nil, offsetToData: 0, dataLength: length, flags: 0, blockBufferOut: &newBlock) == noErr, let newBlock,
      bytes.withUnsafeBytes({ CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: newBlock, offsetIntoDestination: 0, dataLength: length) }) == noErr else { return nil }
    let pts = CMTimeSubtract(CMSampleBufferGetPresentationTimeStamp(sample), CMTime(value: CMTimeValue(hop), timescale: CMTimeScale(sampleRate)))
    var out: CMSampleBuffer?
    guard CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: newBlock, formatDescription: desc, sampleCount: frames, presentationTimeStamp: pts, packetDescriptions: nil, sampleBufferOut: &out) == noErr else { return nil }
    return out
  }
}
