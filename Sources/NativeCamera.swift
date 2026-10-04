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
  private var desired = AVCaptureVideoStabilizationMode.cinematicExtended
  @Published var status = "Câmera aguardando permissão"
  @Published var ready = false
  @Published var recording = false
  @Published var finishing = false
  @Published var zoom: Double = 1
  @Published var minimumZoom: Double = 0.5
  @Published var maximumZoom: Double = 10
  @Published var activeMode = AVCaptureVideoStabilizationMode.off
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
          self.publish { self.ready = true }
        } catch { self.publish { self.status = error.localizedDescription } }
      }
    }
  }
  private func publish(_ action: @escaping @Sendable () -> Void) { DispatchQueue.main.async(execute: action) }
  private func configure() throws {
    let discovery = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInDualWideCamera, .builtInWideAngleCamera], mediaType: .video, position: .back)
    guard let cam = discovery.devices.first(where: { $0.deviceType == .builtInDualWideCamera }) ?? discovery.devices.first,
      let mic = AVCaptureDevice.default(for: .audio) else { throw failure("Câmera ou microfone indisponível") }
    let videoInput = try AVCaptureDeviceInput(device: cam), audioInput = try AVCaptureDeviceInput(device: mic)
    session.beginConfiguration()
    defer {
      if !configured { session.inputs.forEach(session.removeInput); session.outputs.forEach(session.removeOutput) }
      session.commitConfiguration()
    }
    guard session.canAddInput(videoInput), session.canAddInput(audioInput) else { throw failure("Entradas da câmera indisponíveis") }
    session.addInput(videoInput); session.addInput(audioInput)
    guard session.canAddOutput(movie) else { throw failure("Gravação nativa indisponível") }
    session.addOutput(movie)
    session.sessionPreset = .inputPriority
    try cam.lockForConfiguration()
    defer { cam.unlockForConfiguration() }
    // Keep resolution/fps first; never choose a smaller format just for stabilization.
    let candidates = cam.formats.filter { f in
      let d = CMVideoFormatDescriptionGetDimensions(f.formatDescription)
      return d.width == 3840 && d.height == 2160 && f.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 60 && $0.maxFrameRate >= 60 }
    }
    guard let format = candidates.first(where: { $0.isVideoStabilizationModeSupported(desired) }) ?? candidates.first else {
      throw failure("4K/60 não disponível nesta câmera; não foi reduzida a qualidade automaticamente")
    }
    cam.activeFormat = format
    cam.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 60)
    cam.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 60)
    base = cam.deviceType == .builtInDualWideCamera ? (cam.virtualDeviceSwitchOverVideoZoomFactors.first?.doubleValue.mapCGFloat ?? 2) : 1
    cam.videoZoomFactor = max(cam.minAvailableVideoZoomFactor, min(base, cam.maxAvailableVideoZoomFactor))
    if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
    if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
    if cam.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { cam.whiteBalanceMode = .continuousAutoWhiteBalance }
    device = cam
    let displayBase = base
    zoomObservation = cam.observe(\.videoZoomFactor, options: [.initial, .new]) { [weak self] cam, _ in
      guard let self else { return }
      let value = Double(cam.videoZoomFactor / displayBase)
      self.publish { self.zoom = value }
    }
    movie.maxRecordedFileSize = 256 * 1024 * 1024
    if let connection = movie.connection(with: .video) {
      if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
      if movie.availableVideoCodecTypes.contains(.hevc) { movie.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: connection) }
    }
    configureStabilization()
    configured = true
    let low = Double(cam.minAvailableVideoZoomFactor / base), high = Double(min(cam.maxAvailableVideoZoomFactor / base, 10))
    publish { self.minimumZoom = low; self.maximumZoom = high; self.zoom = 1 }
  }
  private func failure(_ message: String) -> NSError { NSError(domain: "CowboyCamera", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
  private func configureStabilization() {
    guard let cam = device, let connection = movie.connection(with: .video) else { return }
    let fallback: [AVCaptureVideoStabilizationMode] = desired == .off ? [.off] : [desired, .cinematic, .standard, .off]
    let mode = fallback.first { cam.activeFormat.isVideoStabilizationModeSupported($0) } ?? .off
    if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = mode }
    let actual = connection.activeVideoStabilizationMode
    publish { self.activeMode = mode; self.status = "4K · 60 fps · estabilização solicitada: \(Self.label(mode)) · ativa: \(Self.label(actual))" }
  }
  static func label(_ mode: AVCaptureVideoStabilizationMode) -> String {
    switch mode { case .off: return "Desligada"; case .standard: return "Standard"; case .cinematic: return "Cinematic"; case .cinematicExtended: return "Cinematic Extended"; default: return "Sistema" }
  }
  func setStabilization(_ value: Int) {
    queue.async {
      guard !self.movie.isRecording else { return }
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
        self.publish { self.colorLocked = locked }
      } catch { self.publish { self.status = error.localizedDescription } }
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
  func close() { queue.async { if self.movie.isRecording { self.movie.stopRecording() }; if self.session.isRunning { self.session.stopRunning() }; self.publish { self.ready = false } } }
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
  }
  func makeUIView(context: Context) -> Surface {
    let view = Surface(); view.preview.session = camera.session; view.preview.videoGravity = .resizeAspectFill; return view
  }
  func updateUIView(_ view: Surface, context: Context) {
    if let connection = view.preview.connection {
      if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
      if connection.isVideoStabilizationSupported { connection.preferredVideoStabilizationMode = camera.activeMode }
    }
  }
}
