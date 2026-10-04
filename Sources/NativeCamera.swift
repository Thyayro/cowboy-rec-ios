import AVFoundation
import Combine
import SwiftUI

// All device/session operations are serialized. Published UI state is sent to main.
final class NativeCamera: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate, @unchecked Sendable {
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "cowboy.native.camera", qos: .userInitiated)
  private let movie = AVCaptureMovieFileOutput()
  private var device: AVCaptureDevice?
  private var base: CGFloat = 1
  private var configured = false
  private var zoomObservation: NSKeyValueObservation?
  private var recovering = Set<URL>()
  private var owner: String?
  private var outputURL: URL?
  private var telemetry: DispatchSourceTimer?
  private var selectedProfile = NativeCaptureProfile.main
  private var requestedHDR = false
  private var requestedLog = false
  @Published var logAvailable = false
  @Published var logEnabled = false
  private var requestedCodec = AVVideoCodecType.hevc
  private var availableDevices: [AVCaptureDevice] = []
  private var rotationAngle: Double = 90
  @Published var captureAngle: Double = 90
  struct Lens: Identifiable, Sendable { let id: String; let name: String }
  @Published var lenses: [Lens] = []
  @Published var lensID = ""
  @Published var lensName = "Principal 1×"
  @Published var profiles: [NativeCaptureProfile] = []
  @Published var profileID = NativeCaptureProfile.main.id
  @Published var formatLabel = "Aguardando câmera"
  @Published var hdrAvailable = false
  @Published var hdrEnabled = false
  @Published var codecs: [String] = []
  @Published var codec = "hevc"
  @Published var torchAvailable = false
  @Published var torchEnabled = false
  @Published var canSwitchUltraWide = false
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
  private var desired = AVCaptureVideoStabilizationMode.cinematicExtended
  @Published var status = "Câmera aguardando permissão"
  @Published var ready = false
  @Published var recording = false
  @Published var finishing = false
  @Published var zoom: Double = 1
  @Published var minimumZoom: Double = 0.5
  @Published var maximumZoom: Double = 10
  @Published var activeMode = AVCaptureVideoStabilizationMode.off
  @Published var preferredMode = AVCaptureVideoStabilizationMode.cinematicExtended
  @Published var colorLocked = false
  @Published var recoverableFile: URL?
  var onSaved: ((URL, String?) -> Void)?

  func start() {
    Task {
      let camera = await AVCaptureDevice.requestAccess(for: .video)
      let audio = await AVCaptureDevice.requestAccess(for: .audio)
      guard camera && audio else { publish { self.status = "Libere câmera e microfone nos Ajustes do iPhone" }; return }
      queue.async {
        do {
          if !self.configured { try self.configure() }
          if !self.session.isRunning { self.session.startRunning() }
          self.configureStabilization()
          self.startTelemetry()
          self.publish { self.ready = true }
        } catch { self.publish { self.status = error.localizedDescription } }
      }
    }
  }
  private func publish(_ action: @escaping @Sendable () -> Void) { DispatchQueue.main.async(execute: action) }
  private func descriptors(_ cam: AVCaptureDevice) -> [NativeFormatDescriptor] {
    cam.formats.enumerated().map { index,f in
      let d=CMVideoFormatDescriptionGetDimensions(f.formatDescription)
      return NativeFormatDescriptor(index:index,width:Int(d.width),height:Int(d.height),ranges:f.videoSupportedFrameRateRanges.map { NativeFrameRange(min:$0.minFrameRate,max:$0.maxFrameRate) },hdr:f.supportedColorSpaces.contains(.HLG_BT2020),stabilized:f.isVideoStabilizationModeSupported(desired),log:f.supportedColorSpaces.contains(.appleLog))
    }
  }
  private func name(_ cam: AVCaptureDevice) -> String {
    if cam.position == .front { return "Frontal" }
    switch cam.deviceType {
    case .builtInWideAngleCamera: return "Principal 1×"
    case .builtInUltraWideCamera: return "Ultra-angular 0,5×"
    case .builtInTelephotoCamera: return "Teleobjetiva"
    default: return "Traseira automática"
    }
  }
  private func displayBase(_ cam: AVCaptureDevice) -> CGFloat {
    if cam.deviceType == .builtInUltraWideCamera { return 2 }
    if cam.isVirtualDevice && cam.constituentDevices.contains(where: { $0.deviceType == .builtInUltraWideCamera }) {
      return CGFloat(cam.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 2)
    }
    if cam.deviceType == .builtInTelephotoCamera,
      let virtual=availableDevices.first(where: { $0.deviceType == .builtInTripleCamera }),
      let last=virtual.virtualDeviceSwitchOverVideoZoomFactors.last?.doubleValue {
      let main=virtual.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue ?? 2
      return CGFloat(main/last)
    }
    return 1
  }
  private func configure(cameraID: String? = nil, profile: NativeCaptureProfile? = nil, hdr: Bool? = nil, codec: AVVideoCodecType? = nil, log: Bool? = nil, zoom: Double? = nil) throws {
    if availableDevices.isEmpty {
      availableDevices=AVCaptureDevice.DiscoverySession(deviceTypes:[.builtInWideAngleCamera,.builtInUltraWideCamera,.builtInTelephotoCamera,.builtInDualWideCamera,.builtInTripleCamera],mediaType:.video,position:.unspecified).devices
      let choices=availableDevices.map { Lens(id:$0.uniqueID,name:name($0)) }
      publish { self.lenses=choices }
    }
    let cam = cameraID.flatMap { id in availableDevices.first(where: { $0.uniqueID == id }) } ?? device ?? availableDevices.first(where: { $0.position == .back && $0.deviceType == .builtInWideAngleCamera })
    guard let cam else { throw failure("Câmera indisponível") }
    let chosen=profile ?? selectedProfile,wantsHDR=hdr ?? requestedHDR,wantsLog=log ?? requestedLog
    let encoding=codec ?? requestedCodec
    let catalog=descriptors(cam)
    guard let index=NativeCapturePolicy.select(chosen,hdr:wantsHDR,formats:catalog,log:wantsLog) else {
      throw failure("\(name(cam)) não suporta \(chosen.label)\(wantsHDR ? " HDR" : ""). Escolha um formato suportado; a qualidade não foi reduzida.")
    }
    if (wantsHDR || wantsLog) && encoding != .hevc { throw failure("HDR/Log exige HEVC; selecione HEVC antes de ativar HDR") }
    let input=try AVCaptureDeviceInput(device:cam)
    let oldVideo=session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.first(where: { $0.device.hasMediaType(.video) })
    let oldFormat=cam.activeFormat,oldMin=cam.activeVideoMinFrameDuration,oldMax=cam.activeVideoMaxFrameDuration,oldSpace=cam.activeColorSpace
    let wasConfigured=configured
    session.automaticallyConfiguresCaptureDeviceForWideColor=false
    session.beginConfiguration()
    defer { session.commitConfiguration() }
    try cam.lockForConfiguration()
    defer { cam.unlockForConfiguration() }
    do {
      if let oldVideo { session.removeInput(oldVideo) }
      guard session.canAddInput(input) else { throw failure("Esta câmera não pode ser aberta") }
      session.addInput(input)
      if !wasConfigured {
        guard let mic=AVCaptureDevice.default(for:.audio) else { throw failure("Microfone indisponível") }
        let audio=try AVCaptureDeviceInput(device:mic)
        guard session.canAddInput(audio),session.canAddOutput(movie) else { throw failure("Gravação indisponível") }
        session.addInput(audio);session.addOutput(movie)
      }
      session.sessionPreset = .inputPriority
      cam.activeFormat=cam.formats[index]
      let duration=CMTime(seconds:1/chosen.fps,preferredTimescale:600000)
      cam.activeVideoMinFrameDuration=duration;cam.activeVideoMaxFrameDuration=duration
      cam.automaticallyAdjustsVideoHDREnabled=false
      if cam.activeFormat.isVideoHDRSupported { cam.isVideoHDREnabled=wantsHDR }
      if wantsLog { cam.activeColorSpace = .appleLog }
      else if wantsHDR { cam.activeColorSpace = .HLG_BT2020 }
      else if cam.activeFormat.supportedColorSpaces.contains(.sRGB) { cam.activeColorSpace = .sRGB }
      let nativeBase=displayBase(cam)
      let relative=zoom ?? (cam.uniqueID == device?.uniqueID ? Double(cam.videoZoomFactor/base) : max(1,Double(cam.minAvailableVideoZoomFactor/nativeBase)))
      cam.videoZoomFactor=max(cam.minAvailableVideoZoomFactor,min(CGFloat(relative)*nativeBase,cam.maxAvailableVideoZoomFactor))
      if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
      if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
      if cam.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { cam.whiteBalanceMode = .continuousAutoWhiteBalance }
      guard let connection=movie.connection(with:.video),movie.availableVideoCodecTypes.contains(encoding) else { throw failure("Codec não disponível neste formato") }
      if connection.isVideoRotationAngleSupported(rotationAngle) { connection.videoRotationAngle=rotationAngle }
      movie.setOutputSettings([AVVideoCodecKey:encoding],for:connection)
      movie.maxRecordedFileSize=256*1024*1024
      zoomObservation?.invalidate()
      device=cam;base=nativeBase;selectedProfile=chosen;requestedHDR=wantsHDR;requestedLog=wantsLog;requestedCodec=encoding;configured=true
      zoomObservation=cam.observe(\.videoZoomFactor,options:[.initial,.new]) { [weak self] cam,_ in
        guard let self else { return };let value=Double(cam.videoZoomFactor/nativeBase)
        self.publish { self.zoom=value }
      }
      let low=Double(cam.minAvailableVideoZoomFactor/nativeBase),high=Double(min(cam.maxAvailableVideoZoomFactor/nativeBase,10))
      let options=NativeCapturePolicy.profiles(catalog,hdr:wantsHDR,log:wantsLog)
      let hdrOK=catalog.contains { $0.supports(chosen,hdr:true) }
      let logOK=catalog.contains { $0.supports(chosen,hdr:false,log:true) }
      let codecNames=movie.availableVideoCodecTypes.filter { $0 == .hevc || $0 == .h264 }.map { $0.rawValue }
      let display=name(cam),minimumISO=Double(cam.activeFormat.minISO),maximumISO=Double(cam.activeFormat.maxISO)
      let exposureMinimum=CMTimeGetSeconds(cam.activeFormat.minExposureDuration)
      let ultraAvailable=cam.position == .back && availableDevices.contains { lens in lens.position == .back && lens.deviceType == .builtInUltraWideCamera && NativeCapturePolicy.select(chosen,hdr:wantsHDR,formats:descriptors(lens),log:wantsLog) != nil }
      publish {
        self.minimumZoom=low;self.maximumZoom=high;self.lensID=cam.uniqueID;self.lensName=display
        self.profiles=options;self.profileID=chosen.id;self.formatLabel=chosen.label;self.hdrAvailable=hdrOK;self.hdrEnabled=wantsHDR;self.logAvailable=logOK;self.logEnabled=wantsLog
        self.codecs=codecNames;self.codec=encoding.rawValue
        self.torchAvailable=cam.hasTorch;self.torchEnabled=cam.torchMode == .on
        self.canSwitchUltraWide=ultraAvailable
        self.focusAvailable=cam.isFocusModeSupported(.locked) && cam.isLockingFocusWithCustomLensPositionSupported;self.manualFocus=false
        self.exposureAvailable=cam.isExposureModeSupported(.custom);self.manualExposure=false
        self.minISO=minimumISO;self.maxISO=maximumISO
        self.minShutter=chosen.fps;self.maxShutter=max(chosen.fps,1/max(exposureMinimum,0.000001))
        self.minExposureBias=Double(cam.minExposureTargetBias);self.maxExposureBias=Double(cam.maxExposureTargetBias)
        self.whiteBalanceAvailable=cam.isWhiteBalanceModeSupported(.locked);self.manualWhiteBalance=false;self.colorLocked=false
      }
      configureStabilization()
    } catch {
      session.inputs.compactMap { $0 as? AVCaptureDeviceInput }.filter { $0.device.hasMediaType(.video) }.forEach { session.removeInput($0) }
      if let oldVideo,session.canAddInput(oldVideo) { session.addInput(oldVideo) }
      if !wasConfigured { session.inputs.forEach { session.removeInput($0) };session.outputs.forEach { session.removeOutput($0) } }
      cam.activeFormat=oldFormat;cam.activeVideoMinFrameDuration=oldMin;cam.activeVideoMaxFrameDuration=oldMax;cam.activeColorSpace=oldSpace
      throw error
    }
  }
  private func reconfigure(_ action: @escaping @Sendable () throws -> Void) {
    queue.async {
      guard self.outputURL == nil,!self.movie.isRecording else { self.publish { self.status="Pare a gravação antes de trocar câmera, formato ou codec" };return }
      self.publish { self.ready=false }
      do { try action();self.publish { self.ready=self.session.isRunning } }
      catch { self.publish { self.ready=self.session.isRunning;self.status=error.localizedDescription } }
    }
  }
  func selectLens(_ id: String) { reconfigure { try self.configure(cameraID:id) } }
  func selectProfile(_ id: String) {
    reconfigure {
      guard let cam=self.device,let p=NativeCapturePolicy.profiles(self.descriptors(cam),hdr:self.requestedHDR,log:self.requestedLog).first(where: { $0.id == id }) else { throw self.failure("Formato indisponível") }
      try self.configure(profile:p)
    }
  }
  func setHDR(_ enabled: Bool) { reconfigure { try self.configure(hdr:enabled,log:false) } }
  func setLog(_ enabled: Bool) { reconfigure { try self.configure(hdr:false,log:enabled) } }
  func setCodec(_ value: String) { reconfigure { try self.configure(codec:AVVideoCodecType(rawValue:value)) } }
  func setCaptureAngle(_ angle: Double) {
    queue.async {
      guard self.outputURL == nil,!self.movie.isRecording else { return }
      self.rotationAngle=angle
      if let connection=self.movie.connection(with:.video),connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle=angle }
      self.publish { self.captureAngle=angle }
    }
  }
  var zoomPresets: [Double] {
    [0.5,1,2,5,10].filter { value in
      (value >= minimumZoom && value <= maximumZoom) || (value == 0.5 && canSwitchUltraWide && !recording && !finishing)
    }
  }
  func selectZoom(_ value: Double) {
    queue.async {
      guard let cam=self.device else { return }
      if self.outputURL == nil && cam.position == .back && ((cam.deviceType == .builtInWideAngleCamera && value<1) || (cam.deviceType == .builtInUltraWideCamera && value>=1)) {
        let type: AVCaptureDevice.DeviceType = value<1 ? .builtInUltraWideCamera : .builtInWideAngleCamera
        if let lens=self.availableDevices.first(where: { $0.position == .back && $0.deviceType == type }) {
          do { try self.configure(cameraID:lens.uniqueID,zoom:value) } catch { self.publish { self.status=error.localizedDescription } }
          return
        }
      }
      self.setZoom(value)
    }
  }
  private func startTelemetry() {
    guard telemetry == nil else { return }
    let timer=DispatchSource.makeTimerSource(queue:queue)
    timer.schedule(deadline:.now(),repeating:.seconds(1))
    timer.setEventHandler { [weak self] in
      guard let self,let cam=self.device,self.session.isRunning else { return }
      let iso=Double(cam.iso),shutter=1/max(0.000001,CMTimeGetSeconds(cam.exposureDuration)),position=Double(cam.lensPosition),bias=Double(cam.exposureTargetBias)
      let temp=Double(cam.temperatureAndTintValues(for:cam.deviceWhiteBalanceGains).temperature)
      let actual=self.movie.connection(with:.video)?.activeVideoStabilizationMode ?? .off
      self.publish { self.iso=iso;self.shutter=shutter;self.lensPosition=position;self.exposureBias=bias;self.temperature=temp;self.activeMode=actual }
    }
    telemetry=timer;timer.resume()
  }
  private func failure(_ message: String) -> NSError { NSError(domain: "CowboyCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  private func configureStabilization() {
    guard let cam = device, let connection = movie.connection(with: .video) else { return }
    let fallback: [AVCaptureVideoStabilizationMode] = desired == .off ? [.off] : [desired, .cinematic, .standard, .off]
    let mode = fallback.first { cam.activeFormat.isVideoStabilizationModeSupported($0) } ?? .off
    if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = mode }
    let actual = connection.activeVideoStabilizationMode
    let description="\(name(cam)) · \(selectedProfile.label)\(requestedHDR ? " · HDR" : "") · estabilização solicitada: \(Self.label(mode))"
    publish { self.preferredMode=mode;self.activeMode = actual; self.status = description }
  }
  static func label(_ mode: AVCaptureVideoStabilizationMode) -> String {
    switch mode { case .off: return "Desligada"; case .standard: return "Standard"; case .cinematic: return "Cinematic"; case .cinematicExtended: return "Cinematic Extended"; default: return "Sistema" }
  }
  func setStabilization(_ value: Int) {
    queue.async {
      guard self.outputURL == nil,!self.movie.isRecording else { return }
      self.desired = value == 0 ? .off : value == 1 ? .standard : value == 2 ? .cinematic : .cinematicExtended
      self.configureStabilization()
    }
  }
  func setZoom(_ value: Double) {
    queue.async {
      guard let cam = self.device else { return }
      do {
        try cam.lockForConfiguration(); defer { cam.unlockForConfiguration() }
        let target = max(cam.minAvailableVideoZoomFactor, min(CGFloat(value) * self.base, cam.maxAvailableVideoZoomFactor))
        // The camera performs the continuous ramp; no JS zoom steps or CSS warp.
        cam.ramp(toVideoZoomFactor: target, withRate: 3)
      } catch { self.publish { self.status = error.localizedDescription } }
    }
  }
  func lockColor(_ locked: Bool) {
    queue.async {
      guard let cam = self.device else { return }
      do {
        try cam.lockForConfiguration(); defer { cam.unlockForConfiguration() }
        if locked {
          if cam.isExposureModeSupported(.locked) { cam.exposureMode = .locked }
          if cam.isWhiteBalanceModeSupported(.locked) { cam.whiteBalanceMode = .locked }
        } else {
          if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
          if cam.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { cam.whiteBalanceMode = .continuousAutoWhiteBalance }
        }
        self.publish { self.colorLocked = locked;self.manualExposure=false;self.manualWhiteBalance=false }
      } catch { self.publish { self.status = error.localizedDescription } }
    }
  }
  private func control(_ action: @escaping @Sendable (AVCaptureDevice) throws -> Void) {
    queue.async {
      guard let cam=self.device,self.session.isRunning else { return }
      do { try cam.lockForConfiguration();defer { cam.unlockForConfiguration() };try action(cam) }
      catch { self.publish { self.status=error.localizedDescription } }
    }
  }
  func setTorch(_ enabled: Bool) {
    control { cam in
      guard cam.hasTorch,cam.isTorchAvailable else { throw self.failure("Lanterna indisponível nesta câmera") }
      if enabled { try cam.setTorchModeOn(level:AVCaptureDevice.maxAvailableTorchLevel) } else { cam.torchMode = .off }
      self.publish { self.torchEnabled=enabled }
    }
  }
  func setFocus(_ manual: Bool,position: Double? = nil) {
    control { cam in
      if manual {
        guard cam.isFocusModeSupported(.locked),cam.isLockingFocusWithCustomLensPositionSupported else { throw self.failure("Foco manual indisponível nesta lente") }
        cam.setFocusModeLocked(lensPosition:Float(max(0,min(1,position ?? Double(cam.lensPosition)))),completionHandler:nil)
      } else if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
      self.publish { self.manualFocus=manual;if let position { self.lensPosition=max(0,min(1,position)) } }
    }
  }
  func focusAt(_ point: CGPoint) {
    control { cam in
      if cam.isFocusPointOfInterestSupported && cam.isFocusModeSupported(.autoFocus) {
        cam.focusPointOfInterest=point;cam.focusMode = .autoFocus
        self.publish { self.manualFocus=false }
      }
      if cam.isExposurePointOfInterestSupported && cam.exposureMode != .locked && cam.exposureMode != .custom {
        cam.exposurePointOfInterest=point
      }
    }
  }
  func setExposure(_ manual: Bool,iso: Double? = nil,shutter: Double? = nil) {
    control { cam in
      if manual {
        guard cam.isExposureModeSupported(.custom) else { throw self.failure("Exposição manual indisponível") }
        let sensitivity=Float(max(Double(cam.activeFormat.minISO),min(Double(cam.activeFormat.maxISO),iso ?? Double(cam.iso))))
        let minimum=CMTimeGetSeconds(cam.activeFormat.minExposureDuration)
        let maximum=min(CMTimeGetSeconds(cam.activeFormat.maxExposureDuration),1/self.selectedProfile.fps)
        let seconds=max(minimum,min(maximum,shutter.map { 1/max(1,$0) } ?? CMTimeGetSeconds(cam.exposureDuration)))
        cam.setExposureModeCustom(duration:CMTime(seconds:seconds,preferredTimescale:1000000000),iso:sensitivity,completionHandler:nil)
      } else if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
      self.publish {
        self.manualExposure=manual;self.colorLocked=false
        if let iso { self.iso=max(self.minISO,min(self.maxISO,iso)) }
        if let shutter { self.shutter=max(self.minShutter,min(self.maxShutter,shutter)) }
      }
    }
  }
  func setExposureBias(_ value: Double) {
    control { cam in
      let bias=max(Double(cam.minExposureTargetBias),min(Double(cam.maxExposureTargetBias),value))
      cam.setExposureTargetBias(Float(bias),completionHandler:nil)
      self.publish { self.exposureBias=bias }
    }
  }
  func setWhiteBalance(_ manual: Bool,temperature: Double? = nil) {
    control { cam in
      if manual {
        guard cam.isWhiteBalanceModeSupported(.locked) else { throw self.failure("Balanço de branco manual indisponível") }
        let current=cam.temperatureAndTintValues(for:cam.deviceWhiteBalanceGains)
        var gains=cam.deviceWhiteBalanceGains(for:AVCaptureDevice.WhiteBalanceTemperatureAndTintValues(temperature:Float(max(2000,min(10000,temperature ?? Double(current.temperature)))),tint:current.tint))
        gains.redGain=max(1,min(cam.maxWhiteBalanceGain,gains.redGain));gains.greenGain=max(1,min(cam.maxWhiteBalanceGain,gains.greenGain));gains.blueGain=max(1,min(cam.maxWhiteBalanceGain,gains.blueGain))
        cam.setWhiteBalanceModeLocked(with:gains,completionHandler:nil)
      } else if cam.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { cam.whiteBalanceMode = .continuousAutoWhiteBalance }
      self.publish { self.manualWhiteBalance=manual;self.colorLocked=false;if let temperature { self.temperature=max(2000,min(10000,temperature)) } }
    }
  }
  func record(owner: String) {
    queue.async {
      guard self.configured, self.session.isRunning, !self.movie.isRecording, self.outputURL == nil else { return }
      self.owner = owner
      let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CowboyCaptures")
      let file = directory.appendingPathComponent(UUID().uuidString + ".mov")
      do {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(owner).write(to: file.appendingPathExtension("owner"), options: .atomic)
        let metadata=NativeCaptureMetadata(width:self.selectedProfile.width,height:self.selectedProfile.height,frameRate:self.selectedProfile.fps,hdr:self.requestedHDR,codec:self.requestedCodec.rawValue,lens:self.device.map { self.name($0) } ?? "Câmera",stabilization:Self.label(self.movie.connection(with:.video)?.activeVideoStabilizationMode ?? .off),colorProfile:self.requestedLog ? "applelog" : self.requestedHDR ? "hlg" : "rec709")
        try JSONEncoder().encode(metadata).write(to:file.appendingPathExtension("capture"),options:.atomic)
      } catch { self.publish { self.status = error.localizedDescription }; return }
      self.outputURL = file
      self.movie.startRecording(to: file, recordingDelegate: self)
    }
  }
  // Finalized captures survive app restarts even if enqueue failed after stopping.
  // Unfinished files are kept for manual recovery, never uploaded as valid clips.
  func recoverSaved(owner: String) {
    queue.async {
      let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CowboyCaptures")
      let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
      for file in files where file.pathExtension == "mov" && file != self.outputURL {
        guard let data = try? Data(contentsOf: file.appendingPathExtension("owner")),
          (try? JSONDecoder().decode(String.self, from: data)) == owner, self.recovering.insert(file).inserted else { continue }
        Task {
          let asset = AVURLAsset(url: file)
          guard let duration = try? await asset.load(.duration), duration.isNumeric, duration.seconds > 0 else {
            self.publish { self.recoverableFile = file; self.status = "Captura interrompida mantida; exporte o arquivo para recuperação"; self.queue.async { self.recovering.remove(file) } }
            return
          }
          self.publish { self.onSaved?(file, owner); self.queue.async { self.recovering.remove(file) } }
        }
      }
    }
  }
  func stopRecording() { queue.async { if self.movie.isRecording { self.publish { self.finishing = true }; self.movie.stopRecording() } } }
  func close() { queue.async { self.telemetry?.cancel();self.telemetry=nil; if self.movie.isRecording { self.movie.stopRecording() }; if self.session.isRunning { self.session.stopRunning() }; self.publish { self.ready = false } } }
  func fileOutput(_ output: AVCaptureFileOutput, didStartRecordingTo fileURL: URL, from connections: [AVCaptureConnection]) {
    publish { self.recording = true; self.finishing = false }
  }
  func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo fileURL: URL, from connections: [AVCaptureConnection], error: Error?) {
    queue.async {
      let owner = self.owner
      self.outputURL = nil; self.owner = nil
      let success = error == nil || (error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool == true
      self.publish {
        self.recording = false; self.finishing = false
        if success { self.onSaved?(fileURL, owner) }
        else { self.status = "Falha na gravação: \(error?.localizedDescription ?? "erro desconhecido"). Arquivo mantido no aparelho." }
      }
    }
  }
}
private extension Double { var mapCGFloat: CGFloat { CGFloat(self) } }

struct CameraPreview: UIViewRepresentable {
  let camera: NativeCamera
  final class Surface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var lockedAngle: Double?
    var angleChanged: ((Double) -> Void)?
    private var lastAngle: Double?
    override func layoutSubviews() {
      super.layoutSubviews()
      let orientation=window?.windowScene?.interfaceOrientation
      let angle=lockedAngle ?? (orientation == .landscapeLeft ? 180 : orientation == .landscapeRight ? 0 : 90)
      if let connection=preview.connection,connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle=angle }
      if angle != lastAngle { lastAngle=angle;angleChanged?(angle) }
    }
  }
  func makeCoordinator() -> Coordinator { Coordinator(camera:camera) }
  final class Coordinator: NSObject {
    let camera: NativeCamera
    init(camera: NativeCamera) { self.camera=camera }
    @objc func tapped(_ recognizer: UITapGestureRecognizer) {
      guard let surface=recognizer.view as? Surface else { return }
      camera.focusAt(surface.preview.captureDevicePointConverted(fromLayerPoint:recognizer.location(in:surface)))
    }
  }
  func makeUIView(context: Context) -> Surface {
    let view = Surface(); view.preview.session = camera.session; view.preview.videoGravity = .resizeAspectFill
    view.angleChanged={ angle in camera.setCaptureAngle(angle) }
    view.addGestureRecognizer(UITapGestureRecognizer(target:context.coordinator,action:#selector(Coordinator.tapped(_:))))
    return view
  }
  func updateUIView(_ view: Surface, context: Context) {
    view.lockedAngle=camera.recording || camera.finishing ? camera.captureAngle : nil
    view.setNeedsLayout()
    if let connection = view.preview.connection {
      if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = camera.preferredMode }
    }
  }
}
