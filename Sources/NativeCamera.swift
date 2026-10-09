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
  // 0.9.0: a tomada das 18:24 (0.8.9) subiu com 0 pedaços de vídeo (32 s, 549 quadros perdidos) — contadores pro diagnóstico
  private(set) var vOK = 0, aOK = 0, aSkip = 0, segs = 0, segBytes = 0
  private var audioDone = false
  var statusCode: Int { writer.status.rawValue }
  // áudio que não entra (ou parou) faz o gravador segurar o vídeo esperando intercalar e não soltar pedaço nenhum: fecha a
  // faixa de áudio e o vídeo segue (melhor uma tomada sem som do que nenhuma)
  func endAudio() {
    guard !audioDone, let a = audio, start != nil, writer.status == .writing else { return }
    audioDone = true
    _ = CowboyObjC.catching { a.markAsFinished() }
  }
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
      if appended { vOK += 1 } else { dropped += 1 }
    } else { dropped += 1 }
  }
  func appendAudio(_ sample: CMSampleBuffer) {
    guard error == nil, !audioDone, let start, let audio, writer.status == .writing, CMSampleBufferGetPresentationTimeStamp(sample) >= start else { return }
    guard audio.isReadyForMoreMediaData else { aSkip += 1; return }
    var ok = false
    if let ex = CowboyObjC.catching({ ok = audio.append(sample) }) { error = ex; return }
    if ok { aOK += 1 } else { aSkip += 1 }
  }
  func finish(_ done: @escaping @Sendable (Bool) -> Void) {
    guard start != nil, writer.status == .writing else { _ = CowboyObjC.catching { self.writer.cancelWriting() }; done(false); return }
    let w = writer
    let ex = CowboyObjC.catching {
      self.video.markAsFinished(); if !self.audioDone { self.audio?.markAsFinished() }
      w.finishWriting { done(w.status == .completed) }
    }
    if ex != nil { done(false) }
  }
  func assetWriter(_ writer: AVAssetWriter, didOutputSegmentData segmentData: Data, segmentType: AVAssetSegmentType, segmentReport: AVAssetSegmentReport?) {
    segs += 1; segBytes += segmentData.count
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
  private let fastOut = AVCaptureVideoDataOutput()   // prévia do zoom: sem estabilização, tempo real (nunca vai pro arquivo)
  private let fastQueue = DispatchQueue(label: "cowboy.native.fast", qos: .userInteractive)
  private var fastOK = false
  private(set) var device: AVCaptureDevice?
  private(set) var base: CGFloat = 1
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
  @Published var lightPreview = UserDefaults.standard.object(forKey: "lightPreview") as? Bool ?? true
  @Published var zoomInstant = UserDefaults.standard.object(forKey: "zoomInstant") as? Bool ?? true
  // Arquivo final: Rec.709 + look convertido NO iPhone a partir do Log real (padrão) ou o Log original (cor na VPS)
  @Published var bake709 = UserDefaults.standard.object(forKey: "bake709") as? Bool ?? true { didSet { UserDefaults.standard.set(bake709, forKey: "bake709") } }
  @Published var lastThumb: UIImage? = UIImage(contentsOfFile: NativeCamera.thumbURL.path)
  // EFEITOS E ZOOM (0.8.9): velocidade do toque nas lentes, desfoque de movimento e onde ele é aplicado
  //  - Live (padrão): tela e arquivo com o rastro (no shader do arquivo, só nos quadros com movimento: parado não custa);
  //  - Render: grava LIMPO (menos GPU gravando) e a VPS aplica depois, pela mesma conta (arquivo de efeitos .fx);
  //    "ver como render" mostra na tela exatamente o rastro que o render vai pôr.
  static let zoomSpeeds: [(label: String, seconds: Double, floor: Double)] = [("Rápido", 0.16, 0.08), ("Médio", 0.32, 0.15), ("Lento", 0.55, 0.3)]
  @Published var zoomSpeed = max(0, min(2, UserDefaults.standard.object(forKey: "zoomSpeed") as? Int ?? 1))
  @Published var motionBlur = UserDefaults.standard.object(forKey: "motionBlur") as? Bool ?? true
  @Published var blurAngle = MotionBlur.angles.contains(UserDefaults.standard.integer(forKey: "blurAngle")) ? UserDefaults.standard.integer(forKey: "blurAngle") : 720   // pesado (After Effects) por padrão
  @Published var fxRender = UserDefaults.standard.object(forKey: "fxRender") as? Bool ?? false
  @Published var previewAsRender = UserDefaults.standard.object(forKey: "previewAsRender") as? Bool ?? false
  private var fxAngle = 180.0     // cópia do "forte" pra quem lê fora da thread principal
  private var fileBlur = false    // tomada atual: o shader do arquivo aplica (Live)
  private var fxLogOn = false     // tomada atual: cada quadro com rastro vira linha no arquivo de efeitos (Render)
  private var fxBuffer = ""
  private var fxLines = 0
  private var lastFileFrame: (pixel: CVPixelBuffer, sid: Int, geo: SwitchGeometry)?
  private var fileXF: (pixel: CVPixelBuffer, t0: Double, geo: SwitchGeometry)?
  private var writerStall = 0
  func setZoomSpeed(_ v: Int) { zoomSpeed = max(0, min(2, v)); UserDefaults.standard.set(zoomSpeed, forKey: "zoomSpeed"); Diag.step("fx", ["zoom": Self.zoomSpeeds[zoomSpeed].label], send: false) }
  func setMotionBlur(_ on: Bool) { motionBlur = on; UserDefaults.standard.set(on, forKey: "motionBlur"); syncEffects() }
  func setBlurAngle(_ a: Int) { blurAngle = MotionBlur.angles.contains(a) ? a : 720; UserDefaults.standard.set(blurAngle, forKey: "blurAngle"); syncEffects() }
  func setFXRender(_ on: Bool) { fxRender = on; UserDefaults.standard.set(on, forKey: "fxRender"); syncEffects() }
  func setPreviewAsRender(_ on: Bool) { previewAsRender = on; UserDefaults.standard.set(on, forKey: "previewAsRender"); syncEffects() }
  func syncEffects() {
    renderer.blurPreview = motionBlur && (!fxRender || previewAsRender)
    fxAngle = Double(blurAngle)
    Diag.step("fx", ["desfoque": motionBlur ? "\(blurAngle)" : "off", "modo": fxRender ? "render" : "live", "tela": renderer.blurPreview ? "com rastro" : "limpa", "zoom": Self.zoomSpeeds[zoomSpeed].label], send: false)
  }
  static let thumbURL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("last_thumb.jpg")
  private var recBaker: LutBaker?
  let zoomDriver = ZoomDriver()
  // redutor de ruído (no áudio que vai pro arquivo): médio por padrão
  let noise = NoiseReducer(level: NoiseReducer.Level(rawValue: UserDefaults.standard.object(forKey: "noise") as? Int ?? 2) ?? .medium)
  @Published var noiseLevel = NoiseReducer.Level(rawValue: UserDefaults.standard.object(forKey: "noise") as? Int ?? 2) ?? .medium
  func setNoise(_ l: NoiseReducer.Level) { noise.setLevel(l); noiseLevel = l; UserDefaults.standard.set(l.rawValue, forKey: "noise"); Diag.step("noise", ["level": l.label], send: false) }
  private var constituentObservation: NSKeyValueObservation?
  private(set) var lensMatch: LensMatch?
  private var aligner: SwitchAligner?
  private var observing = false
  // ZOOM ESTILO BLACKMAGIC: em 0,5× a pinça dá zoom SÓ na ultra-angular (lente travada); tocando 1× ou mais, o zoom cruza as
  // lentes (ultra -> principal -> tele). Tocar 0,5 de novo volta a travar na ultra.
  @Published var ultraLock = UserDefaults.standard.object(forKey: "ultraLock") as? Bool ?? true
  // FOCO SEGURADO NO ZOOM (medido 08/10): o vai-e-volta de escala ao estacionar era o FOCO AUTOMÁTICO procurando de novo
  // (o zoom dentro de uma lente é recorte digital: muda a área que o AF analisa e ele caça; as lentes do iPhone mudam de
  // tamanho de imagem quando o foco anda — "focus breathing", forte na tele). Durante o zoom e 1,2 s depois o foco fica
  // TRAVADO onde está (a distância do assunto não mudou); na troca de lente física faz UM ajuste e trava de novo.
  // 0.8.1: DESLIGADO. Medido na tela (trechos 0.8.0): travar no zoom deixava a imagem desfocada depois de cada zoom e a
  // lente nova entrava fora de foco (o "um ajuste" na troca caçava) — ~1 s depois o foco contínuo voltava e procurava.
  // O vai-e-volta de escala era outra coisa (ampliação da tela e troca de lente, já resolvidos). Foco contínuo e suave o
  // tempo todo, como a câmera do iPhone (o iPhone passa o foco de uma lente pra outra sozinho).
  // 0.8.2 (medido nos trechos da 0.8.0 e da 0.8.1): contínuo o tempo todo deixou a lente principal ENTRAR DESFOCADA na
  // troca e o modo suave não achou o foco em >2 s (nitidez 5 contra ~1000 da ultra no mesmo monitor a ~50 cm); a trava da
  // 0.6.8 segurava bem durante o zoom, o ruim era soltar pro contínuo 1,2 s depois (caçava). Agora:
  //  - zoom andando: foco TRAVADO (o AF caça enquanto a imagem muda de tamanho — e a "respiração" muda a escala);
  //  - zoom parou (0,3 s), lente trocou, toque, cena mudou: UM foco rápido (sem o modo suave) e, assentou, contínuo suave.
  // 0.8.3: a 0.8.2 também entrou borrada na troca (o foco nem se mexia por 2 s). Fim dos ajustes por cima do iPhone: foco
  // CONTÍNUO sempre (sem trava no zoom, sem foco forçado, sem modo suave) e troca de lente automática — o padrão da Apple,
  // que é o da câmera nativa. Toque = contínuo no ponto até a cena mudar ou um zoom.
  var focusHoldEnabled = false
  private var focusHeld = false
  // CALOR (0.8.2): aparelho morno/quente e câmera parada (sem gravar) = 30 qps; gravando, a cadência do formato
  private var idleSlow = false
  private var thermalObserver: NSObjectProtocol?
  private var recCadence: Double?
  private var recCadenceUntil = 0.0
  private var lastVideoPTS: Double?
  // toque pra focar: foco e luz seguem o ponto tocado até a cena mudar (aviso do iPhone) ou um zoom — aí voltam pro centro
  private var pointFocused = false
  private var subjectObserver: NSObjectProtocol?
  private var focusGen = 0
  @Published var selfTest = ""          // texto do teste automático em andamento ("" = parado)
  private var selfTestResults: [String: [Float]] = [:]
  private var selfTestMode = ""
  var calibrating = false   // calibração do zoom rodando: sem medição do estacionar em paralelo (CPU)
  // aprendizado da trava nos zooms do uso normal (ZoomCalibration.swift) — só na thread principal
  var autoSamples: [GestureSample] = []
  var autoWindow: Double?
  var autoHandled = 0.0
  var autoTimer: Timer?
  var zoomBoundaries: [Double] = []
  // prévia estabilizada: zoom de cada quadro = registro exato do ZoomDriver + trava calibrada (nil = conta antiga). Só main.
  func setFrameLag(_ fit: ZoomFit?) {
    if let fit { let drv = zoomDriver; renderer.frameZoom = { [weak drv] p in drv?.zoom(forFrame: p, fit: fit) } } else { renderer.frameZoom = nil }
  }
  @Published var lensMatchOn = UserDefaults.standard.object(forKey: "lensMatch") as? Bool ?? true
  @Published var lensMatchStatus: [String: Int] = [:]
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
    renderer.tap.refill()
    syncEffects()
    LensSwitchHider.geometryOn = false   // 0.9.0: troca parada = dissolve (ver ZoomKernel)
    Task {
      let camera = await AVCaptureDevice.requestAccess(for: .video)
      let audio = await AVCaptureDevice.requestAccess(for: .audio)
      guard camera && audio else { publish { self.status = "Libere câmera e microfone nos Ajustes do iPhone" }; return }
      MotionHub.shared.start()
      observeSession()
      queue.async {
        do {
          if !self.configured { try self.guarded { try self.configure() } }
          if !self.session.isRunning { self.session.startRunning() }
          if !self.session.isRunning { self.retryRunning(0) }
          self.configureStabilization()
          self.startTelemetry()
          self.publish { self.ready = true }
        } catch { self.publish { self.status = error.localizedDescription } }
      }
    }
  }
  private func publish(_ action: @escaping @Sendable () -> Void) { DispatchQueue.main.async(execute: action) }
  // outra tela/app (ex.: página web) pegou a câmera, ou o iOS interrompeu: volta sozinho assim que liberar
  private func observeSession() {
    guard !observing else { return }; observing = true
    let nc = NotificationCenter.default
    nc.addObserver(forName: AVCaptureSession.wasInterruptedNotification, object: session, queue: nil) { [weak self] n in
      let why = (n.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int) ?? -1
      Diag.step("session-interrupted", ["why": why])
      self?.publish { self?.status = "Câmera em uso por outra tela — volta sozinha" }
    }
    nc.addObserver(forName: AVCaptureSession.interruptionEndedNotification, object: session, queue: nil) { [weak self] _ in
      Diag.step("session-resumed")
      self?.queue.async { guard let self else { return }; if !self.session.isRunning { self.session.startRunning() }; self.publish { self.ready = self.session.isRunning } }
    }
    nc.addObserver(forName: AVCaptureSession.runtimeErrorNotification, object: session, queue: nil) { [weak self] n in
      let err = (n.userInfo?[AVCaptureSessionErrorKey] as? NSError)?.localizedDescription ?? "?"
      Diag.step("session-error", ["err": err])
      self?.retryRunning(0)
    }
  }
  private func retryRunning(_ n: Int) {
    queue.asyncAfter(deadline: .now() + 0.5) {
      guard !self.session.isRunning else { self.publish { self.ready = true }; return }
      self.session.startRunning()
      if self.session.isRunning { Diag.step("session-restarted", ["tries": n + 1]); self.publish { self.ready = true } }
      else if n < 20 { self.retryRunning(n + 1) }
    }
  }
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
        if session.canAddOutput(fastOut) {
          session.addOutput(fastOut); fastOut.alwaysDiscardsLateVideoFrames = true; fastOut.setSampleBufferDelegate(self, queue: fastQueue); fastOK = true
        }
        Diag.step("fast-output", ["ok": fastOK])
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
      if fastOK, fastOut.availableVideoPixelFormatTypes.contains(sub) { fastOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: sub] }
      // LEVEZA (0.7.8): a saída rápida só serve à tela e às medidas — quadro do tamanho da tela em vez do 4K inteiro
      // (o celular esquentava e travava os outros apps)
      if fastOK { _ = CowboyObjC.catching { self.fastOut.automaticallyConfiguresOutputBufferDimensions = false; self.fastOut.deliversPreviewSizedOutputBuffers = true } }
      // troca de lente AUTOMÁTICA (0.8.3) = o padrão da Apple, o mesmo da câmera nativa: o iOS escolhe a lente por zoom,
      // distância de foco (perto demais pra principal = ultra), luz e obstrução, e cuida do foco na passagem. O "só pelo zoom"
      // (restricted) e a ultra travada no 0,5× deixavam a lente entrar sem foco (medido: principal borrada por >2 s). Os
      // pulos de tamanho/cor da troca são cuidados pelo LensSwitchHider e pelo igualar câmeras.
      if cam.isVirtualDevice { _ = CowboyObjC.catching { cam.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: []) } }
      let nativeBase = displayBase(cam)
      let relative = zoom ?? (cam.uniqueID == device?.uniqueID ? Double(cam.videoZoomFactor / base) : Double(cam.minAvailableVideoZoomFactor / nativeBase))
      cam.videoZoomFactor = max(cam.minAvailableVideoZoomFactor, min(CGFloat(relative) * nativeBase, cam.maxAvailableVideoZoomFactor))
      if relative <= 0.51 { publish { self.ultraLock = true; UserDefaults.standard.set(true, forKey: "ultraLock") } }
      if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
      if cam.isSmoothAutoFocusSupported { cam.isSmoothAutoFocusEnabled = false }   // modo suave demorava >2 s pra achar o foco
      if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
      if cam.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) { cam.whiteBalanceMode = .continuousAutoWhiteBalance }
      guard let connection = videoOut.connection(with: .video) else { throw failure("Saída de vídeo indisponível") }
      let isFront = cam.position == .front
      // frontal: o iPhone gira os quadros (mais simples e certo pro espelho); traseira: quadro do sensor + rotação no arquivo
      if isFront, connection.isVideoRotationAngleSupported(previewAngle) { connection.videoRotationAngle = previewAngle }
      else if connection.isVideoRotationAngleSupported(0) { connection.videoRotationAngle = 0 }
      if connection.isVideoMirroringSupported { connection.automaticallyAdjustsVideoMirroring = false; connection.isVideoMirrored = false }
      if fastOK, let fc = fastOut.connection(with: .video) {
        // prévia: estabilização de baixa latência (a da câmera do iPhone); a Extrema fica só no arquivo
        // a estabilização de prévia da Apple fazia a ESCALA ir e voltar depois do zoom (medido 08/10): a tela recebe o quadro
        // cru e estabiliza sozinha (PreviewEIS, só deslocamento)
        let light: AVCaptureVideoStabilizationMode = .off
        if fc.isVideoStabilizationSupported {
          if CowboyObjC.catching({ fc.preferredVideoStabilizationMode = light }) != nil { _ = CowboyObjC.catching { fc.preferredVideoStabilizationMode = .standard } }
        }
        let lightName = Self.label(light)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { Diag.step("preview-stab", ["asked": lightName, "active": Self.label(fc.activeVideoStabilizationMode)]) }
        if isFront, fc.isVideoRotationAngleSupported(previewAngle) { fc.videoRotationAngle = previewAngle } else if fc.isVideoRotationAngleSupported(0) { fc.videoRotationAngle = 0 }
        if fc.isVideoMirroringSupported { fc.automaticallyAdjustsVideoMirroring = false; fc.isVideoMirrored = false }
      }
      zoomObservation?.invalidate(); rotationObservation?.invalidate()
      device = cam; base = nativeBase; selectedProfile = chosen; requestedHDR = wantsHDR; requestedLog = wantsLog; requestedCodec = encoding; configured = true
      UserDefaults.standard.set(cam.uniqueID, forKey: "lens"); UserDefaults.standard.set(wantsLog, forKey: "log")
      DispatchQueue.main.async { self.rotation = AVCaptureDevice.RotationCoordinator(device: cam, previewLayer: nil) }
      renderer.zoomNow = { [weak cam] in cam.map { Double($0.videoZoomFactor) } }
      renderer.blurShutter = { [weak self, weak cam] in
        guard let self, let cam else { return 0 }
        let fd = CMTimeGetSeconds(cam.activeVideoMinFrameDuration), ex = CMTimeGetSeconds(cam.exposureDuration)
        return MotionBlur.shutter(angle: self.fxAngle, frameDuration: fd.isFinite && fd > 0 ? fd : 1.0 / 60, exposure: ex.isFinite ? ex : 0)
      }
      renderer.blurHot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
      lastPrimary = nil
      renderer.digitalNow = { [weak self] in self?.zoomDriver.digital ?? 1 }
      renderer.digitalAt = { [weak self] p in self?.zoomDriver.digital(at: p) ?? 1 }
      let bounds = (cam.isVirtualDevice ? cam.virtualDeviceSwitchOverVideoZoomFactors.map { $0.doubleValue } : []) + cam.activeFormat.secondaryNativeResolutionZoomFactors.map { Double($0) }
      DispatchQueue.main.async {
        self.setFrameLag(ZoomLag.load()); self.zoomBoundaries = bounds
        // aprendizado em segundo plano DESLIGADO (0.7.7): no aparelho os pares tinham saltos de 8–28% que nenhum modelo de
        // atraso explica (trocas de lente); só gastava processador. Primeiro: ver o que a tela mostra.
        self.renderer.tap.allowed = { [weak self] in guard let self else { return false }; return !self.recording && !self.renderer.lightPreview }
        self.renderer.tap.onClip = { data in Diag.postClip(data) }
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
        Diag.step("zoom-lag-state", ["trava_ms": ZoomLag.load()?.text ?? "nenhuma (conta antiga)", "previa": self.renderer.lightPreview ? "sem atraso" : "estabilizada"])
      }
      // igualar câmeras: lente ativa a cada instante (o quadro atrasado do arquivo procura a lente pelo próprio horário)
      let match = lensMatch ?? LensMatch(deviceKey: cam.deviceType.rawValue)
      lensMatch = match; renderer.lensMatch = match
      let al = aligner ?? SwitchAligner()
      aligner = al; renderer.aligner = al
      let rnd = renderer
      al.probe = { [weak cam] in
        guard let c = cam else { return "" }
        let crop = rnd.displayCrop, sh = rnd.displayShake
        let lens = LensMatch.name(c.activePrimaryConstituent?.deviceType ?? c.deviceType)
        return String(format: "z%.3f %@%@ L%.3f c%.4f E%+.4f,%+.4f", Double(c.videoZoomFactor), lens, c.isRampingVideoZoom ? " R" : "", c.lensPosition, crop, sh.0, sh.1)
      }
      al.settleStream = { [weak rnd] in (rnd?.lightPreview ?? true) ? "fast" : "stab" }
      al.displayScale = { [weak rnd] t in rnd?.displayK(at: t) }
      al.onSettle = { [weak self] txt, amp, tag in
        DispatchQueue.main.async {
          guard let self else { return }
          if !tag.isEmpty {
            self.selfTestResults[tag, default: []].append(amp)
            Diag.step("zoom-selftest-trace", ["passo": tag, "volta": String(format: "%.4f", amp), "quadros": String(txt.prefix(7000))])
            if tag == "pinça 3" { self.finishSelfTest() }
          }
          else { Diag.step("zoom-settle-image", ["amplitude": String(format: "%.4f", amp), "ms:escala": String(txt.prefix(2500))]) }
        }
      }
      // pinça na ultra travada bateu no limite digital dela (medido 08/10: parou em ~1,4×): libera o cruzamento de lentes e o
      // zoom continua subindo pela principal, sem "travar" o gesto
      zoomDriver.onStuck = { [weak self] txt in
        Diag.step("zoom-stuck", ["info": txt])
        DispatchQueue.main.async {
          guard let self, self.ultraLock else { return }
          self.ultraLock = false; UserDefaults.standard.set(false, forKey: "ultraLock")
          self.queue.async { if let c = self.device { self.applyLensLock(c) } }
        }
      }
      zoomDriver.onTrace = { txt in Diag.step("zoom-settle-cmd", ["zoom": String(txt.prefix(3000))]) }
      al.lensAt = { [weak match] t in match?.lens(at: t) ?? LensMatch.reference }
      al.onAlign = { stream, g, e, e0 in Diag.step("lens-align", ["stream": stream, "s": String(format: "%.4f", g.s), "tx": String(format: "%.4f", g.tx), "ty": String(format: "%.4f", g.ty), "gain": String(format: "%.2f", e0 > 0 ? 1 - e / e0 : 0)]) }
      match.motion = { MotionHub.shared.rotationSpeed() }
      renderer.onSwitch = { info in Diag.step("lens-switch", info) }
      var lastBorderDiag = 0.0
      renderer.blackBorder = { [weak cam] in
        let now = CACurrentMediaTime(); guard now - lastBorderDiag > 4 else { return }; lastBorderDiag = now
        Diag.step("fast-black-border", ["zoom": String(format: "%.2f", Double(cam?.videoZoomFactor ?? 0)), "ramping": cam?.isRampingVideoZoom ?? false])
      }
      match.onLearn = { [weak self] lens, c in
        guard let self else { return }
        let st = match.status(); self.publish { self.lensMatchStatus = st }
        if c.samples == 1 || c.samples % 5 == 0 { Diag.step("lens-match", ["lens": lens, "n": c.samples, "gamma": String(format: "%.3f", c.gamma), "scale": String(format: "%.3f", c.scale), "gain": String(format: "%.3f %.3f %.3f", c.gain.x, c.gain.y, c.gain.z)]) }
      }
      constituentObservation?.invalidate()
      if cam.isVirtualDevice {
        constituentObservation = cam.observe(\.activePrimaryConstituent, options: [.initial, .new]) { [weak self] cam, _ in
          match.lensChanged(LensMatch.name(cam.activePrimaryConstituent?.deviceType))
          self?.queue.async {
            self?.applyLensLock(cam)
            self?.focusNewLens(cam)
            // lente física nova: o foco fica com o iPhone (0.8.4). Reafirmar o contínuo aqui fazia a lente de foco dar um
            // passinho 0,4–0,7 s depois de cada troca (medido: 0,227→0,216, 0,518→0,502…) = o "foco ajustando entre as lentes"
          }
        }
      } else { match.lensChanged(LensMatch.name(cam.deviceType)) }
      let st0 = match.status()
      zoomDriver.attach(cam)
      // diagnóstico: posição da lente de foco e se o AF está andando, junto da nitidez depois de cada troca de lente
      renderer.focusProbe = { [weak cam] in
        guard let c = cam else { return "" }
        return String(format: "L%.3fI%.0fE%.0f", c.lensPosition, c.iso, CMTimeGetSeconds(c.exposureDuration) * 10000) + (c.isAdjustingFocus ? "A" : "") + (c.isAdjustingExposure ? "X" : "") + (c.focusMode == .continuousAutoFocus ? "" : c.focusMode == .locked ? "T" : "U")
      }
      if thermalObserver == nil {
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
          Diag.step("thermal", ["estado": Self.thermalName()])
          self?.renderer.blurHot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
          self?.applyIdleRate()
        }
      }
      idleSlow = false
      applyIdleRate()
      if let o = subjectObserver { NotificationCenter.default.removeObserver(o) }
      subjectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: cam, queue: nil) { [weak self] _ in self?.recenterFocus("cena mudou") }
      DispatchQueue.main.async { self.lensMatchStatus = st0 }
      renderer.onCrop = { c in Diag.step("crop-calib", ["crop": String(format: "%.3f", c)]) }
      zoomObservation = cam.observe(\.videoZoomFactor, options: [.initial, .new]) { [weak self] cam, _ in
        guard let self else { return }
        let value = Double(cam.videoZoomFactor / nativeBase), raw = Double(cam.videoZoomFactor)
        let total = value * self.zoomDriver.digital
        self.publish { self.zoom = total; self.zoomFactorRaw = raw }
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
      renderer.blurFOV = fov
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
      try self.configure(cameraID: target.uniqueID, zoom: goFront ? 1 : 0.5)
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
  func setZoomInstant(_ value: Bool) { UserDefaults.standard.set(value, forKey: "zoomInstant"); renderer.zoomInstant = value; publish { self.zoomInstant = value } }
  func setLightPreview(_ value: Bool) { UserDefaults.standard.set(value, forKey: "lightPreview"); renderer.lightPreview = value; publish { self.lightPreview = value } }
  func setBitrate(_ value: Int) { UserDefaults.standard.set(value, forKey: "bitrate"); publish { self.bitrateChoice = value } }
  // interface girou (retrato/deitado): a prévia acompanha; o arquivo usa o ângulo do horizonte travado ao começar
  func setPreviewAngle(_ angle: Double) {
    queue.async {
      guard self.previewAngle != angle else { return }
      self.previewAngle = angle
      guard let cam = self.device else { return }
      let isFront = cam.position == .front
      if isFront, !self.isRecording, let c = self.videoOut.connection(with: .video), c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
      if isFront, self.fastOK, let c = self.fastOut.connection(with: .video), c.isVideoRotationAngleSupported(angle) { c.videoRotationAngle = angle }
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
  // 0,5×: lente travada na ultra (zoom digital nela). 1× em diante: troca de lente pelo zoom.
  private func applyLensLock(_ cam: AVCaptureDevice, leaving: Bool = false) {
    guard cam.isVirtualDevice, cam.position == .back else { return }
    // REGRA DO FILMMAKER (0.8.5): no 0,5× a ULTRA fica TRAVADA — pinça partindo do 0,5× vai pela 0,5 (zoom digital nela),
    // sem o iOS alternar ultra↔principal perto do 1× (medido na 0.8.3/0.8.4 com a troca automática: ia e voltava). Tocou
    // em 1×/2×/5× = troca automática (o iOS escolhe a lente e cuida do foco na passagem). Pinça que bate no limite digital
    // da ultra destrava (onStuck) e segue pela principal.
    // 0.8.7: NUNCA travada — `.locked` congelou o foco em 1,000 (infinito) e outros devs relatam o mesmo no 16 Pro Max.
    // A regra do 0,5× é feita pelo zoom digital na ultra (ZoomDriver), com o iPhone sempre no automático.
    let lockUltra = false
    let want: AVCaptureDevice.PrimaryConstituentDeviceSwitchingBehavior = .auto
    guard cam.primaryConstituentDeviceSwitchingBehavior != want else { return }
    _ = CowboyObjC.catching {
      if (try? cam.lockForConfiguration()) != nil {
        cam.setPrimaryConstituentDeviceSwitchingBehavior(want, restrictedSwitchingBehaviorConditions: [])
        cam.unlockForConfiguration()
      }
    }
    Diag.step("lens-lock", ["mode": lockUltra ? "ultra" : "auto"])
  }
  private func holdFocus(_ seconds: Double) {
    queue.async {
      guard self.focusHoldEnabled, let cam = self.device, !self.manualFocus, cam.position == .back else { return }
      self.focusGen += 1; let gen = self.focusGen
      if !self.focusHeld && cam.isFocusModeSupported(.locked) {
        _ = CowboyObjC.catching { if (try? cam.lockForConfiguration()) != nil { cam.focusMode = .locked; cam.unlockForConfiguration() } }
        self.focusHeld = true
      }
      self.queue.asyncAfter(deadline: .now() + seconds) {
        guard gen == self.focusGen, self.focusHeld else { return }
        self.focusHeld = false
        guard !self.manualFocus, let cam = self.device else { return }
        _ = CowboyObjC.catching { if (try? cam.lockForConfiguration()) != nil { self.continuousFocusLocked(cam); cam.unlockForConfiguration() } }
      }
    }
  }
  // foco contínuo no ponto de interesse atual (pôr o ponto e o modo de novo = o AF recomeça ali). Fila da câmera, travada.
  private func continuousFocusLocked(_ cam: AVCaptureDevice, force: Bool = false) {
    guard force || !manualFocus, cam.isFocusModeSupported(.continuousAutoFocus) else { return }
    focusGen += 1; focusHeld = false
    if cam.isFocusPointOfInterestSupported { cam.focusPointOfInterest = cam.focusPointOfInterest }
    cam.focusMode = .continuousAutoFocus
  }
  // LENTE NOVA CHEGA EM FOCO (0.8.9): medido nos trechos da 0.8.6–0.8.8, a principal ficava ~0,8 s PARADA (L0,922) depois
  // da troca vinda do 0,5× e só então procurava = "sai focado do 0,5 e chega desfocado". Na troca: UM foco na hora
  // (one-shot — o foco por fase da lente nova acha em ~0,1–0,3 s) e, assentou, contínuo de novo, sem mexer no ponto. Não é
  // o "reafirmar o contínuo" da 0.8.4 (que reiniciava a busca 0,4–0,7 s DEPOIS, com a lente já focada): aqui a busca é já.
  private var lastPrimary: AVCaptureDevice.DeviceType?
  private var lensFocus: (gen: Int, t0: Double, l0: Float, moved: Bool, from: String, to: String)?
  private func focusNewLens(_ cam: AVCaptureDevice) {
    let type = cam.activePrimaryConstituent?.deviceType
    let before = lastPrimary; lastPrimary = type
    guard let before, let type, before != type, cam.position == .back, !manualFocus,
      cam.isFocusModeSupported(.autoFocus), cam.isFocusModeSupported(.continuousAutoFocus) else { return }
    focusGen += 1
    lensFocus = (focusGen, CACurrentMediaTime(), cam.lensPosition, false, LensMatch.name(before), LensMatch.name(type))
    _ = CowboyObjC.catching { if (try? cam.lockForConfiguration()) != nil { cam.focusMode = .autoFocus; cam.unlockForConfiguration() } }
    queue.asyncAfter(deadline: .now() + 0.04) { self.lensFocusTick() }
  }
  private func lensFocusTick() {
    guard var w = lensFocus, let cam = device else { return }
    guard w.gen == focusGen else { lensFocus = nil; return }   // toque/zoom/foco manual assumiu: não mexe
    if cam.isAdjustingFocus { w.moved = true; lensFocus = w }
    let el = CACurrentMediaTime() - w.t0
    guard (w.moved && !cam.isAdjustingFocus) || el > 1.2 else { queue.asyncAfter(deadline: .now() + 0.04) { self.lensFocusTick() }; return }
    lensFocus = nil
    if !manualFocus { _ = CowboyObjC.catching { if (try? cam.lockForConfiguration()) != nil { cam.focusMode = .continuousAutoFocus; cam.unlockForConfiguration() } } }
    Diag.step("focus-new-lens", ["de": w.from, "para": w.to, "ms": Int(el * 1000), "L": String(format: "%.3f>%.3f", w.l0, cam.lensPosition), "achou": w.moved])
  }
  static func thermalName() -> String {
    switch ProcessInfo.processInfo.thermalState { case .nominal: return "normal"; case .fair: return "morno"; case .serious: return "quente"; case .critical: return "crítico"; @unknown default: return "?" }
  }
  // parado (sem gravar) e o aparelho morno ou quente: 30 qps (metade do trabalho do sensor, da estabilização e da tela)
  private func applyIdleRate() {
    queue.async {
      guard self.configured, let cam = self.device, !self.isRecording else { return }
      let full = self.selectedProfile.fps
      // 0.8.7: só no CRÍTICO — a 30 qps o atraso da Extrema DOBRA (0,57 -> 1,08 s, medido nos trechos): zoom e tela lentos
      let hot = ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.critical.rawValue
      let slow = hot && full > 31 && cam.activeFormat.videoSupportedFrameRateRanges.contains { $0.minFrameRate <= 30.01 && $0.maxFrameRate >= 29.99 }
      guard slow != self.idleSlow else { return }
      self.idleSlow = slow
      let d = CMTime(seconds: 1 / (slow ? 30 : full), preferredTimescale: 600000)
      _ = CowboyObjC.catching { if (try? cam.lockForConfiguration()) != nil { cam.activeVideoMinFrameDuration = d; cam.activeVideoMaxFrameDuration = d; cam.unlockForConfiguration() } }
      Diag.step("idle-rate", ["qps": slow ? 30 : full, "calor": Self.thermalName()])
    }
  }
  private var pinchTarget: Double?
  static let ultraEdge = 0.99   // logo abaixo do 1× (onde a principal entraria)
  // digital só se o arquivo for convertido no iPhone (o shader amplia o quadro); senão a tela mostraria o que o arquivo não tem
  var maxDigital: Double { bake709 ? 2.0 : 1.0 }
  func followZoom(_ display: Double) {
    renderer.tapEnd()   // pinça: a tela volta pro zoom "na hora"
    pinchTarget = display; recenterFocus("zoom"); holdFocus(0.3)
    if ultraLock {
      let want = min(display, Self.ultraEdge * maxDigital)
      zoomDriver.setDigital(max(1, want / Self.ultraEdge))
      zoomDriver.follow(CGFloat(min(want, Self.ultraEdge)) * base)
      if want > Self.ultraEdge { zoom = want }   // o aparelho parou em 0,99×: o rótulo mostra o total
    } else {
      zoomDriver.setDigital(1)
      zoomDriver.follow(CGFloat(display) * base)
    }
  }
  // foco e luz de volta pro centro, contínuos (o ponto tocado antigo não vale mais depois de zoom ou de a cena mudar)
  func recenterFocus(_ why: String) {
    queue.async {
      guard self.pointFocused, let cam = self.device, !self.manualFocus else { return }
      self.pointFocused = false
      _ = CowboyObjC.catching {
        if (try? cam.lockForConfiguration()) != nil {
          let c = CGPoint(x: 0.5, y: 0.5)
          if cam.isFocusPointOfInterestSupported { cam.focusPointOfInterest = c }
          if cam.isExposurePointOfInterestSupported && cam.exposureMode != .locked && cam.exposureMode != .custom { cam.exposurePointOfInterest = c; cam.exposureMode = .continuousAutoExposure }
          cam.isSubjectAreaChangeMonitoringEnabled = false
          self.continuousFocusLocked(cam)
          cam.unlockForConfiguration()
        }
      }
      Diag.step("focus-center", ["por": why])
    }
  }
  func endZoomGesture() {
    holdFocus(0.3); zoomDriver.endFollow()
    // pinça que terminou no 0,5× = "está no 0,5": trava a ultra de novo (a próxima pinça vai pela 0,5)
    if let t = pinchTarget, t <= 0.51, !ultraLock {
      ultraLock = true; UserDefaults.standard.set(true, forKey: "ultraLock")
      queue.async { if let c = self.device { self.applyLensLock(c) } }
    }
    pinchTarget = nil
    let user = selfTestMode.hasPrefix("VOCÊ")
    if user { userPinches += 1 }
    if !recording && !calibrating && !selfTestMode.isEmpty { aligner?.startSettle(CACurrentMediaTime(), tag: user ? "pinça \(userPinches)" : selfTestMode) }
  }
  func selectZoom(_ value: Double) {
    renderer.tapStart(dz: zoomDriver.digital)   // toque: a tela mostra o quadro como ele é (zoom de edição, sem adivinhação)
    recenterFocus("zoom")
    let toUltra = value <= 0.51
    ultraLock = toUltra; UserDefaults.standard.set(toUltra, forKey: "ultraLock")
    queue.async {
      if let cam = self.device {
        // destrava ANTES de subir (pra cruzar as lentes); voltando pra 0,5 trava quando a ultra assumir (observador acima)
        if !toUltra { self.applyLensLock(cam, leaving: true) }
      }
      DispatchQueue.main.async {
        let sp = Self.zoomSpeeds[max(0, min(2, self.zoomSpeed))]
        let dur = self.zoomDriver.glide(to: CGFloat(value) * self.base, seconds: sp.seconds, floor: sp.floor)
        self.zoomDriver.leaveDigital(toRaw: value * Double(self.base), dur: dur)
        self.holdFocus(dur + 0.15)
        let tag = self.selfTestMode
        DispatchQueue.main.asyncAfter(deadline: .now() + dur) { if !self.recording && !self.calibrating && !tag.isEmpty { self.aligner?.startSettle(CACurrentMediaTime(), tag: tag) } }
      }
    }
  }

  // ---- TESTE DO ZOOM (v3): mede de 0,3 s ANTES do zoom parar até 2 s depois, contra o quadro final (zoom relativo +
  // deslizamento + correção da estabilização da tela). Cliques EXATOS nas fronteiras do iPhone (1× = troca 0,5→1, 2× = modo
  // 48 MP do sensor, 5× = tele) × logo antes (1,97×), e no fim 3 pinças feitas pelo filmmaker. Ideal: "volta" ≈ 0.
  private var userPinches = 0
  private var selfTestGen = 0
  private var selfTestEnd: (() -> Void)?
  func finishSelfTest() { let f = selfTestEnd; selfTestEnd = nil; f?() }
  func runZoomSelfTest() {
    guard selfTest.isEmpty, ready, !recording else { return }
    let wasUltra = ultraLock, startZoom = zoom
    selfTestResults = [:]; userPinches = 0; selfTestGen += 1
    let gen = selfTestGen
    var steps: [(Double, () -> Void)] = []
    func say(_ t: String) { steps.append((0, { self.selfTest = t })) }
    func wait(_ s: Double) { steps.append((s, {})) }
    func tap(_ from: Double, _ to: Double) {
      steps.append((0, { self.selfTestMode = String(format: "clique %.2f→%.2f", from, to); self.selectZoom(to) })); wait(3.4)
    }
    selfTestEnd = {
      self.selfTestMode = ""
      let r = self.selfTestResults
      let txt = r.keys.sorted().map { k in String(format: "%@ %.2f%%", k, (r[k]!.max() ?? 0) * 100) }.joined(separator: " · ")
      Diag.step("zoom-selftest", ["volta_por_passo": txt])
      self.selfTest = "Pronto — obrigado! Resultado enviado."
      self.selectZoom(wasUltra ? 0.5 : startZoom)
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.selfTest = "" }
    }
    say("Teste do zoom: celular PARADO e apoiado, apontado pra uma cena com detalhes…")
    steps.append((0, {
      self.queue.async {
        guard let c = self.device else { return }
        let f = c.activeFormat
        Diag.step("zoom-selftest-info", ["camera": c.deviceType.rawValue, "trocas": c.virtualDeviceSwitchOverVideoZoomFactors.map { String(format: "%.2f", $0.doubleValue) }.joined(separator: ","),
          "sensor2x": f.secondaryNativeResolutionZoomFactors.map { String(format: "%.2f", Double($0)) }.joined(separator: ","), "formato": "\(CMVideoFormatDescriptionGetDimensions(f.formatDescription).width)x\(CMVideoFormatDescriptionGetDimensions(f.formatDescription).height)",
          "base": String(format: "%.2f", Double(self.base)), "estab_tela": self.renderer.lightPreview ? "propria" : "apple"])
      }
    }))
    steps.append((0, { self.selectZoom(1) })); wait(3.0)
    say("Teste 1/2 — cliques (automático, não toque)")
    tap(1, 2); tap(2, 1); tap(1, 1.97); tap(1.97, 1); tap(1, 5); tap(5, 1); tap(1, 0.5); tap(0.5, 1)
    steps.append((0, {
      self.selfTestMode = "VOCÊ pinça"
      self.selfTest = "Teste 2/2 — AGORA VOCÊ: faça 3 zooms com a PINÇA, do jeito que dá o tremido. Solte e espere 3 s entre um e outro."
      DispatchQueue.main.asyncAfter(deadline: .now() + 45) { if self.selfTestGen == gen { self.finishSelfTest() } }   // não fez as 3: encerra sozinho
    }))
    var t = 0.0
    for (delay, action) in steps { t += delay; DispatchQueue.main.asyncAfter(deadline: .now() + t, execute: action) }
  }
  func setLensMatch(_ on: Bool) { lensMatch?.setEnabled(on); lensMatchOn = on }
  func resetLensMatch() { lensMatch?.reset(); lensMatchStatus = [:] }
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
      self.focusGen += 1; self.focusHeld = false
      if manual {
        guard cam.isFocusModeSupported(.locked), cam.isLockingFocusWithCustomLensPositionSupported else { throw self.failure("Foco manual indisponível nesta lente") }
        cam.setFocusModeLocked(lensPosition: Float(max(0, min(1, position ?? Double(cam.lensPosition)))), completionHandler: nil)
      } else if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
      self.publish { self.manualFocus = manual; if let position { self.lensPosition = max(0, min(1, position)) } }
    }
  }
  // ponto na imagem mostrada (0–1 em x/y da tela) -> ponto do sensor
  func focusAt(normalized p0: CGPoint) {
    let angle = previewAngle, isFront = front
    // a tela mostra o quadro ESTABILIZADO = recorte do centro do campo do sensor (corte medido, ~1,12): o toque é levado pro
    // campo inteiro (0.8.1; antes o foco caía fora do toque, até ~5% perto das bordas)
    let c = max(1, min(1.4, renderer.displayCrop)) * max(1, zoomDriver.digital)
    let p = CGPoint(x: 0.5 + (p0.x - 0.5) / c, y: 0.5 + (p0.y - 0.5) / c)
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
    Diag.step("focus-tap", ["toque": String(format: "%.3f,%.3f", p0.x, p0.y), "sensor": String(format: "%.3f,%.3f", point.x, point.y), "corte": String(format: "%.3f", c)])
    control { cam in
      self.focusGen += 1; self.focusHeld = false
      // contínuo NO PONTO (segue o assunto se ele chegar perto/longe), até a cena mudar ou um zoom
      if cam.isFocusPointOfInterestSupported && cam.isFocusModeSupported(.autoFocus) {
        cam.focusPointOfInterest = point
        self.continuousFocusLocked(cam, force: true)   // contínuo no ponto tocado
        self.publish { self.manualFocus = false }
      }
      if cam.isExposurePointOfInterestSupported && cam.exposureMode != .locked && cam.exposureMode != .custom {
        cam.exposurePointOfInterest = point; cam.exposureMode = .continuousAutoExposure
      }
      cam.isSubjectAreaChangeMonitoringEnabled = true
      self.pointFocused = true
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
    let fxLive = motionBlur && !fxRender, fxRend = motionBlur && fxRender, fxDeg = blurAngle
    let horizon: Double? = rotation.map { Double($0.videoRotationAngleForHorizonLevelCapture) }   // lido na thread principal
    queue.async {
      guard self.configured, self.session.isRunning, !self.isRecording, let cam = self.device else { return }
      do {
        Diag.step("record-tap", ["codec": self.requestedCodec.rawValue, "fmt": self.selectedProfile.label, "log": self.requestedLog])
        if self.idleSlow {
          self.idleSlow = false
          let fps = self.selectedProfile.fps, d = CMTime(seconds: 1 / fps, preferredTimescale: 600000)
          _ = CowboyObjC.catching { if (try? cam.lockForConfiguration()) != nil { cam.activeVideoMinFrameDuration = d; cam.activeVideoMaxFrameDuration = d; cam.unlockForConfiguration() } }
          self.dataQueue.sync { self.recCadence = fps; self.recCadenceUntil = CACurrentMediaTime() + 1.3 }
          Diag.step("idle-rate", ["qps": fps, "por": "gravar"])
        }
        let source: SourceColor = self.requestedLog ? .appleLog : self.requestedHDR ? .hlg : .sdr
        let bakeFn = self.bake709 ? ColorMath.previewTransform(source: source, rawLog: false, look: look) : nil
        let incoming = (self.videoOut.videoSettings?[kCVPixelBufferPixelFormatTypeKey as String] as? NSNumber)?.uint32Value ?? CMFormatDescriptionGetMediaSubType(cam.activeFormat.formatDescription)
        if bakeFn != nil && !LutBaker.supports(incoming) { Diag.step("bake-unsupported", ["fmt": incoming]) }
        let baker = LutBaker.supports(incoming) ? bakeFn.flatMap { LutBaker(transform: $0) } : nil
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
        // efeitos (0.8.9): live = já no arquivo; render = a VPS aplica pelo arquivo .fx; live sem conversão no iPhone = só na tela
        meta["efeitos"] = fxRend ? "render" : fxLive ? (baker != nil ? "live" : "live-so-tela") : "off"
        if fxLive || fxRend { meta["desfoque"] = "\(fxDeg)°" }
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
            self.fileBlur = fxLive && baker != nil; self.fxLogOn = false; self.fxBuffer = ""; self.fxLines = 0; self.lastFileFrame = nil; self.fileXF = nil; self.writerStall = 0
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
          self.fileBlur = fxLive && baker != nil; self.fxLogOn = fxRend; self.fxBuffer = ""; self.fxLines = 0; self.lastFileFrame = nil; self.fileXF = nil; self.writerStall = 0
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
      self.applyIdleRate()
      if let b = self.recBaker, b.failures > 0 { Diag.step("bake-failures", ["n": b.failures, "err": b.lastError]) }
      self.recBaker = nil
      let fx = self.fxBuffer, fxN = self.fxLines
      self.fxBuffer = ""; self.fxLines = 0; self.fileBlur = false; self.fxLogOn = false; self.lastFileFrame = nil; self.fileXF = nil
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
      if !fx.isEmpty { CloudStream.shared.side(cid, kind: "fx", data: Data(fx.utf8)); Diag.step("fx-file", ["linhas": fxN]) }
      if let meta = self.spaceMeta?() {
        var space = meta; space["camera"] = self.lensName; space["source"] = "ios-native"; space["fov_long_deg"] = self.fieldOfView; space["dropped_frames"] = dropped
        if let data = try? JSONSerialization.data(withJSONObject: space) { CloudStream.shared.side(cid, kind: "space", data: data) }
      }
      self.publish { self.recording = false; self.finishing = true }
      writer.finish { ok in
        gyro?.close()
        if (gyro?.lines ?? 0) == 0 { try? FileManager.default.removeItem(at: CloudStream.shared.sideFile(cid, kind: "gcsv")) }
        CloudStream.shared.close(cid, durationMs: duration)
        Diag.step("stop-stream", ["ok": ok, "ms": duration, "dropped": dropped, "pedacos": writer.segs, "mb": writer.segBytes / 1_000_000, "v": writer.vOK, "a": writer.aOK, "a_fora": writer.aSkip, "status": writer.statusCode])
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

  // ---- garimpo dos dados por quadro (só diagnóstico, 1× por abertura): procura um valor de zoom/recorte que o iPhone
  // anexe a cada quadro — se existir, a prévia estabilizada passa a saber o zoom EXATO de cada quadro até no escuro
  private var metaScout = 0, metaScoutStab = 0, metaZoomLogs = 8, metaLastZoom = 0.0   // garimpo encerrado (0.7.8)
  static func flatMeta(_ sample: CMSampleBuffer, numbersOnly: Bool) -> String {
    var out: [String] = []
    func walk(_ prefix: String, _ v: Any) {
      if let d = v as? [String: Any] { for (k, x) in d.sorted(by: { $0.key < $1.key }) { walk(prefix.isEmpty ? k : prefix + "." + k, x) } }
      else if let n = v as? NSNumber { out.append(prefix + "=" + n.stringValue) }
      else if !numbersOnly {
        if let t = v as? String { out.append(prefix + "=" + String(t.prefix(40))) }
        else if let d = v as? Data { out.append(prefix + "=<\(d.count)B>") }
        else if let a = v as? [Any] { out.append(prefix + "=[\(a.count)]") }
        else { out.append(prefix + "=?") }
      }
    }
    if let a = CMCopyDictionaryOfAttachments(allocator: nil, target: sample, attachmentMode: kCMAttachmentMode_ShouldPropagate) as? [String: Any] { walk("sb", a) }
    if let a = CMCopyDictionaryOfAttachments(allocator: nil, target: sample, attachmentMode: kCMAttachmentMode_ShouldNotPropagate) as? [String: Any] { walk("sbn", a) }
    if let pb = CMSampleBufferGetImageBuffer(sample), let a = CVBufferCopyAttachments(pb, .shouldPropagate) as? [String: Any] { walk("pb", a) }
    return String(out.joined(separator: " ").prefix(3800))
  }
  private func scoutMeta(_ sample: CMSampleBuffer, fast: Bool) {
    if !fast { if metaScoutStab > 0 { metaScoutStab -= 1; Diag.step("frame-meta", ["saida": "estabilizada", "meta": Self.flatMeta(sample, numbersOnly: false)]) }; return }
    let z = Double(device?.videoZoomFactor ?? 0)
    let moving = abs(z - metaLastZoom) > 1e-4; metaLastZoom = z
    if metaScout > 0 { metaScout -= 1; Diag.step("frame-meta", ["saida": "rapida", "z": String(format: "%.4f", z), "meta": Self.flatMeta(sample, numbersOnly: false)]) }
    else if moving && metaZoomLogs < 8 {
      metaZoomLogs += 1
      Diag.step("frame-meta-zoom", ["z": String(format: "%.4f", z), "pts": String(format: "%.4f", CMSampleBufferGetPresentationTimeStamp(sample).seconds),
        "agora": String(format: "%.4f", CACurrentMediaTime()), "meta": Self.flatMeta(sample, numbersOnly: true)])
    }
  }

  // ---- quadros
  func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
    if output === fastOut {
      let t = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
      zoomDriver.frameTick(t)   // pinça: um passo de zoom por quadro capturado
      if metaScout > 0 || metaZoomLogs < 8 { scoutMeta(sampleBuffer, fast: true) }
      if let pb = CMSampleBufferGetImageBuffer(sampleBuffer) { renderer.pushFast(pb, pts: t) }
      return
    }
    if output === audioOut {
      meter(sampleBuffer)
      let clean = noise.process(sampleBuffer)   // roda sempre (a estimativa do ruído fica pronta antes de gravar)
      if !stopping { writer?.appendAudio(clean ?? sampleBuffer) }
      return
    }
    let pixel = CMSampleBufferGetImageBuffer(sampleBuffer)
    let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
    if metaScoutStab > 0 { scoutMeta(sampleBuffer, fast: false) }
    if let pixel { renderer.push(pixel, pts: pts.seconds) }
    let prevVideoPTS = lastVideoPTS; lastVideoPTS = pts.seconds
    guard let writer, !stopping else { return }
    // estava a 30 qps parada (aparelho quente): o arquivo só começa com os quadros já na cadência do formato
    if !writer.started, let want = recCadence {
      if pts.seconds - (prevVideoPTS ?? 0) > 1.5 / want && CACurrentMediaTime() < recCadenceUntil { return }
      recCadence = nil
    }
    // desfoque de movimento (0.8.9): Live = no shader do arquivo; Render = linha no arquivo de efeitos (a VPS aplica)
    var blur = BlurParams.none, stages = (1, 1)
    if fileBlur || fxLogOn, let pixel {
      blur = renderer.blurParams(at: pts.seconds, width: Double(CVPixelBufferGetWidth(pixel)), height: Double(CVPixelBufferGetHeight(pixel)))
      stages = blur.stages(cap: 12)
    }
    // troca de lente com o zoom parado (0.9.0): dissolve curto do último quadro da lente velha, em vez de ampliar/desampliar
    let sidNow = pixel.map { LensID.of($0) } ?? 0
    let geoNow = renderer.fileSwitchGeometry(pixel, pts: pts.seconds)
    if recBaker != nil, let lf = lastFileFrame, lf.sid != 0, sidNow != 0, lf.sid != sidNow, abs(renderer.contentZoomSpeed(at: pts.seconds)) < 0.4 { fileXF = (lf.pixel, pts.seconds, lf.geo) }
    var xfOld: CVPixelBuffer?, xfBlend: Float = 0, xfGeo = SwitchGeometry.identity
    if let x = fileXF {
      let a = (pts.seconds - x.t0) / PreviewRenderer.xfadeDur
      if a >= 1 || a < 0 { fileXF = nil } else { xfOld = x.pixel; xfBlend = Float(1 - a * a * (3 - 2 * a)); xfGeo = x.geo }
    }
    if let pixel, recBaker != nil { lastFileFrame = (pixel, sidNow, geoNow) }
    var baked: CMSampleBuffer?
    if let recBaker {
      baked = recBaker.convert(sampleBuffer, match: lensMatch?.correction(at: pts.seconds, lens: pixel.flatMap { LensID.name($0) }) ?? .identity, geo: geoNow,
        blur: fileBlur ? blur : .none, stages: stages, old: xfOld, blend: xfBlend, oldGeo: xfGeo)
      if baked == nil { return }   // quadro que não converteu é descartado (nunca entra Log no meio do Rec.709)
    }
    writer.appendVideo(baked ?? sampleBuffer)
    if recStart == nil, writer.started { recStart = pts; gyro?.begin(at: pts.seconds) }
    if fxLogOn, blur.active, let s = recStart { fxBuffer += MotionBlur.line(t: (pts - s).seconds, blur, stages: stages); fxLines += 1 }
    // gravador sem soltar pedaço nenhum (0.9.0): diagnóstico e, se o áudio não entra, fecha a faixa de áudio pro vídeo seguir
    if let s = recStart, writer.fileURL == nil, writer.segs == 0 {
      let el = (pts - s).seconds
      if writerStall == 0 && el > 3.5 {
        writerStall = 1
        let stuckAudio = writer.hasAudio && (writer.aOK == 0 || writer.aSkip > writer.aOK)
        Diag.step("writer-sem-pedacos", ["s": String(format: "%.1f", el), "v": writer.vOK, "v_drop": writer.dropped, "a": writer.aOK, "a_fora": writer.aSkip, "status": writer.statusCode, "solta_audio": stuckAudio])
        if stuckAudio { writer.endAudio() }
      } else if writerStall == 1 && el > 8 {
        writerStall = 2
        Diag.step("writer-sem-pedacos-2", ["v": writer.vOK, "v_drop": writer.dropped, "a": writer.aOK, "a_fora": writer.aSkip, "status": writer.statusCode])
        writer.endAudio()
      }
    }
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
