import AVFoundation
import Photos
import SwiftUI
import UIKit

// ÁREA DE FOTOGRAFIA (0.11.0, pedido do filmmaker 17/10: "área de fotografia além de vídeo com TODAS as funções da câmera,
// HDR, log/RAW nativo, o que de mais profissional se usa em foto"). Sessão PRÓPRIA (a de vídeo fecha antes, como no AR):
// nada aqui mexe no caminho de vídeo (Extrema, Log, troca de lente, nuvem).
// - Câmera virtual tripla (0,5 / 1 / 2 / 5 e pinça), troca de lente e foco 100% do iPhone (lição do vídeo: não brigar).
// - Formatos: HEIF (HDR inteligente + mapa de ganho, 10 bits), JPEG, Apple ProRAW (DNG, a "latitude de Log" da foto) e
//   RAW+HEIF. Resolução 12/24/48 MP (o que o formato da lente aceitar). Prioridade "Máxima" = fusão multi-quadro (Deep
//   Fusion / Smart HDR / noite automática); "Rápida" = disparo em sequência.
// - Flash, temporizador, compensação de luz (sol), toque = foco+luz no ponto, nível pela orientação real (RotationCoordinator).
// - Cada foto vai pra pasta do app (Documents/Fotos, base do editor) e, ligado, pra Fototeca (RAW+HEIF = um item só).
enum PhotoFormat: String, CaseIterable, Identifiable {
  case heif, jpeg, raw, rawHeif
  var id: String { rawValue }
  var label: String {
    switch self { case .heif: return "HEIF"; case .jpeg: return "JPEG"; case .raw: return "ProRAW"; case .rawHeif: return "RAW+HEIF" }
  }
  var needsRaw: Bool { self == .raw || self == .rawHeif }
}
extension PhotoCamera {
  // o que o disparo realmente grava neste lado (ProRAW escolhido na traseira vira HEIF na frontal sem RAW)
  var effectiveFormat: PhotoFormat { format.needsRaw && !rawSupported ? .heif : format }
}
enum PhotoFlash: Int, CaseIterable { case off, auto, on
  var icon: String { self == .off ? "bolt.slash" : self == .auto ? "bolt.badge.automatic" : "bolt.fill" }
  var mode: AVCaptureDevice.FlashMode { self == .off ? .off : self == .auto ? .auto : .on }
}

// PROPORÇÃO (0.11.1): 3:4 é o sensor inteiro; 1:1, 4:5 e 9:16 são recortes centrais (em pé; deitado vira 5:4 / 16:9, como
// no iPhone). A prévia escurece o que fica fora; o arquivo salvo já sai recortado e o RAW guarda o original inteiro com a
// proporção ao lado (`<id>.aspect`), que o editor aplica — revelar do DNG sai no mesmo quadro que foi fotografado.
enum PhotoAspect: String, CaseIterable, Identifiable {
  case full = "3:4", square = "1:1", r45 = "4:5", r916 = "9:16"
  var id: String { rawValue }
  var portrait: CGFloat { switch self { case .full: return 3.0 / 4; case .square: return 1; case .r45: return 0.8; case .r916: return 9.0 / 16 } }
  var next: PhotoAspect { let a = Self.allCases; return a[(a.firstIndex(of: self)! + 1) % a.count] }
  // recorte central desta proporção dentro de um quadro em pé (prévia)
  func rect(in r: CGRect) -> CGRect {
    let have = r.width / max(1, r.height), want = portrait
    if abs(have - want) < 0.001 { return r }
    if want < have { let w = r.height * want; return CGRect(x: r.midX - w / 2, y: r.minY, width: w, height: r.height) }
    let h = r.width / want; return CGRect(x: r.minX, y: r.midY - h / 2, width: r.width, height: h)
  }
  // recorte central da imagem já orientada (deitada = proporção invertida); sem mudança se já estiver nela
  func crop(_ img: CIImage) -> CIImage {
    guard self != .full else { return img }
    let e = img.extent, want = e.width > e.height ? 1 / portrait : portrait, have = e.width / max(1, e.height)
    guard abs(have - want) > 0.002 else { return img }
    var r = e
    if have > want { let w = (e.height * want).rounded(); r = CGRect(x: (e.midX - w / 2).rounded(), y: e.minY, width: w, height: e.height) }
    else { let h = (e.width / want).rounded(); r = CGRect(x: e.minX, y: (e.midY - h / 2).rounded(), width: e.width, height: h) }
    let c = img.cropped(to: r)
    return c.transformed(by: CGAffineTransform(translationX: -c.extent.minX, y: -c.extent.minY))
  }
}

// uma foto na pasta do app: arquivo principal (HEIF/JPEG ou DNG), RAW ao lado (se houver) e a versão editada
struct PhotoShot: Identifiable, Hashable {
  let id: String
  let main: URL
  let raw: URL?
  let date: Date
  var edited: URL? { let u = PhotoStore.dir.appendingPathComponent(id + "-ed.heic"); return FileManager.default.fileExists(atPath: u.path) ? u : nil }
  var isRaw: Bool { main.pathExtension.lowercased() == "dng" }
  // gerada pela IA (0.11.5): cada resultado vira um item da galeria do app na hora, salvo ou não na Fototeca
  var isAI: Bool { id.contains("-ia-") }
  // fonte da edição: o RAW quando existe (latitude), senão o processado
  var source: URL { raw ?? main }
}

enum PhotoStore {
  static var dir: URL {
    let d = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Fotos", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }
  static func all() -> [PhotoShot] {
    let fm = FileManager.default
    guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey]) else { return [] }
    var byID: [String: (main: URL?, raw: URL?, date: Date)] = [:]
    for f in files {
      let name = f.deletingPathExtension().lastPathComponent, ext = f.pathExtension.lowercased()
      guard !name.hasSuffix("-ed") else { continue }
      let date = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
      var e = byID[name] ?? (nil, nil, date)
      if ext == "dng" { e.raw = f } else if ["heic", "jpg", "jpeg"].contains(ext) { e.main = f }
      e.date = min(e.date, date); byID[name] = e
    }
    return byID.compactMap { id, e in
      guard let m = e.main ?? e.raw else { return nil }
      return PhotoShot(id: id, main: m, raw: e.main == nil ? nil : e.raw, date: e.date)
    }.sorted { $0.date > $1.date }
  }
  private static func removeFiles(_ s: PhotoShot) {
    for u in [s.main, s.raw, s.edited, dir.appendingPathComponent(s.id + ".aspect"), dir.appendingPathComponent(s.id + ".assets")].compactMap({ $0 }) { try? FileManager.default.removeItem(at: u) }
  }
  // APAGAR (0.11.5): cada foto que o app põe na Fototeca guarda o identificador do item em `<id>.assets` (original e a
  // revelada). Apagar "do app e da Fototeca" pede leitura+escrita da Fototeca e o iOS mostra a confirmação dele; lá o item
  // vai pra "Apagados Recentemente" (30 dias). Cancelou a confirmação do iOS = nada sai, nem do app.
  // Fotos de antes da 0.11.5 não têm o identificador: saem só do app.
  static func libraryIDs(_ id: String) -> [String] {
    ((try? String(contentsOf: dir.appendingPathComponent(id + ".assets"), encoding: .utf8)) ?? "")
      .split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }
  private static func remember(_ localID: String, for id: String) {
    let ids = libraryIDs(id) + [localID]
    try? ids.joined(separator: "\n").write(to: dir.appendingPathComponent(id + ".assets"), atomically: true, encoding: .utf8)
  }
  // done(quantas saíram do app, aviso) — sempre na main
  static func delete(_ shots: [PhotoShot], fromLibrary: Bool, done: @escaping (Int, String?) -> Void) {
    let main: (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }
    let ids = fromLibrary ? shots.flatMap { libraryIDs($0.id) } : []
    let semID = shots.filter { libraryIDs($0.id).isEmpty }.count
    func local(_ note: String?) {
      shots.forEach(removeFiles)
      Diag.step("photo-delete", ["fotos": shots.count, "fototeca": fromLibrary, "itens_fototeca": ids.count, "aviso": note ?? ""])
      main { done(shots.count, note) }
    }
    let oldNote: String? = fromLibrary && semID > 0 ? (semID == 1 ? "1 foto antiga só saiu do app (apague na Fototeca)" : "\(semID) fotos antigas só saíram do app (apague na Fototeca)") : nil
    guard !ids.isEmpty else { local(oldNote); return }
    PHPhotoLibrary.requestAuthorization(for: .readWrite) { st in
      guard st == .authorized || st == .limited else { local("Saiu do app; sem permissão pra apagar na Fototeca"); return }
      let assets = PHAsset.fetchAssets(withLocalIdentifiers: ids, options: nil)
      guard assets.count > 0 else { local(oldNote); return }
      PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.deleteAssets(assets) }) { ok, err in
        if ok { local(oldNote) }
        else { Diag.step("photo-delete", ["fotos": 0, "cancelado": true, "erro": err?.localizedDescription ?? ""]); main { done(0, "Cancelado — nada foi apagado") } }
      }
    }
  }
  // resultado da IA → `<foto>-ia-<hora>.heic` na pasta do app (fica como "temporária": só no app até o Salvar mandar pra Fototeca)
  static func saveAI(_ data: Data, from id: String) -> PhotoShot? {
    let rootID = id.components(separatedBy: "-ia-").first ?? id
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"; f.locale = Locale(identifier: "en_US_POSIX")
    let newID = rootID + "-ia-" + f.string(from: Date())
    let u = dir.appendingPathComponent(newID + ".heic")
    guard (try? data.write(to: u, options: .atomic)) != nil else { return nil }
    return PhotoShot(id: newID, main: u, raw: nil, date: Date())
  }
  static func aspect(_ id: String) -> PhotoAspect {
    (try? String(contentsOf: dir.appendingPathComponent(id + ".aspect"), encoding: .utf8)).flatMap { PhotoAspect(rawValue: $0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? .full
  }
  private static let cropContext = CIContext(options: [.cacheIntermediates: false])
  // arquivo recortado na proporção (HEIF 10 bits P3, ou JPEG se o original era JPEG), metadados do original com orientação 1
  static func cropped(_ src: URL, aspect: PhotoAspect, to dst: URL) -> Bool {
    var img: CIImage?
    if src.pathExtension.lowercased() == "dng", let d = try? Data(contentsOf: src) { img = CIRAWFilter(imageData: d, identifierHint: "com.adobe.raw-image")?.outputImage }
    else { img = CIImage(contentsOf: src, options: [.applyOrientationProperty: true]) }
    guard let base = img, let cs = CGColorSpace(name: CGColorSpace.displayP3) else { return false }
    var props = base.properties; props[kCGImagePropertyOrientation as String] = 1
    let c = aspect.crop(base).settingProperties(props)
    let data: Data?
    if dst.pathExtension.lowercased() == "jpg" { data = cropContext.jpegRepresentation(of: c, colorSpace: cs, options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: 0.92]) }
    else { data = (try? cropContext.heif10Representation(of: c, colorSpace: cs, options: [:])) ?? cropContext.heifRepresentation(of: c, format: .RGBA8, colorSpace: cs, options: [:]) }
    guard let data, (try? data.write(to: dst, options: .atomic)) != nil else { return false }
    return true
  }
  static func thumbnail(_ url: URL, size: CGFloat = 240) -> UIImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: size]
    return CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary).map { UIImage(cgImage: $0) }
  }
  // Fototeca (só adicionar): principal + RAW como item único (o app Fotos mostra o processado e guarda o DNG junto)
  private final class IDBox: @unchecked Sendable { var value: String? }
  static func saveToLibrary(main: URL, raw: URL?, shotID: String, done: @escaping (Bool, String?) -> Void) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { st in
      guard st == .authorized || st == .limited else { done(false, "sem permissão da Fototeca"); return }
      let box = IDBox()
      PHPhotoLibrary.shared().performChanges({
        let r = PHAssetCreationRequest.forAsset()
        r.addResource(with: .photo, fileURL: main, options: nil)
        if let raw, raw != main { r.addResource(with: .alternatePhoto, fileURL: raw, options: nil) }
        box.value = r.placeholderForCreatedAsset?.localIdentifier
      }) { ok, err in
        if ok, let lid = box.value { remember(lid, for: shotID) }
        done(ok, err?.localizedDescription)
      }
    }
  }
}

final class PhotoCamera: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
  let session = AVCaptureSession()
  private let queue = DispatchQueue(label: "cowboy.photo.session", qos: .userInitiated)
  private let output = AVCapturePhotoOutput()
  private var device: AVCaptureDevice?
  private var base: CGFloat = 1                 // fator do aparelho que é o "1×" (a principal)
  private var coordinator: AVCaptureDevice.RotationCoordinator?
  weak var previewLayer: AVCaptureVideoPreviewLayer? { didSet { if let l = previewLayer { attach(l) } } }
  private let lock = NSLock()
  private var pending: [Int64: (processed: Data?, raw: Data?, t0: Double, format: PhotoFormat, mp: Int, aspect: PhotoAspect)] = [:]
  private var subjectObserver: NSObjectProtocol?

  @Published var ready = false
  @Published var status = "Abrindo a câmera de foto…"
  @Published var format: PhotoFormat = PhotoFormat(rawValue: UserDefaults.standard.string(forKey: "photoFormat") ?? "") ?? .heif { didSet { UserDefaults.standard.set(format.rawValue, forKey: "photoFormat"); queue.async { self.applyRaw() } } }
  // FRONTAL (0.11.5): a escolha frontal/traseira fica salva; resolução guardada POR LADO (a frontal só tem 12 MP na
  // maioria dos aparelhos e não pode apagar os 24/48 MP escolhidos na traseira). Padrão da frontal = a MAIOR resolução.
  @Published var position: AVCaptureDevice.Position = UserDefaults.standard.bool(forKey: "photoFront") ? .front : .back { didSet { UserDefaults.standard.set(position == .front, forKey: "photoFront") } }
  @Published var switching = false
  @Published var mirrorFront: Bool = UserDefaults.standard.bool(forKey: "photoMirrorFront") { didSet { UserDefaults.standard.set(mirrorFront, forKey: "photoMirrorFront") } }
  private static func mpKey(_ p: AVCaptureDevice.Position) -> String { p == .front ? "photoMPFront" : "photoMP" }
  @Published var megapixels: Int = UserDefaults.standard.object(forKey: PhotoCamera.mpKey(UserDefaults.standard.bool(forKey: "photoFront") ? .front : .back)) as? Int ?? 24 { didSet { UserDefaults.standard.set(megapixels, forKey: Self.mpKey(position)) } }
  @Published var mpOptions: [Int] = [12]
  @Published var rawSupported = false
  @Published var flash: PhotoFlash = PhotoFlash(rawValue: UserDefaults.standard.integer(forKey: "photoFlash")) ?? .off { didSet { UserDefaults.standard.set(flash.rawValue, forKey: "photoFlash") } }
  @Published var flashAvailable = false
  @Published var maxQuality: Bool = UserDefaults.standard.object(forKey: "photoMaxQ") as? Bool ?? true { didSet { UserDefaults.standard.set(maxQuality, forKey: "photoMaxQ"); let on = !maxQuality; queue.async { self.applyResponsive(on) } } }
  @Published var timer: Int = UserDefaults.standard.integer(forKey: "photoTimer") { didSet { UserDefaults.standard.set(timer, forKey: "photoTimer") } }
  @Published var saveToPhotos: Bool = UserDefaults.standard.object(forKey: "photoToLibrary") as? Bool ?? true { didSet { UserDefaults.standard.set(saveToPhotos, forKey: "photoToLibrary") } }
  @Published var aspect: PhotoAspect = PhotoAspect(rawValue: UserDefaults.standard.string(forKey: "photoAspect") ?? "") ?? .full { didSet { UserDefaults.standard.set(aspect.rawValue, forKey: "photoAspect") } }
  @Published var zoom: Double = 1
  @Published var minZoom: Double = 1
  @Published var maxZoom: Double = 10
  @Published var lenses: [Double] = [1]
  @Published var exposureBias: Double = 0
  @Published var minBias: Double = -4
  @Published var maxBias: Double = 4
  @Published var inFlight = 0
  @Published var countdown = 0
  @Published var shutterBlink = 0
  @Published var lastShot: PhotoShot? = PhotoStore.all().first { !$0.isAI }
  @Published var lastThumb: UIImage?

  private func publish(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }

  func start() {
    PhotoRelease.begin()
    let want = position
    Task {
      guard await AVCaptureDevice.requestAccess(for: .video) else { publish { self.status = "Libere a câmera nos Ajustes do iPhone" }; return }
      queue.async {
        self.configure(want)
        if !self.session.isRunning { self.session.startRunning() }
        let ok = self.session.isRunning
        self.publish { self.ready = ok; self.status = ok ? "" : "Câmera de foto indisponível" }
      }
    }
    if let s = lastShot { DispatchQueue.global(qos: .utility).async { let t = PhotoStore.thumbnail(s.main, size: 160); self.publish { self.lastThumb = t } } }
  }
  func stop(_ done: (() -> Void)? = nil) {
    queue.async {
      if self.session.isRunning { self.session.stopRunning() }
      // 0.11.9: SOLTA a câmera. A sessão de foto ficava com a traseira como entrada depois de parar e, ao fechar, devolvia o
      // espaço de cor dela (HLG) DEPOIS que o vídeo já tinha posto Apple Log = tela/arquivo com cor e luz distorcidas
      // (medido 22/10: photo-back cor 2 quando a foto terminou na traseira; cor 3 quando terminou na frontal).
      self.session.beginConfiguration()
      self.session.inputs.forEach { self.session.removeInput($0) }
      self.session.commitConfiguration()
      PhotoRelease.end()
      DispatchQueue.main.async { self.ready = false; done?() }
    }
  }

  private func configure(_ want: AVCaptureDevice.Position) {
    guard session.inputs.isEmpty else { return }
    if !useCamera(want) && want == .front { _ = useCamera(.back) }   // frontal indisponível: abre a traseira
  }
  // vira a câmera (frontal ↔ traseira) na MESMA sessão: troca só a entrada, a saída de foto fica
  func flip() {
    guard ready, !switching, countdown == 0, inFlight == 0 else { return }
    let to: AVCaptureDevice.Position = position == .back ? .front : .back
    switching = true
    queue.async {
      let ok = self.useCamera(to)
      self.publish { self.switching = false; if !ok { self.status = to == .front ? "Câmera frontal indisponível" : "Câmera traseira indisponível" } }
    }
  }
  @discardableResult private func useCamera(_ pos: AVCaptureDevice.Position) -> Bool {
    let types: [AVCaptureDevice.DeviceType] = pos == .front
      ? [.builtInTrueDepthCamera, .builtInWideAngleCamera]
      : [.builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera, .builtInWideAngleCamera]
    guard let cam = AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: pos).devices.first,
          let input = try? AVCaptureDeviceInput(device: cam) else {
      publish { self.status = pos == .front ? "Não deu pra abrir a câmera frontal" : "Não deu pra abrir a câmera traseira" }; return false
    }
    session.beginConfiguration()
    let old = session.inputs
    old.forEach { session.removeInput($0) }
    if session.sessionPreset != .photo && session.canSetSessionPreset(.photo) { session.sessionPreset = .photo }
    guard session.canAddInput(input), session.outputs.contains(output) || session.canAddOutput(output) else {
      old.forEach { if session.canAddInput($0) { session.addInput($0) } }
      session.commitConfiguration()
      publish { self.status = pos == .front ? "Não deu pra abrir a câmera frontal" : "Não deu pra abrir a câmera traseira" }; return false
    }
    session.addInput(input)
    if !session.outputs.contains(output) { session.addOutput(output) }
    session.commitConfiguration()   // formato da lente nova (preset .photo) já valendo antes de ler resolução/zoom
    if let o = subjectObserver { NotificationCenter.default.removeObserver(o); subjectObserver = nil }
    device = cam
    // 48 MP quando a lente/formato aceita (14 Pro em diante); o pedido de cada foto escolhe 12/24/48
    let dims = cam.activeFormat.supportedMaxPhotoDimensions
    if let big = dims.max(by: { Int($0.width) * Int($0.height) < Int($1.width) * Int($1.height) }) { _ = CowboyObjC.catching { self.output.maxPhotoDimensions = big } }
    let mps = Array(Set(dims.map { Self.mp($0) })).sorted()
    output.maxPhotoQualityPrioritization = .quality
    let rawOK = output.isAppleProRAWSupported
    applyResponsive(!maxQuality)
    applyRaw()
    // zoom: 1× = a principal (fator de troca ultra→principal); ultra = 0,5×
    let switches = cam.virtualDeviceSwitchOverVideoZoomFactors.map { CGFloat(truncating: $0) }
    base = cam.isVirtualDevice && [.builtInTripleCamera, .builtInDualWideCamera].contains(cam.deviceType) ? (switches.first ?? 1) : 1
    var ls: [Double] = []
    if base > 1 { ls.append(Double(1 / base)) }
    ls.append(1)
    if mps.contains(where: { $0 >= 40 }) || cam.deviceType == .builtInTripleCamera { ls.append(2) }   // 2× = recorte do sensor de 48 MP
    if cam.deviceType == .builtInTripleCamera, switches.count > 1 { ls.append(Double(switches[1] / base)) }
    if (try? cam.lockForConfiguration()) != nil {
      if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
      if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
      if cam.isVirtualDevice { _ = CowboyObjC.catching { cam.setPrimaryConstituentDeviceSwitchingBehavior(.auto, restrictedSwitchingBehaviorConditions: []) } }
      cam.isSubjectAreaChangeMonitoringEnabled = true
      cam.videoZoomFactor = max(cam.minAvailableVideoZoomFactor, min(base, cam.maxAvailableVideoZoomFactor))
      cam.unlockForConfiguration()
    }
    subjectObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.subjectAreaDidChangeNotification, object: cam, queue: nil) { [weak self] _ in self?.recenter() }
    let minZ = Double(cam.minAvailableVideoZoomFactor / base), maxZ = Double(min(cam.maxAvailableVideoZoomFactor, base * 25) / base)
    // frontal: o "flash" é a tela acesa (Retina Flash), que a saída de foto oferece como modo de flash
    let flashOK = cam.hasFlash || output.supportedFlashModes.contains(.on), lo = Double(cam.minExposureTargetBias), hi = Double(cam.maxExposureTargetBias)
    Diag.step("photo-open", ["lado": pos == .front ? "frontal" : "traseira", "device": cam.deviceType.rawValue, "mp": mps.map(String.init).joined(separator: "/"), "raw": rawOK, "base": String(format: "%.2f", Double(base))])
    publish {
      self.position = pos
      self.mpOptions = mps.isEmpty ? [12] : mps
      // resolução deste lado: a salva; sem salva, traseira = 24 MP e frontal = a maior que ela tem
      let saved = UserDefaults.standard.object(forKey: Self.mpKey(pos)) as? Int
      let fallback = pos == .front ? (self.mpOptions.last ?? 12) : (self.mpOptions.contains(24) ? 24 : (self.mpOptions.last ?? 12))
      self.megapixels = saved.flatMap { self.mpOptions.contains($0) ? $0 : nil } ?? fallback
      // sem ProRAW neste lado o disparo sai em HEIF, mas a escolha (ProRAW) fica guardada pro outro lado
      self.rawSupported = rawOK
      self.lenses = ls; self.minZoom = minZ; self.maxZoom = maxZ; self.zoom = 1
      self.flashAvailable = flashOK; self.minBias = max(-4, lo); self.maxBias = min(4, hi)
      if let l = self.previewLayer { self.attach(l) }   // a camada nasce antes da sessão ter câmera: gira a prévia agora
    }
    return true
  }
  // rótulo comercial: 8064×6048 = 48,8 milhões de pontos = "48 MP"; 5712×4284 = "24 MP"
  static func mp(_ d: CMVideoDimensions) -> Int { let m = Double(d.width) * Double(d.height) / 1e6; return m >= 40 ? 48 : m >= 20 ? 24 : m >= 15 ? 18 : m >= 10 ? 12 : max(1, Int(m.rounded())) }
  // CALOR (0.11.2): a captura responsiva + priorização rápida mantêm um buffer de quadros sendo processado o tempo todo (o
  // celular esquentou em 1,5 min no modo foto da 0.11.0). Só ligadas no "Disparo rápido"; na "Qualidade máxima" a foto
  // demora um pouco mais pra liberar o próximo disparo, mas o aparelho fica frio.
  private func applyResponsive(_ on: Bool) {
    _ = CowboyObjC.catching {
      // a rápida depende da responsiva: liga responsiva → rápida; desliga rápida → responsiva
      if !on && self.output.isFastCapturePrioritizationEnabled { self.output.isFastCapturePrioritizationEnabled = false }
      if self.output.isResponsiveCaptureSupported && self.output.isResponsiveCaptureEnabled != on { self.output.isResponsiveCaptureEnabled = on }
      if on && self.output.isFastCapturePrioritizationSupported { self.output.isFastCapturePrioritizationEnabled = true }
    }
  }
  private func applyRaw() {
    guard output.isAppleProRAWSupported else { return }
    let want = format.needsRaw
    if output.isAppleProRAWEnabled != want { _ = CowboyObjC.catching { self.output.isAppleProRAWEnabled = want } }
  }
  private func attach(_ layer: AVCaptureVideoPreviewLayer) {
    queue.async {
      guard let cam = self.device else { return }
      DispatchQueue.main.async {
        let c = AVCaptureDevice.RotationCoordinator(device: cam, previewLayer: layer)
        self.coordinator = c
        if let conn = layer.connection, conn.isVideoRotationAngleSupported(c.videoRotationAngleForHorizonLevelPreview) { conn.videoRotationAngle = c.videoRotationAngleForHorizonLevelPreview }
      }
    }
  }

  // ---------------------------------------------------------------- zoom, foco, luz
  func setZoom(_ z: Double, animated: Bool = false) {
    let zz = max(minZoom, min(maxZoom, z)); zoom = zz
    queue.async {
      guard let cam = self.device, (try? cam.lockForConfiguration()) != nil else { return }
      let f = max(cam.minAvailableVideoZoomFactor, min(cam.maxAvailableVideoZoomFactor, CGFloat(zz) * self.base))
      if animated { cam.ramp(toVideoZoomFactor: f, withRate: 12) } else { cam.cancelVideoZoomRamp(); cam.videoZoomFactor = f }
      cam.unlockForConfiguration()
    }
  }
  // ponto em coordenadas da camada da prévia
  func focus(atLayerPoint p: CGPoint) {
    guard let layer = previewLayer else { return }
    let dp = layer.captureDevicePointConverted(fromLayerPoint: p)
    queue.async {
      guard let cam = self.device, (try? cam.lockForConfiguration()) != nil else { return }
      if cam.isFocusPointOfInterestSupported { cam.focusPointOfInterest = dp }
      if cam.isFocusModeSupported(.continuousAutoFocus) { cam.focusMode = .continuousAutoFocus }
      if cam.isExposurePointOfInterestSupported { cam.exposurePointOfInterest = dp }
      if cam.isExposureModeSupported(.continuousAutoExposure) { cam.exposureMode = .continuousAutoExposure }
      cam.unlockForConfiguration()
    }
  }
  private func recenter() {
    queue.async {
      guard let cam = self.device, (try? cam.lockForConfiguration()) != nil else { return }
      let c = CGPoint(x: 0.5, y: 0.5)
      if cam.isFocusPointOfInterestSupported { cam.focusPointOfInterest = c }
      if cam.isExposurePointOfInterestSupported { cam.exposurePointOfInterest = c }
      cam.unlockForConfiguration()
    }
  }
  func setBias(_ v: Double) {
    let b = max(minBias, min(maxBias, v)); exposureBias = b
    queue.async {
      guard let cam = self.device, (try? cam.lockForConfiguration()) != nil else { return }
      cam.setExposureTargetBias(Float(b), completionHandler: nil)
      cam.unlockForConfiguration()
    }
  }

  // ---------------------------------------------------------------- disparo
  func shoot() {
    guard ready, !switching else { return }
    let angle = coordinator?.videoRotationAngleForHorizonLevelCapture ?? 90
    if timer > 0 {
      countdown = timer
      func tick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
          guard self.countdown > 0 else { return }
          self.countdown -= 1
          if self.countdown == 0 { self.capture(angle: self.coordinator?.videoRotationAngleForHorizonLevelCapture ?? angle) } else { tick() }
        }
      }
      tick()
    } else { capture(angle: angle) }
  }
  func cancelTimer() { countdown = 0 }
  // depois de apagar na galeria/revelação: miniatura do botão de fotos = a mais nova que sobrou
  func refreshLast() {
    let s = PhotoStore.all().first { !$0.isAI }
    lastShot = s
    guard let s else { lastThumb = nil; return }
    DispatchQueue.global(qos: .utility).async { let t = PhotoStore.thumbnail(s.edited ?? s.main, size: 160); self.publish { if self.lastShot?.id == s.id { self.lastThumb = t } } }
  }
  private func capture(angle: CGFloat) {
    let fmt = format, mp = megapixels, fl = flash, maxQ = maxQuality, asp = aspect, mirror = position == .front && mirrorFront
    inFlight += 1
    queue.async {
      guard self.device != nil else { self.publish { self.inFlight = max(0, self.inFlight - 1) }; return }
      let rawType = self.output.availableRawPhotoPixelFormatTypes.first { AVCapturePhotoOutput.isAppleProRAWPixelFormat($0) }
      let hevc = self.output.availablePhotoCodecTypes.contains(.hevc)
      var used = fmt
      let s: AVCapturePhotoSettings
      switch fmt {
      case .raw where rawType != nil: s = AVCapturePhotoSettings(rawPixelFormatType: rawType!)
      case .rawHeif where rawType != nil: s = AVCapturePhotoSettings(rawPixelFormatType: rawType!, processedFormat: [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.jpeg])
      case .jpeg: s = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.jpeg])
      default: used = hevc ? .heif : .jpeg; s = AVCapturePhotoSettings(format: [AVVideoCodecKey: hevc ? AVVideoCodecType.hevc : AVVideoCodecType.jpeg])
      }
      // resolução pedida (a mais próxima que o formato aceita, sem passar do máximo da saída)
      if let cam = self.device {
        let dims = cam.activeFormat.supportedMaxPhotoDimensions.filter { Int($0.width) * Int($0.height) <= Int(self.output.maxPhotoDimensions.width) * Int(self.output.maxPhotoDimensions.height) }
        if let d = dims.first(where: { Self.mp($0) == mp }) ?? dims.min(by: { abs(Self.mp($0) - mp) < abs(Self.mp($1) - mp) }) { s.maxPhotoDimensions = d }
      }
      s.photoQualityPrioritization = maxQ ? .quality : .balanced
      if self.output.supportedFlashModes.contains(fl.mode) { s.flashMode = fl.mode }
      if let conn = self.output.connection(with: .video) {
        if conn.isVideoRotationAngleSupported(angle) { conn.videoRotationAngle = angle }
        // frontal: igual ao iPhone de fábrica = a foto sai como o mundo vê (não espelhada); "Espelhar frontal" = como na prévia
        if conn.isVideoMirroringSupported { conn.automaticallyAdjustsVideoMirroring = false; conn.isVideoMirrored = mirror }
      }
      self.lock.lock(); self.pending[s.uniqueID] = (nil, nil, CACurrentMediaTime(), used, mp, asp); self.lock.unlock()
      if CowboyObjC.catching({ self.output.capturePhoto(with: s, delegate: self) }) != nil {
        self.lock.lock(); self.pending[s.uniqueID] = nil; self.lock.unlock()
        Diag.step("photo-fail", ["etapa": "capturePhoto", "formato": used.label])
        self.publish { self.inFlight = max(0, self.inFlight - 1); self.status = "A foto falhou — tente de novo" }
      }
    }
  }
  func photoOutput(_ output: AVCapturePhotoOutput, willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings) {
    publish { self.shutterBlink += 1 }
  }
  func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
    guard error == nil, let data = photo.fileDataRepresentation() else {
      Diag.step("photo-fail", ["etapa": "processar", "erro": error?.localizedDescription ?? "sem dados"]); return
    }
    let id = photo.resolvedSettings.uniqueID
    lock.lock()
    if var p = pending[id] { if photo.isRawPhoto { p.raw = data } else { p.processed = data }; pending[id] = p }
    lock.unlock()
  }
  func photoOutput(_ output: AVCapturePhotoOutput, didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings, error: Error?) {
    lock.lock(); let p = pending.removeValue(forKey: resolvedSettings.uniqueID); lock.unlock()
    publish { self.inFlight = max(0, self.inFlight - 1) }
    guard let p, p.processed != nil || p.raw != nil else { if error != nil { publish { self.status = "A foto falhou — tente de novo" } }; return }
    let f = DateFormatter(); f.dateFormat = "yyyyMMdd-HHmmss-SSS"; f.locale = Locale(identifier: "en_US_POSIX")
    let id = "IMG-" + f.string(from: Date())
    let dir = PhotoStore.dir
    var main: URL?, raw: URL?
    if let d = p.processed {
      let u = dir.appendingPathComponent(id + (p.format == .jpeg || (p.format != .heif && p.format != .rawHeif) ? ".jpg" : ".heic"))
      let isJPEG = d.starts(with: [0xFF, 0xD8])
      let fixed = isJPEG ? u.deletingPathExtension().appendingPathExtension("jpg") : u.deletingPathExtension().appendingPathExtension("heic")
      if (try? d.write(to: fixed)) != nil { main = fixed }
    }
    if let d = p.raw { let u = dir.appendingPathComponent(id + ".dng"); if (try? d.write(to: u)) != nil { raw = u } }
    guard var m = main ?? raw else { publish { self.status = "Sem espaço pra salvar a foto" }; return }
    // proporção: o principal sai recortado (só RAW = um HEIF recortado vira o principal e o DNG inteiro fica junto)
    var cropOK = true
    if p.aspect != .full {
      try? p.aspect.rawValue.write(to: dir.appendingPathComponent(id + ".aspect"), atomically: true, encoding: .utf8)
      let ext = main?.pathExtension.lowercased() == "jpg" ? "jpg" : "heic"
      let dst = dir.appendingPathComponent(id + ".crop." + ext)
      cropOK = PhotoStore.cropped(m, aspect: p.aspect, to: dst)
      if cropOK {
        let final = dir.appendingPathComponent(id + "." + ext)
        if let old = main { try? FileManager.default.removeItem(at: old) }
        if (try? FileManager.default.moveItem(at: dst, to: final)) != nil { m = final }
      }
    }
    let shot = PhotoShot(id: id, main: m, raw: m == raw ? nil : raw, date: Date())
    let ms = Int((CACurrentMediaTime() - p.t0) * 1000), bytes = (p.processed?.count ?? 0) + (p.raw?.count ?? 0)
    Diag.step("photo-shot", ["formato": p.format.label, "mp": p.mp, "ms": ms, "kb": bytes / 1024, "raw": raw != nil, "proporcao": p.aspect.rawValue, "recorte": cropOK])
    let thumb = PhotoStore.thumbnail(m, size: 160)
    publish { self.lastShot = shot; self.lastThumb = thumb }
    if saveToPhotos {
      PhotoStore.saveToLibrary(main: m, raw: shot.raw, shotID: id) { ok, err in if !ok { Diag.step("photo-save-fail", ["erro": err ?? "?"]); self.publish { self.status = "Não salvou na Fototeca: \(err ?? "?")" } } }
    }
  }
}

// prévia da câmera de foto: a camada nativa do iPhone (tempo real, sem o atraso da Extrema — foto não precisa dela)
struct PhotoPreview: UIViewRepresentable {
  let camera: PhotoCamera
  final class View: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
  }
  func makeUIView(context: Context) -> View {
    let v = View()
    v.backgroundColor = .black
    v.preview.session = camera.session
    v.preview.videoGravity = .resizeAspect
    camera.previewLayer = v.preview
    return v
  }
  func updateUIView(_ uiView: View, context: Context) {}
}

/// Portão da volta pro vídeo (0.11.9): a câmera de vídeo só reaplica o formato DEPOIS que a sessão de foto parou e soltou
/// o aparelho (onDisappear/onDismiss do SwiftUI não têm ordem garantida). Reserva: 1,5 s.
enum PhotoRelease {
  private static let lock = NSLock()
  private static var busy = false
  private static var waiters: [() -> Void] = []
  static func begin() { lock.lock(); busy = true; lock.unlock() }
  static func end() { lock.lock(); busy = false; let w = waiters; waiters = []; lock.unlock(); w.forEach { $0() } }
  static func whenFree(timeout: Double = 1.5, _ f: @escaping () -> Void) {
    let once = NSLock(); var done = false
    let run = { once.lock(); let go = !done; done = true; once.unlock(); if go { f() } }
    lock.lock()
    if !busy { lock.unlock(); run(); return }
    waiters.append(run); lock.unlock()
    DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { run() }
  }
}
