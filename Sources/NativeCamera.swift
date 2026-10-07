import AVFoundation
import Combine
import CoreImage
import QuartzCore
import SwiftUI
import UIKit
import UniformTypeIdentifiers
import VideoToolbox

// Gravador: (1) NUVEM — AVAssetWriter no perfil HLS fMP4 entrega init + um fragmento por segundo em memória, cada um vai
// direto pra fila de envio (CloudStream); (2) ARQUIVO — se o iPhone recusar o modo fragmentado, grava um .mov no aparelho
// (fragmentado a cada 2 s, sobrevive a travamento) que sobe ao parar. Toda chamada que o AVFoundation pode recusar com
// exceção passa pelo CowboyObjC.catching: vira mensagem, o app não fecha.
final class SegmentWriter: NSObject, AVAssetWriterDelegate, @unchecked Sendable {
  private let writer: AVAssetWriter
  private let video: AVAssetWriterInput
  private var audio: AVAssetWriterInput?
  private var start: CMTime?
  let fileURL: URL?
  private(set) var dropped = 0
  private(set) var error: String?
  var onSegment: ((Data) -> Void)?
  static func make(video videoSettings: [String: Any], audio audioSettings: [String: Any]?, transform: CGAffineTransform, file: URL?) throws -> SegmentWriter {
    var made: SegmentWriter?
    var thrown: Error?
    let ex = CowboyObjC.catching {
      do { made = try SegmentWriter(video: videoSettings, audio: audioSettings, transform: transform, file: file) } catch { thrown = error }
    }
    if let ex { throw NSError(domain: "CowboyWriter", code: 2, userInfo: [NSLocalizedDescriptionKey: ex]) }
    if let thrown { throw thrown }
    guard let made else { throw NSError(domain: "CowboyWriter", code: 3, userInfo: [NSLocalizedDescriptionKey: "gravador não criado"]) }
    return made
  }
  private init(video videoSettings: [String: Any], audio audioSettings: [String: Any]?, transform: CGAffineTransform, file: URL?) throws {
    fileURL = file
    if let file {
      writer = try AVAssetWriter(outputURL: file, fileType: .mov)
      writer.movieFragmentInterval = CMTime(seconds: 2, preferredTimescale: 600)
    } else {
      writer = AVAssetWriter(contentType: UTType(AVFileType.mp4.rawValue) ?? .mpeg4Movie)
      writer.outputFileTypeProfile = .mpeg4AppleHLS
      writer.preferredOutputSegmentInterval = CMTime(seconds: 1, preferredTimescale: 600)
    }
    video = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
    video.expectsMediaDataInRealTime = true
    video.transform = transform
    guard writer.canAdd(video) else { throw NSError(domain: "CowboyWriter", code: 1, userInfo: [NSLocalizedDescriptionKey: "O iPhone recusou o formato de vídeo do gravador"]) }
    writer.add(video)
    if let audioSettings {
      let a = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
      a.expectsMediaDataInRealTime = true
      if writer.canAdd(a) { writer.add(a); audio = a }
    }
    super.init()
    if file == nil { writer.delegate = self }
  }
  var hasAudio: Bool { audio != nil }
  var started: Bool { start != nil }
  var failed: String? { error ?? (writer.status == .failed ? (writer.error?.localizedDescription ?? "falhou") : nil) }
  func appendVideo(_ sample: CMSampleBuffer) {
    guard error == nil else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(sample)
    if start == nil {
      var ok = false
      let ex = CowboyObjC.catching {
        if self.fileURL == nil { self.writer.initialSegmentStartTime = pts }
        ok = self.writer.startWriting()
        if ok { self.writer.startSession(atSourceTime: pts) }
      }
      if let ex { error = ex; return }
      guard ok else { error = writer.error?.localizedDescription ?? "não começou a gravar"; return }
      start = pts
    }
    guard writer.status == .writing else { return }
    if video.isReadyForMoreMediaData {
      var appended = false
      if let ex = CowboyObjC.catching({ appended = self.video.append(sample) }) { error = ex; return }
      if !appended { dropped += 1 }
    } else { dropped += 1 }
  }
  func appendAudio(_ sample: CMSampleBuffer) {
    guard error == nil, let start, let audio, writer.status == .writing, CMSampleBufferGetPresentationTimeStamp(sample) >= start, audio.isReadyForMoreMediaData else { return }
    if let ex = CowboyObjC.catching({ _ = audio.append(sample) }) { error = ex }
  }
  func finish(_ done: @escaping @Sendable (Bool) -> Void) {
    guard start != nil, writer.status == .writing else { _ = CowboyObjC.catching { self.writer.cancelWriting() }; done(false); return }
    let w = writer
    let ex = CowboyObjC.catching {
      self.video.markAsFinished(); self.audio?.markAsFinished()
      w.finishWriting { done(w.status == .completed) }
    }
    if ex != nil { done(false) }
  }
  func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
    onSegment?(segmentData)
  }
}

// All device/session operations are serialized on `queue`; frames/audio on `dataQueue`. Published UI state goes to main.
final class NativeCamera: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
  let session = AVCaptureSession()
  let renderer = PreviewRenderer()
  private let queue = DispatchQueue(label: "cowboy.native.camera", qos: .userInitiated)
  private let dataQueue = DispatchQueue(label: "cowboy.native.data", qos: .userInteractive)
  private let videoOut = AVCaptureVideoDataOutput()
  private let audioOut = AVCaptureAudioDataOutput()
  private var device: AVCaptureDevice?
  private var base: CGFloat = 1
  private var configured = false
  private var zoomObservation: NSKeyValueObservation?
  private var rotationObservation: NSKeyValueObservation?
  private var rotation: AVCaptureDevice.RotationCoordinator?
  private var selectedProfile = NativeCaptureProfile.main
  private var requestedHDR = false
  private var requestedLog = UserDefaults.standard.bool(forKey: "log")
  private var requestedCodec = AVVideoCodecType.hevc
  private var availableDevices: [AVCaptureDevice] = []
  private var previewAngle: Double = 90
  private var telemetry: DispatchSourceTimer?
  // gravação (somente dataQueue)
  private var writer: SegmentWriter?
  private var recCid: String?
  private var recOwner: String?
  private var recStart: CMTime?
  private var recAngle: Double = 90
  private var recFront = false
  private var thumbDone = true
  private var gyro: GyroLog?
  private var lastPublish = 0.0
  private var recovering = Set<URL>()
  private var elapsedMs = 0

  struct Lens: Identifiable, Sendable { let id: String; let name: String }
  @Published var lenses: [Lens] = []
  @Published var lensID = ""
  @Published var lensName = "Traseira 0,5–5×"
  @Published var profiles: [NativeCaptureProfile] = []
  @Published var profileID = NativeCaptureProfile.main.id
  @Published var formatLabel = "Aguardando câmera"
  @Published var formatShort = "4K · 60"
  @Published var hdrAvailable = false
  @Published var hdrEnabled = false
  @Published var logAvailable = false
  @Published var logEnabled = false
  @Published var convertRec709 = UserDefaults.standard.object(forKey: "conv709") as? Bool ?? true { didSet { UserDefaults.standard.set(convertRec709, forKey: "conv709") } }
  @Published var codecs: [String] = []
  @Published var codec = "hvc1"
  @Published var torchAvailable = false
  @Published var torchEnabled = false
  @Published var focusAvailable = false
  @Published var manualFocus = false
  @Published var lensPosition: Double = 0
  @Published var exposureAvailable = false
  @Published var manualExposure = false
  @Published var iso: Double = 100
  @Published var minISO: Double = 20
  @Published var maxISO: Double = 2000
  @Published var shutter: Double = 120
  @Published var minShutter: Double = 60
  @Published var maxShutter: Double = 8000
  @Published var exposureBias: Double = 0
  @Published var minExposureBias: Double = -2
  @Published var maxExposureBias: Double = 2
  @Published var whiteBalanceAvailable = false
  @Published var manualWhiteBalance = false
  @Published var temperature: Double = 5000
  @Published var status = "Câmera aguardando permissão"
  @Published var ready = false
  @Published var recording = false
  @Published var finishing = false
  @Published var elapsed: Double = 0
  @Published var zoom: Double = 1
  @Published var minimumZoom: Double = 0.5
  @Published var maximumZoom: Double = 10
  @Published var zoomPresets: [Double] = [0.5, 1, 2, 5]
  @Published var zoomFactorRaw: Double = 1
  @Published var fieldOfView: Double = 106
  @Published var videoSize = CGSize(width: 2160, height: 3840)   // como aparece na tela
  @Published var front = false
  @Published var activeMode = AVCaptureVideoStabilizationMode.off
  @Published var preferredMode = AVCaptureVideoStabilizationMode.off
  @Published var stabilizationChoice = UserDefaults.standard.object(forKey: "stab") as? Int ?? 4
  @Published var bitrateChoice = UserDefaults.standard.integer(forKey: "bitrate")
  @Published var colorLocked = false
  @Published var lookID = UserDefaults.standard.string(forKey: "look") ?? "natural"
  @Published var rawLog = false
  @Published var droppedFrames = 0
  // Arquivo final: Rec.709 + look convertido NO iPhone a partir do Log real (padrão) ou o Log original (cor na VPS)
  @Published var bake709 = UserDefaults.standard.object(forKey: "bake709") as? Bool ?? true { didSet { UserDefaults.standard.set(bake709, forKey: "bake709") } }
  @Published var lastThumb: UIImage? = UIImage(contentsOfFile: NativeCamera.thumbURL.path)
  static let thumbURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("last_thumb.jpg")
  private var recBaker: LutBaker?
  // parar na hora: o toque derruba a gravação imediatamente (quadros que chegarem depois não entram)
  private let stopLock = NSLock()
  private var stopRequested = false
  // medidor de áudio: pico por canal (dBFS), atualizado ~20×/s, gravando ou não
  @Published var audioLevels: [Float] = [-80]
  @Published var audioPeakHold: [Float] = [-80]
  @Published var audioClip = false
  private var meterAcc: [Float] = []
  private var meterLast = 0.0
  private var holdValues: [Float] = []
  private var holdAt: [Double] = []
  private var clipAt = 0.0
  @Published var recoverableFile: URL?
  var onSaved: ((URL, String?) -> Void)?
  var spaceMeta: (() -> [String: Any])?

  static let bitrates: [(label: String, bps: Int?)] = [("Máxima do iPhone", nil), ("80 Mb/s", 80_000_000), ("50 Mb/s", 50_000_000), ("35 Mb/s", 35_000_000), ("20 Mb/s (4G)", 20_000_000)]

  func start() {
    Task {
      let camera = await AVCaptureDevice.requestAccess(for: .video)
      let audio = await AVCaptureDevice.requestAccess(for: .audio)
      guard camera && audio else { publish { self.status = "Libere câmera e microfone nos Ajustes do iPhone" }; return }
      MotionHub.shared.start()
      queue.async {
        do {
          if !self.configured { try self.guarded { try self.configure() } }
          if !self.session.isRunning { self.session.startRunning() }
          self.configureStabilization()
          self.startTelemetry()
          self.publish { self.ready = true }
        } catch { self.publish { self.status = error.localizedDescription } }
      }
    }
  }
  private func publish(_ action: @escaping @Sendable () -> Void) { DispatchQueue.main.async(execute: action) }
  private func failure(_ message: String) -> NSError { NSError(domain: "CowboyCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }

  // ---- estabilização: 0 desligada · 1 standard · 2 cinematic · 3 cinematic extended · 4 EXTREMA (cinematicExtendedEnhanced, iOS 18)
  static func mode(for choice: Int) -> AVCaptureVideoStabilizationMode {
    switch choice {
    case 0: return .off
    case 1: return .standard
    case 2: return .cinematic
    case 3: return .cinematicExtended
    default:
      if #available(iOS 18.0, *) { return .cinematicExtendedEnhanced }
      return .cinematicExtended
    }
  }
  static func label(_ mode: AVCaptureVideoStabilizationMode) -> String {
    if #available(iOS 18.0, *), mode == .cinematicExtendedEnhanced { return "Extrema" }
    switch mode {
    case .off: return "Desligada"
    case .standard: return "Standard"
    case .cinematic: return "Cinematic"
    case .cinematicExtended: return "Cinematic Extended"
    case .previewOptimized: return "Prévia"
    case .auto: return "Automática"
    default: return "Sistema"
    }
  }
  private var desired: AVCaptureVideoStabilizationMode { Self.mode(for: stabilizationChoiceValue) }
  private var stabilizationChoiceValue = UserDefaults.standard.object(forKey: "stab") as? Int ?? 4
  private func fallbackChain() -> [AVCaptureVideoStabilizationMode] {
    let want = desired
    if want == .off { return [.off] }
    var chain = [want]
    for m in [Self.mode(for: 4), .cinematicExtended, .cinematic, .standard] where !chain.contains(m) {
      // nunca cai pra cima do pedido: só pra modos mais fracos
      if Self.rank(m) < Self.rank(want) { chain.append(m) }
    }
    return chain + [.off]
  }
  static func rank(_ m: AVCaptureVideoStabilizationMode) -> Int {
    if #available(iOS 18.0, *), m == .cinematicExtendedEnhanced { return 5 }
    switch m { case .cinematicExtended: return 4; case .cinematic: return 3; case .standard: return 2; default: return 0 }
  }

  // ---- formatos
  private func descriptors(_ cam: AVCaptureDevice) -> [NativeFormatDescriptor] {
    cam.formats.enumerated().map { index, f in
      let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
      let sub = CMFormatDescriptionGetMediaSubType(f.formatDescription)
      let ten = sub == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange || sub == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
      return NativeFormatDescriptor(index: index, width: Int(d.width), height: Int(d.height), ranges: f.videoSupportedFrameRateRanges.map { NativeFrameRange(min: $0.minFrameRate, max: $0.maxFrameRate) }, hdr: f.supportedColorSpaces.contains(.HLG_BT2020), stabilized: f.isVideoStabilizationModeSupported(desired), log: f.supportedColorSpaces.contains(.appleLog), tenBit: ten)
    }
  }
  private func name(_ cam: AVCaptureDevice) -> String {
    if cam.position == .front { return "Frontal" }
    switch cam.deviceType {
    case .builtInTripleCamera: return "Traseira 0,5–5× (automática)"
    case .builtInDualWideCamera: return "Traseira 0,5–1× (automática)"
    case .builtInDualCamera: return "Traseira 1–2× (automática)"
    case .builtInWideAngleCamera: return "Só a principal 1×"
    case .builtInUltraWideCamera: return "Só a ultra-angular 0,5×"
    case .builtInTelephotoCamera: return "Só a teleobjetiva"
    default: return "Traseira"
    }
  }
  // 1× = lente principal. Na câmera virtual, fator 1 = ultra-angular (0,5×) e a principal entra no 1º ponto de troca.
  private func displayBase(_ cam: AVCaptureDevice) -> CGFloat {
    if cam.deviceType == .builtInUltraWideCamera { return 2 }
    if cam.isVirtualDevice && cam.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }) {
      return CGFloat(cam.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 2)
    }
    if cam.deviceType == .builtInTelephotoCamera,
      let virtual = availableDevices.first(where: { $0.deviceType == .builtInTripleCamera }),
      let last = virtual.virtualDeviceSwitchOverVideoZoomFactors.last?.doubleValue {
      let main = virtual.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 2
      return CGFloat(main / last)
    }
    return 1
  }
  private func defaultBack() -> AVCaptureDevice? {
    for type in [AVCaptureDevice.DeviceType.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera] {
      if let d = availableDevices.first(where: { $0.position == .back && $0.deviceType == type }) { return d }
    }
    return availableDevices.first { $0.position == .back }
  }
  private func configure(cameraID: String? = nil, profile: NativeCaptureProfile? = nil, hdr: Bool? = nil, codec: AVVideoCodecType? = nil, log: Bool? = nil, zoom: Double? = nil) throws {
    if availableDevices.isEmpty {
      availableDevices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera, .builtInUltraWideCamera, .builtInTelephotoCamera], mediaType: .video, position: .unspecified).devices
      let choices = availableDevices.map { Lens(id: $0.uniqueID, name: name($0)) }
      publish { self.lenses = choices }
    }
    let saved = UserDefaults.standard.string(forKey: "lens")
    let cam = cameraID.flatMap { id in availableDevices.first { $0.uniqueID == id } } ?? device ?? saved.flatMap { id in availableDevices.first { $0.uniqueID == id } } ?? defaultBack()
    guard let cam else { throw failure("Câmera indisponível") }
    var chosen = profile ?? selectedProfile
    var wantsHDR = hdr ?? requestedHDR, wantsLog = log ?? requestedLog
    let encoding = codec ?? requestedCodec
    let catalog = descriptors(cam)
    if wantsLog && !catalog.contains(where: { $0.log }) { wantsLog = false }   // lente/aparelho sem Log: segue sem, avisa no seletor
    if wantsLog { wantsHDR = false }
    if NativeCapturePolicy.select(chosen, hdr: wantsHDR, formats: catalog, log: wantsLog) == nil, profile == nil, cameraID != nil {
      // trocando de câmera: a frontal pode não ter 4K60 — usa o melhor que ela tiver no mesmo qps, senão o melhor geral
      if let best = NativeCapturePolicy.profiles(catalog, hdr: wantsHDR, log: wantsLog).first(where: { abs($0.fps - chosen.fps) < 0.5 }) ?? NativeCapturePolicy.profiles(catalog, hdr: wantsHDR, log: wantsLog).first { chosen = best }
    }
    guard let index = NativeCapturePolicy.select(chosen, hdr: wantsHDR, formats: catalog, log: wantsLog) else {
      throw failure("\(name(cam)) não tem \(chosen.label)\(wantsLog ? " em Apple Log" : wantsHDR ? " HDR" : ""). Escolha outro formato — a qualidade não é reduzida sozinha.")
    }
    if (wantsHDR || wantsLog) && encoding != .hevc { throw failure("HDR/Log exige HEVC") }
    let input = try AVCaptureDeviceInput(device: cam)
    let oldVideo = session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first { $0.device.hasMediaType(.video) }
    let wasConfigured = configured
    session.automaticallyConfiguresCaptureDeviceForWideColor = false
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    try cam.lockForConfiguration()
    defer { cam.unlockForConfiguration() }
    do {
      if let oldVideo { session.removeInput(oldVideo) }
      guard session.canAddInput(input) else { throw failure("Esta câmera não pode ser aberta") }
      session.addInput(input)
      if !wasConfigured {
        guard let mic = AVCaptureDevice.default(for: .audio) else { throw failure("Microfone indisponível") }
        let audio = try AVCaptureDeviceInput(device: mic)
        guard session.canAddInput(audio), session.canAddOutput(videoOut), session.canAddOutput(audioOut) else { throw failure("Gravação indisponível") }
        session.addInput(audio); session.addOutput(videoOut); session.addOutput(audioOut)
        videoOut.alwaysDiscardsLateVideoFrames = false
        videoOut.setSampleBufferDelegate(self, queue: dataQueue)
        audioOut.setSampleBufferDelegate(self, queue: dataQueue)
      }
      session.sessionPreset = .inputPriority
      cam.activeFormat = cam.formats[index]
      let duration = CMTime(seconds: 1 / chosen.fps, preferredTimescale: 600000)
      cam.activeVideoMinFrameDuration = duration; cam.activeVideoMaxFrameDuration = duration
      cam.automaticallyAdjustsVideoHDREnabled = false
      if cam.activeFormat.isVideoHDRSupported { cam.isVideoHDREnabled = wantsHDR }
      if wantsLog { cam.activeColorSpace = .appleLog }
      else if wantsHDR { cam.activeColorSpace = .HLG_BT2020 }
      else if cam.activeFormat.supportedColorSpaces.contains(.sRGB) { cam.activeColorSpace = .sRGB }
      // os quadros chegam no formato nativo do sensor (10 bits no Log/HLG), sem conversão
      let sub = CMFormatDescriptionGetMediaSubType(cam.activeFormat.formatDescription)
      if videoOut.availableVideoPixelFormatTypes.contains(sub) { videoOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: sub] }
      if cam.isVirtualDevice { cam.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: []) }
      let nativeBase = displayBase(cam)
      let relative = zoom ?? (cam.uniqueID == device?.uniqueID ? Double(cam.videoZoomFactor / base) : 1)
      cam.videoZoomFactor = max(cam.minAvailableVideoZoomFactor, min(CGFloat(relative) * nativeBase, cam.maxAvailableVideoZoomFactor))
      if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
      if cam.isSmoothAutoFocusSupported { cam.isSmoothAutoFocusEnabled = true }
      if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
      if cam.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { cam.whiteBalanceMode = .continuousAutoWhiteBalance }
      guard let connection = videoOut.connection(with: .video) else { throw failure("Saída de vídeo indisponível") }
      let isFront = cam.position == .front
      // frontal: o iPhone gira os quadros (mais simples e certo pro espelho); traseira: quadro do sensor + rotação no arquivo
      if isFront, connection.isVideoRotationAngleSupported(previewAngle) { connection.videoRotationAngle = previewAngle }
      else if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
      if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
      zoomObservation?.invalidate(); rotationObservation?.invalidate()
      device = cam; base = nativeBase; selectedProfile = chosen; requestedHDR = wantsHDR; requestedLog = wantsLog; requestedCodec = encoding; configured = true
      UserDefaults.standard.set(cam.uniqueID, forKey: "lens"); UserDefaults.standard.set(wantsLog, forKey: "log")
      DispatchQueue.main.async { self.rotation = AVCaptureDevice.RotationCoordinator(device: cam, previewLayer: nil) }
      renderer.zoomNow = { [weak cam] in cam.map { Double($0.videoZoomFactor) } }
      zoomObservation = cam.observe(\.videoZoomFactor, options: [.initial, .new]) { [weak self] cam, _ in
        guard let self else { return }
        let value = Double(cam.videoZoomFactor / nativeBase), raw = Double(cam.videoZoomFactor)
        self.publish { self.zoom = value; self.zoomFactorRaw = raw }
      }
      let low = Double(cam.minAvailableVideoZoomFactor / nativeBase), high = Double(min(cam.maxAvailableVideoZoomFactor / nativeBase, 25))
      let switches = cam.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue }
      let presets = cam.isVirtualDevice ? ZoomMath.presets(base: Double(nativeBase), switchOvers: switches, minDisplay: low, maxDisplay: high) : [low, 1, 2].filter { $0 >= low - 0.01 && $0 <= high + 0.01 }
      let options = NativeCapturePolicy.profiles(catalog, hdr: wantsHDR, log: wantsLog)
      let hdrOK = catalog.contains { $0.supports(chosen, hdr: true) }
      let logOK = catalog.contains { $0.supports(chosen, hdr: false, log: true) }
      let codecNames = videoOut.availableVideoCodecTypes.filter { $0 == .hevc || $0 == .h264 }.map { $0.rawValue }
      let display = name(cam), minimumISO = Double(cam.activeFormat.minISO), maximumISO = Double(cam.activeFormat.maxISO)
      let exposureMinimum = CMTimeGetSeconds(cam.activeFormat.minExposureDuration)
      let dims = CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription)
      let fov = Double(cam.activeFormat.videoFieldOfView)
      renderer.setOrientation(isFront ? .up : Self.orientation(previewAngle), mirrored: isFront)
      let portrait = isFront ? false : (previewAngle == 90 || previewAngle == 270)
      let shown = portrait ? CGSize(width: Int(dims.height), height: Int(dims.width)) : CGSize(width: Int(dims.width), height: Int(dims.height))
      let frontShown = isFront && (previewAngle == 90 || previewAngle == 270) ? CGSize(width: Int(min(dims.width, dims.height)), height: Int(max(dims.width, dims.height))) : shown
      publish {
        self.minimumZoom = low; self.maximumZoom = high; self.zoomPresets = presets; self.lensID = cam.uniqueID; self.lensName = display
        self.profiles = options; self.profileID = chosen.id; self.formatLabel = chosen.label; self.formatShort = chosen.short
        self.hdrAvailable = hdrOK; self.hdrEnabled = wantsHDR; self.logAvailable = logOK; self.logEnabled = wantsLog
        self.codecs = codecNames; self.codec = encoding.rawValue; self.front = isFront; self.fieldOfView = fov
        self.videoSize = isFront ? frontShown : shown
        self.torchAvailable = cam.hasTorch; self.torchEnabled = cam.torchMode == .on
        self.focusAvailable = cam.isFocusModeSupported(.locked) && cam.isLockingFocusWithCustomLensPositionSupported; self.manualFocus = false
        self.exposureAvailable = cam.isExposureModeSupported(.custom); self.manualExposure = false
        self.minISO = minimumISO; self.maxISO = maximumISO
        self.minShutter = chosen.fps; self.maxShutter = max(chosen.fps, 1 / max(exposureMinimum, 0.000001))
        self.minExposureBias = Double(cam.minExposureTargetBias); self.maxExposureBias = Double(cam.maxExposureTargetBias)
        self.whiteBalanceAvailable = cam.isWhiteBalanceModeSupported(.locked); self.manualWhiteBalance = false; self.colorLocked = false
        self.refreshLook()
      }
      configureStabilization()
    } catch {
      session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.video) }.forEach { session.removeInput($0) }
      if let oldVideo, session.canAddInput(oldVideo) { session.addInput(oldVideo) }
      throw error
    }
  }
  static func orientation(_ angle: Double) -> CGImagePropertyOrientation {
    switch Int(angle) { case 0: return .up; case 180: return .down; case 270: return .left; default: return .right }
  }
  private func reconfigure(_ action: @escaping @Sendable () throws -> Void) {
    queue.async {
      guard !self.isRecording else { self.publish { self.status = "Pare a gravação antes de trocar câmera, formato ou codec" }; return }
      self.publish { self.ready = false }
      self.renderer.freeze()
      do { try self.guarded(action); self.publish { self.ready = self.session.isRunning } }
      catch { Diag.step("config-fail", ["err": error.localizedDescription]); self.publish { self.ready = self.session.isRunning; self.status = error.localizedDescription } }
      self.renderer.thaw()
    }
  }
  // o AVFoundation recusa configuração inválida com exceção (fecharia o app): vira erro comum
  private func guarded(_ action: () throws -> Void) throws {
    var thrown: Error?
    if let ex = CowboyObjC.catching({ do { try action() } catch { thrown = error } }) { throw failure(ex) }
    if let thrown { throw thrown }
  }
  private var isRecording: Bool { dataQueue.sync { writer != nil } }
  func selectLens(_ id: String) { reconfigure { try self.configure(cameraID: id) } }
  func flip() {
    reconfigure {
      let goFront = self.device?.position != .front
      let target = goFront ? self.availableDevices.first { $0.position == .front } : self.defaultBack()
      guard let target else { throw self.failure("Câmera indisponível") }
      try self.configure(cameraID: target.uniqueID, zoom: 1)
    }
  }
  func selectProfile(_ id: String) {
    reconfigure {
      guard let cam = self.device, let p = NativeCapturePolicy.profiles(self.descriptors(cam), hdr: self.requestedHDR, log: self.requestedLog).first(where: { $0.id == id }) else { throw self.failure("Formato indisponível") }
      try self.configure(profile: p)
    }
  }
  func setHDR(_ enabled: Bool) { reconfigure { try self.configure(hdr: enabled, log: false) } }
  func setLog(_ enabled: Bool) { reconfigure { try self.configure(hdr: false, log: enabled) } }
  func setCodec(_ value: String) { reconfigure { try self.configure(codec: AVVideoCodecType(rawValue: value)) } }
  func setStabilization(_ value: Int) {
    UserDefaults.standard.set(value, forKey: "stab")
    queue.async {
      self.stabilizationChoiceValue = value
      self.publish { self.stabilizationChoice = value }
      guard !self.isRecording, let cam = self.device else { return }
      // o formato atual pode não ter o modo pedido no mesmo 4K/60: procura um formato idêntico que tenha
      if let idx = NativeCapturePolicy.select(self.selectedProfile, hdr: self.requestedHDR, formats: self.descriptors(cam), log: self.requestedLog), cam.formats[idx] != cam.activeFormat {
        do { try self.configure(profile: self.selectedProfile) } catch { self.publish { self.status = error.localizedDescription } }
      } else { self.configureStabilization() }
    }
  }
  func setBitrate(_ value: Int) { UserDefaults.standard.set(value, forKey: "bitrate"); publish { self.bitrateChoice = value } }
  // interface girou (retrato/deitado): a prévia acompanha; o arquivo usa o ângulo do horizonte travado ao começar
  func setPreviewAngle(_ angle: Double) {
    queue.async {
      guard self.previewAngle != angle else { return }
      self.previewAngle = angle
      guard let cam = self.device else { return }
      let isFront = cam.position == .front
      if isFront, !self.isRecording, let c = self.videoOut.connection(with: .video), c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
      self.renderer.setOrientation(isFront ? .up : Self.orientation(angle), mirrored: isFront)
      let dims = CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription)
      let portrait = angle == 90 || angle == 270
      let long = Int(max(dims.width, dims.height)), short = Int(min(dims.width, dims.height))
      self.publish { self.videoSize = portrait ? CGSize(width: short, height: long) : CGSize(width: long, height: short) }
    }
  }
  private func configureStabilization() {
    guard let cam = device, let connection = videoOut.connection(with: .video) else { return }
    let mode = fallbackChain().first { cam.activeFormat.isVideoStabilizationModeSupported($0) } ?? .off
    if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = mode }
    let actual = connection.activeVideoStabilizationMode
    let description = "\(name(cam)) · \(selectedProfile.label)\(requestedLog ? " · Apple Log" : requestedHDR ? " · HDR" : "") · estabilização \(Self.label(mode))"
    publish { self.preferredMode = mode; self.activeMode = actual; self.status = description }
  }

  // ---- LUT da prévia
  func setLook(_ id: String) { lookID = id; UserDefaults.standard.set(id, forKey: "look"); refreshLook() }
  func setRawLog(_ value: Bool) { rawLog = value; refreshLook() }
  func refreshLook() {
    let source: SourceColor = logEnabled ? .appleLog : hdrEnabled ? .hlg : .sdr
    let look = LookPreset.named(lookID), raw = rawLog
    DispatchQueue.global(qos: .userInitiated).async {
      if let fn = ColorMath.previewTransform(source: source, rawLog: raw, look: look) {
        let floats = ColorMath.cubeFloats(size: 33, fn)
        self.renderer.setCube(floats.withUnsafeBufferPointer { Data(buffer: $0) }, size: 33)
      } else { self.renderer.setCube(nil, size: 33) }
    }
  }

  // ---- zoom: rampa da própria câmera (atravessa 0,5 → 1 → 5 sem trocar de câmera, sem pulo)
  func rampZoom(to display: Double, seconds: Double = 0.38) {
    queue.async {
      guard let cam = self.device else { return }
      do {
        try cam.lockForConfiguration(); defer { cam.unlockForConfiguration() }
        let target = max(cam.minAvailableVideoZoomFactor, min(CGFloat(display) * self.base, cam.maxAvailableVideoZoomFactor))
        let rate = ZoomMath.rampRate(from: Double(cam.videoZoomFactor), to: Double(target), seconds: seconds)
        _ = CowboyObjC.catching { cam.ramp(toVideoZoomFactor: target, withRate: Float(rate)) }
      } catch { self.publish { self.status = error.localizedDescription } }
    }
  }
  // pinça/roda: segue o dedo com uma rampa rápida (suaviza sem atraso perceptível)
  func followZoom(_ display: Double) { rampZoom(to: display, seconds: 0.06) }
  func selectZoom(_ value: Double) { rampZoom(to: value) }
  func setZoom(_ value: Double) { followZoom(value) }

  private func startTelemetry() {
    guard telemetry == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: .seconds(1))
    timer.setEventHandler { [weak self] in
      guard let self, let cam = self.device, self.session.isRunning else { return }
      let iso = Double(cam.iso), shutter = 1 / max(0.000001, CMTimeGetSeconds(cam.exposureDuration)), position = Double(cam.lensPosition), bias = Double(cam.exposureTargetBias)
      var temp = self.temperature
      _ = CowboyObjC.catching {
        var g = cam.deviceWhiteBalanceGains; let mx = cam.maxWhiteBalanceGain
        guard g.redGain.isFinite, g.greenGain.isFinite, g.blueGain.isFinite, mx >= 1 else { return }
        g.redGain = max(1, min(mx, g.redGain)); g.greenGain = max(1, min(mx, g.greenGain)); g.blueGain = max(1, min(mx, g.blueGain))
        temp = Double(cam.temperatureAndTintValues(for: g).temperature)
      }
      let actual = self.videoOut.connection(with: .video)?.activeVideoStabilizationMode ?? .off
      self.publish { self.iso = iso; self.shutter = shutter; self.lensPosition = position; self.exposureBias = bias; self.temperature = temp; self.activeMode = actual }
    }
    telemetry = timer; timer.resume()
  }
  func lockColor(_ locked: Bool) {
    control { cam in
      if locked {
        if cam.isExposureModeSupported(.locked) { cam.exposureMode = .locked }
        if cam.isWhiteBalanceModeSupported(.locked) { cam.whiteBalanceMode = .locked }
      } else {
        if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
        if cam.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { cam.whiteBalanceMode = .continuousAutoWhiteBalance }
      }
      self.publish { self.colorLocked = locked; self.manualExposure = false; self.manualWhiteBalance = false }
    }
  }
  private func control(_ action: @escaping @Sendable (AVCaptureDevice) throws -> Void) {
    queue.async {
      guard let cam = self.device, self.session.isRunning else { return }
      do { try cam.lockForConfiguration(); defer { cam.unlockForConfiguration() }; try self.guarded { try action(cam) } }
      catch { Diag.step("control-fail", ["err": error.localizedDescription]); self.publish { self.status = error.localizedDescription } }
    }
  }
  func setTorch(_ enabled: Bool) {
    control { cam in
      guard cam.hasTorch, cam.isTorchAvailable else { throw self.failure("Lanterna indisponível nesta câmera") }
      if enabled { try cam.setTorchModeOn(level: AVCaptureDevice.maxAvailableTorchLevel) } else { cam.torchMode = .off }
      self.publish { self.torchEnabled = enabled }
    }
  }
  func setFocus(_ manual: Bool, position: Double? = nil) {
    control { cam in
      if manual {
        guard cam.isFocusModeSupported(.locked), cam.isLockingFocusWithCustomLensPositionSupported else { throw self.failure("Foco manual indisponível nesta lente") }
        cam.setFocusModeLocked(lensPosition: Float(max(0, min(1, position ?? Double(cam.lensPosition)))), completionHandler: nil)
      } else if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
      self.publish { self.manualFocus = manual; if let position { self.lensPosition = max(0, min(1, position)) } }
    }
  }
  // ponto na imagem mostrada (0–1 em x/y da tela) -> ponto do sensor
  func focusAt(normalized p: CGPoint) {
    let angle = previewAngle, isFront = front
    let point: CGPoint
    if isFront { point = CGPoint(x: p.y, y: p.x) }
    else {
      switch Int(angle) {
      case 0: point = p
      case 180: point = CGPoint(x: 1 - p.x, y: 1 - p.y)
      case 270: point = CGPoint(x: 1 - p.y, y: p.x)
      default: point = CGPoint(x: p.y, y: 1 - p.x)
      }
    }
    control { cam in
      if cam.isFocusPointOfInterestSupported && cam.isFocusModeSupported(.autoFocus) {
        cam.focusPointOfInterest = point; cam.focusMode = .autoFocus
        self.publish { self.manualFocus = false }
      }
      if cam.isExposurePointOfInterestSupported && cam.exposureMode != .locked && cam.exposureMode != .custom {
        cam.exposurePointOfInterest = point; cam.exposureMode = .continuousAutoExposure
      }
    }
  }
  func setExposure(_ manual: Bool, iso: Double? = nil, shutter: Double? = nil) {
    control { cam in
      if manual {
        guard cam.isExposureModeSupported(.custom) else { throw self.failure("Exposição manual indisponível") }
        let sensitivity = Float(max(Double(cam.activeFormat.minISO), min(Double(cam.activeFormat.maxISO), iso ?? Double(cam.iso))))
        let minimum = CMTimeGetSeconds(cam.activeFormat.minExposureDuration)
        let maximum = min(CMTimeGetSeconds(cam.activeFormat.maxExposureDuration), 1 / self.selectedProfile.fps)
        let seconds = max(minimum, min(maximum, shutter.map { 1 / max(1, $0) } ?? CMTimeGetSeconds(cam.exposureDuration)))
        cam.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1000000000), iso: sensitivity, completionHandler: nil)
      } else if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
      self.publish {
        self.manualExposure = manual; self.colorLocked = false
        if let iso { self.iso = max(self.minISO, min(self.maxISO, iso)) }
        if let shutter { self.shutter = max(self.minShutter, min(self.maxShutter, shutter)) }
      }
    }
  }
  func setExposureBias(_ value: Double) {
    control { cam in
      let bias = max(Double(cam.minExposureTargetBias), min(Double(cam.maxExposureTargetBias), value))
      cam.setExposureTargetBias(Float(bias), completionHandler: nil)
      self.publish { self.exposureBias = bias }
    }
  }
  func setWhiteBalance(_ manual: Bool, temperature: Double? = nil) {
    control { cam in
      if manual {
        guard cam.isWhiteBalanceModeSupported(.locked) else { throw self.failure("Balanço de branco manual indisponível") }
        let current = cam.temperatureAndTintValues(for: cam.deviceWhiteBalanceGains)
        var gains = cam.deviceWhiteBalanceGains(for: AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature: Float(max(2000, min(10000, temperature ?? Double(current.temperature)))), tint: current.tint))
        gains.redGain = max(1, min(cam.maxWhiteBalanceGain, gains.redGain)); gains.greenGain = max(1, min(cam.maxWhiteBalanceGain, gains.greenGain)); gains.blueGain = max(1, min(cam.maxWhiteBalanceGain, gains.blueGain))
        cam.setWhiteBalanceModeLocked(with: gains, completionHandler: nil)
      } else if cam.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { cam.whiteBalanceMode = .continuousAutoWhiteBalance }
      self.publish { self.manualWhiteBalance = manual; self.colorLocked = false; if let temperature { self.temperature = max(2000, min(10000, temperature)) } }
    }
  }

  // ---- gravar: direto na nuvem
  func record(owner: String, aspect: String, look: LookPreset) {
    let convert = convertRec709, bitrate = Self.bitrates[max(0, min(Self.bitrates.count - 1, bitrateChoice))].bps
    let horizon: Double? = rotation.map { Double($0.videoRotationAngleForHorizonLevelCapture) }   // lido na thread principal
    queue.async {
      guard self.configured, self.session.isRunning, !self.isRecording, let cam = self.device else { return }
      do {
        Diag.step("record-tap", ["codec": self.requestedCodec.rawValue, "fmt": self.selectedProfile.label, "log": self.requestedLog])
        let source: SourceColor = self.requestedLog ? .appleLog : self.requestedHDR ? .hlg : .sdr
        let bakeFn = self.bake709 ? ColorMath.previewTransform(source: source, rawLog: false, look: look) : nil
        let baker = bakeFn.flatMap { LutBaker(transform: $0) }
        if bakeFn != nil && baker == nil { Diag.step("bake-init-fail") }
        var (videoSettings, how) = self.writerVideoSettings(cam, bake: baker != nil)
        var compression = (videoSettings[AVVideoCompressionPropertiesKey] as? [String: Any]) ?? [:]
        let codecName = (videoSettings[AVVideoCodecKey] as? AVVideoCodecType)?.rawValue ?? (videoSettings[AVVideoCodecKey] as? String) ?? ""
        if codecName == AVVideoCodecType.hevc.rawValue || codecName == AVVideoCodecType.h264.rawValue {
          compression[AVVideoMaxKeyFrameIntervalDurationKey] = 1.0
          compression[AVVideoExpectedSourceFrameRateKey] = Int(self.selectedProfile.fps.rounded())
          if let bitrate { compression[AVVideoAverageBitRateKey] = bitrate }
          else if let rec = compression[AVVideoAverageBitRateKey] as? Int, rec > 120_000_000 { compression[AVVideoAverageBitRateKey] = 120_000_000 }
        }
        videoSettings[AVVideoCompressionPropertiesKey] = compression
        // AAC estéreo explícito: o "recomendado" do iPhone 16 pode ser áudio espacial (APAC/4 canais), que o MP4 fragmentado recusa
        let audioSettings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48000, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 256000]
        let isFront = cam.position == .front
        let angle: Double = isFront ? 0 : (horizon ?? self.previewAngle)
        let transform = CGAffineTransform(rotationAngle: CGFloat(angle * .pi / 180))
        Diag.step("record-start", ["how": how, "fmt": self.selectedProfile.label, "log": self.requestedLog, "codec": self.requestedCodec.rawValue, "angle": angle, "video": String(String(describing: videoSettings).prefix(600))])
        var writer: SegmentWriter
        var localFile: URL?
        do { writer = try SegmentWriter.make(video: videoSettings, audio: audioSettings, transform: transform, file: nil) }
        catch {
          // o iPhone recusou o modo "direto na nuvem": grava em arquivo e sobe ao parar (não perde a tomada)
          Diag.step("writer-stream-fail", ["err": error.localizedDescription])
          let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CowboyCaptures")
          try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
          let file = dir.appendingPathComponent(UUID().uuidString + ".mov")
          writer = try SegmentWriter.make(video: videoSettings, audio: audioSettings, transform: transform, file: file)
          localFile = file
          let why = error.localizedDescription
          self.publish { self.status = "Modo direto na nuvem recusado pelo iPhone (\(why)) — gravando no aparelho e subindo ao parar" }
        }
        Diag.step("writer-ok", ["mode": localFile == nil ? "nuvem" : "arquivo", "audio": writer.hasAudio], send: false)
        let mode = self.videoOut.connection(with: .video)?.activeVideoStabilizationMode ?? .off
        let profile = self.selectedProfile
        let colorProfile = baker != nil ? "rec709" : self.requestedLog ? "applelog" : self.requestedHDR ? "hlg" : "rec709"
        var meta = NativeCaptureMetadata(width: profile.width, height: profile.height, frameRate: profile.fps, hdr: self.requestedHDR, codec: self.requestedCodec.rawValue, lens: self.name(cam), stabilization: Self.label(mode), colorProfile: colorProfile, convertRec709: convert, captureMode: "avfoundation-stream").settings
        if baker != nil { meta["baked"] = "\(source == .appleLog ? "Apple Log" : source == .hlg ? "HLG" : "SDR") -> Rec.709\(look.neutral ? "" : " + look " + look.label) (no iPhone, 10 bits)" }
        meta["zoom"] = Double(cam.videoZoomFactor / self.base); meta["bitrate"] = bitrate ?? (compression[AVVideoAverageBitRateKey] as? Int ?? 0); meta["rotation"] = angle
        let lookBody: Any = look.neutral ? NSNull() : ["id": look.id, "p": look.p]
        let body: [String: Any] = ["label": self.name(cam), "mime": "video/mp4", "settings": meta, "stabilization": ["enabled": false], "facing": isFront ? "user" : "environment",
          "convert": (colorProfile != "rec709" && convert) ? "keep" : "none", "aspect": aspect, "look": lookBody, "recorded_at": ISO8601DateFormatter().string(from: Date())]
        let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.timeZone = TimeZone(identifier: "America/Sao_Paulo"); f.dateFormat = "dd/MM HH:mm"
        if let localFile {
          try JSONEncoder().encode(owner).write(to: localFile.appendingPathExtension("owner"), options: .atomic)
          let m = NativeCaptureMetadata(width: profile.width, height: profile.height, frameRate: profile.fps, hdr: self.requestedHDR, codec: self.requestedCodec.rawValue, lens: self.name(cam), stabilization: Self.label(mode), colorProfile: colorProfile, convertRec709: convert, captureMode: "avfoundation-file")
          try JSONEncoder().encode(m).write(to: localFile.appendingPathExtension("capture"), options: .atomic)
          self.dataQueue.async {
            self.stopLock.lock(); self.stopRequested = false; self.stopLock.unlock()
            self.recBaker = baker
            self.writer = writer; self.recCid = nil; self.recOwner = owner; self.recStart = nil; self.recAngle = angle; self.recFront = isFront; self.thumbDone = false; self.gyro = nil; self.elapsedMs = 0
            self.publish { self.recording = true; self.finishing = false; self.elapsed = 0; self.droppedFrames = 0 }
          }
          return
        }
        let cid = CloudStream.shared.begin(owner: owner, title: "iPhone \(f.string(from: Date()))", body: body)
        if !look.neutral && baker == nil {
          let text = ColorMath.cubeText(title: "Cowboy \(look.label)") { ColorMath.grade($0, look.p) }
          CloudStream.shared.side(cid, kind: "cube", data: Data(text.utf8))
        }
        let gyro = GyroLog(url: CloudStream.shared.sideFile(cid, kind: "gcsv"), lens: self.name(cam))
        writer.onSegment = { [weak self] data in
          guard let self else { return }
          CloudStream.shared.push(cid, data, durationMs: self.elapsedMs)
        }
        self.dataQueue.async {
          self.stopLock.lock(); self.stopRequested = false; self.stopLock.unlock()
          self.recBaker = baker
          self.writer = writer; self.recCid = cid; self.recStart = nil; self.recAngle = angle; self.recFront = isFront; self.thumbDone = false; self.gyro = gyro; self.elapsedMs = 0
          MotionHub.shared.attach(gyro)
          self.publish { self.recording = true; self.finishing = false; self.elapsed = 0; self.droppedFrames = 0 }
        }
      } catch {
        Diag.step("record-fail", ["err": error.localizedDescription])
        let why = error.localizedDescription
        self.publish { self.status = "Não começou a gravar: \(why)" }
      }
    }
  }
  // Configuração do codificador. 0.5.1 travava aqui: recommendedVideoSettings LANÇA exceção (NSException) em alguns
  // formatos do iPhone 16 Pro (medido: AVFCapture dentro de record, 07/10). Agora: codec que o escritor aceita, recomendado
  // protegido (mp4, depois mov) e, se o iPhone recusar os dois, configuração montada à mão pelo formato ativo.
  private func writerVideoSettings(_ cam: AVCaptureDevice, bake: Bool = false) -> ([String: Any], String) {
    var codecs: [AVVideoCodecType] = []
    _ = CowboyObjC.catching { codecs = self.videoOut.availableVideoCodecTypesForAssetWriter(writingTo: .mp4) }
    // HEVC/H.264 sempre: o "recomendado" do iPhone em Apple Log é ProRes 422 HQ (apch, 760 Mb/s — medido 07/10), que não
    // sobe ao vivo e não aceita quadro-chave por segundo. O codificador HEVC 10 bits aceita os quadros Log do mesmo jeito.
    let codec: AVVideoCodecType = requestedCodec == .h264 ? .h264 : .hevc
    if codecs.contains(codec) && !bake {
      for type in [AVFileType.mp4, .mov] {
        var got: [String: Any]?
        let ex = CowboyObjC.catching { got = self.videoOut.recommendedVideoSettings(forVideoCodecType: codec, assetWriterOutputFileType: type) }
        if let ex { Diag.step("recommended-fail", ["type": type.rawValue, "codec": codec.rawValue, "err": ex]) }
        if ex == nil, let got, got[AVVideoWidthKey] != nil, (got[AVVideoCodecKey] as? AVVideoCodecType) == codec || (got[AVVideoCodecKey] as? String) == codec.rawValue {
          return (got, "recomendado-" + (type == .mp4 ? "mp4" : "mov"))
        }
      }
    } else { Diag.step("codec-manual", ["codecs": codecs.map { $0.rawValue }.joined(separator: ",")], send: true) }
    let d = CMVideoFormatDescriptionGetDimensions(cam.activeFormat.formatDescription)
    let w = Int(d.width), h = Int(d.height), fps = selectedProfile.fps
    let bitrate = max(8_000_000, min(100_000_000, Int(Double(w * h) * fps * 0.12)))
    var compression: [String: Any] = [AVVideoAverageBitRateKey: bitrate, AVVideoExpectedSourceFrameRateKey: Int(fps.rounded())]
    if codec == .hevc { compression[AVVideoProfileLevelKey] = (requestedLog || requestedHDR || bake) ? (kVTProfileLevel_HEVC_Main10_AutoLevel as String) : (kVTProfileLevel_HEVC_Main_AutoLevel as String) }
    else { compression[AVVideoProfileLevelKey] = AVVideoProfileLevelH264HighAutoLevel }
    var settings: [String: Any] = [AVVideoCodecKey: codec, AVVideoWidthKey: w, AVVideoHeightKey: h, AVVideoCompressionPropertiesKey: compression]
    if requestedHDR && !bake {
      settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
    } else if !requestedLog || bake {
      settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2, AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
    }   // Apple Log: a etiqueta de cor vem dos próprios quadros (o escritor copia)
    return (settings, bake ? "manual-709" : "manual")
  }
  func stopRecording() {
    stopLock.lock(); stopRequested = true; stopLock.unlock()
    publish { if self.recording { self.recording = false; self.finishing = true } }
    dataQueue.async {
      guard let writer = self.writer else { self.publish { self.finishing = false }; return }
      self.writer = nil
      if let b = self.recBaker, b.failures > 0 { Diag.step("bake-failures", ["n": b.failures, "err": b.lastError]) }
      self.recBaker = nil
      if let file = writer.fileURL {
        let owner = self.recOwner; self.recOwner = nil
        self.publish { self.recording = false; self.finishing = true }
        writer.finish { ok in
          Diag.step("stop-file", ["ok": ok])
          self.publish { self.finishing = false; if ok { self.onSaved?(file, owner) } else { self.recoverableFile = file; self.status = "A gravação terminou com erro — arquivo mantido no aparelho" } }
        }
        return
      }
      guard let cid = self.recCid else { return }
      self.recCid = nil
      let gyro = self.gyro; self.gyro = nil; MotionHub.shared.attach(nil)
      let duration = self.elapsedMs, dropped = writer.dropped
      if let meta = self.spaceMeta?() {
        var space = meta; space["camera"] = self.lensName; space["source"] = "ios-native"; space["fov_long_deg"] = self.fieldOfView; space["dropped_frames"] = dropped
        if let data = try? JSONSerialization.data(withJSONObject: space) { CloudStream.shared.side(cid, kind: "space", data: data) }
      }
      self.publish { self.recording = false; self.finishing = true }
      writer.finish { ok in
        gyro?.close()
        if (gyro?.lines ?? 0) == 0 { try? FileManager.default.removeItem(at: CloudStream.shared.sideFile(cid, kind: "gcsv")) }
        CloudStream.shared.close(cid, durationMs: duration)
        Diag.step("stop-stream", ["ok": ok, "ms": duration, "dropped": dropped])
        self.publish { self.finishing = false; if !ok { self.status = "A gravação terminou com erro — o que já subiu está salvo na nuvem" } }
      }
    }
  }
  func close(_ completion: (@Sendable () -> Void)? = nil) {
    stopRecording()
    queue.async {
      self.telemetry?.cancel(); self.telemetry = nil
      if self.session.isRunning { self.session.stopRunning() }
      self.publish { self.ready = false; completion?() }
    }
  }

  // ---- quadros
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    if output === audioOut { meter(sampleBuffer); if !stopping { writer?.appendAudio(sampleBuffer) }; return }
    let pixel = CMSampleBufferGetImageBuffer(sampleBuffer)
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if let pixel { renderer.push(pixel, pts: pts.seconds) }
    guard let writer, !stopping else { return }
    var baked: CMSampleBuffer?
    if let recBaker { baked = recBaker.convert(sampleBuffer) }
    writer.appendVideo(baked ?? sampleBuffer)
    if recStart == nil, writer.started { recStart = pts; gyro?.begin(at: pts.seconds) }
    if let s = recStart { elapsedMs = Int((pts - s).seconds * 1000) }
    if !thumbDone, let pixel {
      thumbDone = true
      let angle = recAngle, isFront = recFront, cid = recCid
      let thumbPixel = baked.flatMap { CMSampleBufferGetImageBuffer($0) } ?? pixel, cooked = baked != nil
      DispatchQueue.global(qos: .utility).async {
        guard let jpeg = self.renderer.thumbnail(thumbPixel, orientation: isFront ? .up : Self.orientation(angle), mirrored: false, applyCube: !cooked) else { return }
        if let cid { CloudStream.shared.side(cid, kind: "thumb", data: jpeg) }
        try? jpeg.write(to: Self.thumbURL, options: .atomic)
        let img = UIImage(data: jpeg)
        self.publish { self.lastThumb = img }
      }
    }
    let now = CACurrentMediaTime()
    if now - lastPublish > 0.25 {
      lastPublish = now
      let e = Double(elapsedMs) / 1000, d = writer.dropped, failed = writer.failed
      publish { self.elapsed = e; self.droppedFrames = d; if let failed { self.status = "Gravador: \(failed)" } }
      if let failed { Diag.step("writer-error", ["err": failed]); stopRecording() }
    }
  }
  func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {}
  private var stopping: Bool { stopLock.lock(); defer { stopLock.unlock() }; return stopRequested }

  // ---- medidor: lê as amostras REAIS do microfone (as mesmas que vão pro arquivo), pico por canal
  private func meter(_ sample: CMSampleBuffer) {
    guard let desc = CMSampleBufferGetFormatDescription(sample), let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(desc) else { return }
    let asbd = asbdPtr.pointee
    let channels = max(1, Int(asbd.mChannelsPerFrame)), isFloat = asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0, bits = Int(asbd.mBitsPerChannel)
    let nonInterleaved = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
    var sizeNeeded = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: &sizeNeeded, bufferListOut: nil, bufferListSize: 0, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: nil)
    guard sizeNeeded > 0 else { return }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: 16); defer { raw.deallocate() }
    let abl = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
    var block: CMBlockBuffer?
    guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sample, bufferListSizeNeededOut: nil, bufferListOut: abl, bufferListSize: sizeNeeded, blockBufferAllocator: nil, blockBufferMemoryAllocator: nil, flags: 0, blockBufferOut: &block) == noErr else { return }
    var peaks = [Float](repeating: 0, count: channels)
    for (bi, buf) in UnsafeMutableAudioBufferListPointer(abl).enumerated() {
      guard let data = buf.mData else { continue }
      let chInBuf = nonInterleaved ? 1 : max(1, Int(buf.mNumberChannels))
      if isFloat && bits == 32 {
        let n = Int(buf.mDataByteSize) / 4, p = data.bindMemory(to: Float.self, capacity: n)
        for i in 0..<n { let c = nonInterleaved ? bi : i % chInBuf; if c < channels { peaks[c] = max(peaks[c], abs(p[i])) } }
      } else if bits == 16 {
        let n = Int(buf.mDataByteSize) / 2, p = data.bindMemory(to: Int16.self, capacity: n)
        for i in 0..<n { let c = nonInterleaved ? bi : i % chInBuf; if c < channels { peaks[c] = max(peaks[c], Float(abs(Int(p[i]))) / 32768) } }
      } else if bits == 32 {
        let n = Int(buf.mDataByteSize) / 4, p = data.bindMemory(to: Int32.self, capacity: n)
        for i in 0..<n { let c = nonInterleaved ? bi : i % chInBuf; if c < channels { peaks[c] = max(peaks[c], Float(abs(Double(p[i]))) / 2147483648) } }
      }
    }
    if meterAcc.count != channels { meterAcc = [Float](repeating: 0, count: channels); holdValues = [Float](repeating: -80, count: channels); holdAt = [Double](repeating: 0, count: channels) }
    for c in 0..<channels { meterAcc[c] = max(meterAcc[c], peaks[c]) }
    let now = CACurrentMediaTime()
    if peaks.contains(where: { $0 >= 0.989 }) { clipAt = now }
    guard now - meterLast >= 0.05 else { return }
    meterLast = now
    let db = meterAcc.map { $0 > 0 ? max(-80, 20 * log10($0)) : -80 }
    for c in 0..<channels where db[c] >= holdValues[c] || now - holdAt[c] > 1.5 { holdValues[c] = db[c]; holdAt[c] = now }
    meterAcc = [Float](repeating: 0, count: channels)
    let hold = holdValues, clip = now - clipAt < 1.5
    publish { self.audioLevels = db; self.audioPeakHold = hold; self.audioClip = clip }
  }

  // Capturas antigas (.mov da versão anterior / modo AR) continuam pela fila de arquivos.
  func recoverSaved(owner: String) {
    queue.async {
      let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CowboyCaptures")
      let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
      for file in files where file.pathExtension == "mov" {
        guard let data = try? Data(contentsOf: file.appendingPathExtension("owner")), (try? JSONDecoder().decode(String.self, from: data)) == owner, self.recovering.insert(file).inserted else { continue }
        Task {
          let asset = AVURLAsset(url: file)
          guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else {
            self.publish { self.recoverableFile = file; self.status = "Captura interrompida mantida; exporte o arquivo para recuperação" }
            return
          }
          self.publish { self.onSaved?(file, owner) }
        }
      }
    }
  }
}
