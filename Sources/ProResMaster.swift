import AVFoundation
import CryptoKit
import Foundation
import Network
import SwiftUI
import UIKit

// PRORES LOG EXTRA (0.13.0, operador 17/11): chave em Ajustes, LIGADA por padrão, que soma um mestre ProRes à gravação de
// sempre — desligada, o app é exatamente o 0.12.6 (nada da configuração dele muda). Sem SSD no celular, o mestre NÃO fica
// guardado no iPhone: sai em pedaços de 2 s (ProRes é todo quadro-chave: emenda perfeita, sem recodificar) e cada pedaço
// só é apagado do iPhone com o recibo de quem recebeu (sha256 conferido):
//   • EM CASA (PC achado na rede Wi-Fi) → direto pro receptor do PC (F:\CowboyRec\ProRes), 422 LT 4K30;
//   • FORA → VPS pela internet, 422 HQ (o máximo, pedido dele); o PC puxa da VPS sem parar e a VPS apaga.
// O iPhone só segura o ATRASO da rede (fora de casa, no 4G, o HQ acumula — o mestre para se o iPhone ficar com < 5 GB).
// Gravando a 60 qps o mestre vai a 30 (1 quadro sim, 1 não; limite da Apple sem SSD); a gravação de sempre fica a 60.

enum ProResPrefs {
  private static let d = UserDefaults.standard
  // 0.13.6: o mestre ProRes É o armazenamento (operador 24/11) — chave nova, ligada de fábrica; o "desligado" antigo
  // ("proresExtra", salvo na rua em 20/11) é ignorado. Desligar continua possível em Ajustes.
  static var enabled: Bool { get { d.object(forKey: "proresMestre") as? Bool ?? true } set { d.set(newValue, forKey: "proresMestre") } }
  static var home: ProResFlavor { get { ProResFlavor(rawValue: d.string(forKey: "proresHome") ?? "") ?? .hq } set { d.set(newValue.rawValue, forKey: "proresHome") } }
  static var away: ProResFlavor { get { ProResFlavor(rawValue: d.string(forKey: "proresAway") ?? "") ?? .hq } set { d.set(newValue.rawValue, forKey: "proresAway") } }
}

/// O PC de casa (receptor `C:\EvoOps\cowboy-rec-prores\receptor.py`): o PC publica endereço/porta/senha na VPS e o app lê
/// de lá com o login; "em casa" = o PC respondeu na rede local há pouco.
final class HomePC: @unchecked Sendable {
  static let shared = HomePC()
  struct Conf: Codable, Equatable { let ip: String; let port: Int; let token: String }
  private let lock = NSLock()
  private var okAt: Date?
  private(set) var conf: Conf? = (UserDefaults.standard.data(forKey: "homePC")).flatMap { try? JSONDecoder().decode(Conf.self, from: $0) }
  private lazy var http: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.timeoutIntervalForRequest = 1.5; c.allowsCellularAccess = false; c.waitsForConnectivity = false
    return URLSession(configuration: c)
  }()
  var reachable: Bool { lock.lock(); defer { lock.unlock() }; return okAt.map { Date().timeIntervalSince($0) < 300 } ?? false }
  func lost() { lock.lock(); okAt = nil; lock.unlock() }
  var base: URL? { conf.flatMap { URL(string: "http://\($0.ip):\($0.port)/prores/") } }
  func refreshConf(cookie: String) async {
    var r = URLRequest(url: URL(string: "/api/rec/pc", relativeTo: ProResUploader.origin)!.absoluteURL)
    r.setValue(cookie, forHTTPHeaderField: "Cookie"); r.timeoutInterval = 15
    guard let (body, resp) = try? await URLSession.shared.data(for: r), (resp as? HTTPURLResponse)?.statusCode == 200,
      let j = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let ip = j["ip"] as? String, let port = j["port"] as? Int, let token = j["token"] as? String else { return }
    let c = Conf(ip: ip, port: port, token: token)
    if c != conf { conf = c; UserDefaults.standard.set(try? JSONEncoder().encode(c), forKey: "homePC"); Diag.step("prores-pc-conf", ["ip": ip, "porta": port], send: false) }
  }
  @discardableResult func probe() async -> Bool {
    guard let base, let token = conf?.token else { return false }
    var r = URLRequest(url: base.appendingPathComponent("ping")); r.setValue(token, forHTTPHeaderField: "X-Token")
    let ok = ((try? await http.data(for: r))?.1 as? HTTPURLResponse)?.statusCode == 200
    lock.lock(); okAt = ok ? Date() : nil; lock.unlock()
    return ok
  }
  func authorize(_ r: inout URLRequest) { if let t = conf?.token { r.setValue(t, forHTTPHeaderField: "X-Token") } }
}

/// Gravador do mestre em pedaços de 2 s (só na fila de quadros). Troca de pedaço sem parar: o próximo gravador é criado e
/// iniciado ANTES (fila própria); o áudio vai pro pedaço do seu horário (o anterior fica aberto 0,6 s pra receber o atrasado),
/// então cada amostra cai em exatamente um pedaço e a emenda no PC é contínua (sem buraco nem deriva).
final class ProResRecorder: @unchecked Sendable {
  let cid: String
  let dir: URL
  let flavor: ProResFlavor
  var streamCid: String?
  private let video: [String: Any], audio: [String: Any], transform: CGAffineTransform
  private let step: Int, fps: Double
  private let queue: DispatchQueue
  private let prep = DispatchQueue(label: "cowboy.prores.prep", qos: .userInitiated)
  private var cur: SegmentWriter?, curSeq = 0, curStart: Double?
  private var prev: (w: SegmentWriter, seq: Int, boundary: Double)?
  private var next: SegmentWriter?, preparing = false
  private var frameIndex = 0
  private var stopped: String?
  private var segs = 0, dropped = 0

  /// 0.13.7: livre REAL (o "importante" conta cache que o iOS só limpa depois: 24/11 marcava 13,3 GB e deu "Disco Cheio" em 1:47)
  static func freeBytes() -> Int64 {
    let v = try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
    let imp = Int64(v?.volumeAvailableCapacityForImportantUsage ?? 0), real = Int64(v?.volumeAvailableCapacity ?? 0)
    if real <= 0 { return imp }
    return imp > 0 ? min(imp, real) : real
  }

  init(owner: String, flavor: ProResFlavor, home: Bool, video: [String: Any], audio: [String: Any], transform: CGAffineTransform, fps: Double, width: Int, height: Int, rotation: Double, title: String, queue: DispatchQueue) throws {
    cid = "pr" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(18).lowercased()
    dir = ProResUploader.root.appendingPathComponent(cid)
    self.flavor = flavor; self.video = video; self.audio = audio; self.transform = transform; self.queue = queue
    step = ProResPolicy.step(fps: fps); self.fps = ProResPolicy.masterFPS(fps)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let take = ProResUploader.Take(cid: cid, owner: owner, flavor: flavor.label, codec: flavor.rawValue, fps: self.fps, width: width, height: height, rotation: rotation, title: title,
      recordedAt: ISO8601DateFormatter().string(from: Date()), home: home, closed: false, count: 0)
    ProResUploader.shared.save(take)
    cur = try make(0)
    _ = cur?.prestart()
  }
  private func file(_ seq: Int) -> URL { dir.appendingPathComponent(String(format: "seg_%06d.mov", seq)) }
  private func make(_ seq: Int) throws -> SegmentWriter {
    try? FileManager.default.removeItem(at: file(seq))
    return try SegmentWriter.make(video: video, audio: audio, transform: transform, file: file(seq))
  }
  private func prepareNext() {
    guard !preparing, next == nil else { return }
    preparing = true
    let seq = curSeq + 1
    prep.async {
      let w = try? self.make(seq)
      if let w { _ = w.prestart() }
      self.queue.async { self.preparing = false; if self.stopped == nil { self.next = w } else { w?.finish { _ in } } }
    }
  }
  func appendVideo(_ s: CMSampleBuffer) {
    guard stopped == nil else { return }
    frameIndex += 1
    if (frameIndex - 1) % step != 0 { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(s).seconds
    if let st = curStart, pts - st >= ProResPolicy.segmentSeconds - 0.25 / fps { rotate(at: pts) }
    guard let w = cur, stopped == nil else { return }
    let before = w.dropped
    w.appendVideo(s)
    dropped += w.dropped - before
    if curStart == nil, w.firstVideoPTS != nil { curStart = pts }
    if let f = w.failed { stop("gravador ProRes: \(f)"); return }
    if let st = curStart, pts - st > 0.8 { prepareNext() }
    if let p = prev, pts - p.boundary > 0.6 { closePrev(p) }
  }
  func appendAudio(_ s: CMSampleBuffer) {
    guard stopped == nil else { return }
    let pts = CMSampleBufferGetPresentationTimeStamp(s).seconds
    if let p = prev, pts < p.boundary { p.w.appendAudio(s) } else { cur?.appendAudio(s) }
  }
  private func rotate(at t: Double) {
    if let p = prev { closePrev(p) }
    guard let w = cur else { return }
    prev = (w, curSeq, t)
    curSeq += 1; curStart = nil
    if let n = next { cur = n; next = nil }
    else {
      do { cur = try make(curSeq) } catch { cur = nil; stop("não abriu o pedaço \(curSeq): \(error.localizedDescription)"); return }
      Diag.step("prores-pedaco-atrasado", ["seq": curSeq], send: false)
    }
    if ProResRecorder.freeBytes() < ProResPolicy.minFreeBytes { stop("iPhone com pouco espaço (a rede não acompanhou) — o mestre parou aqui; a gravação de sempre segue") }
  }
  private func closePrev(_ p: (w: SegmentWriter, seq: Int, boundary: Double)) {
    prev = nil
    seal(p.w, seq: p.seq, end: p.boundary)
  }
  /// fecha um pedaço e grava a ficha dele (só então ele entra na fila de envio)
  private func seal(_ w: SegmentWriter, seq: Int, end: Double?) {
    let url = file(seq), fps = self.fps, cid = self.cid
    w.finish { ok in
      guard ok || FileManager.default.fileExists(atPath: url.path), let v0 = w.firstVideoPTS else {
        try? FileManager.default.removeItem(at: url); return
      }
      let vEnd = end ?? ((w.lastVideoPTS ?? v0) + 1 / fps)
      let meta = ProResUploader.Seg(seq: seq, frames: w.vOK, dropped: w.dropped, v0: v0, vEnd: vEnd, a0: w.firstAudioPTS, samples: w.aSamples, audioSkip: w.aSkip, ok: ok)
      ProResUploader.shared.sealed(cid: cid, seg: meta)
    }
    segs += 1
  }
  private func stop(_ why: String) {
    guard stopped == nil else { return }
    stopped = why
    Diag.step("prores-parou", ["por": why, "pedacos": segs, "drop": dropped])
    if let p = prev { closePrev(p) }
    if let w = cur { cur = nil; if w.started { seal(w, seq: curSeq, end: nil) } else { w.finish { _ in }; try? FileManager.default.removeItem(at: file(curSeq)) } }
    if let n = next { next = nil; n.finish { _ in }; try? FileManager.default.removeItem(at: file(curSeq + 1)) }
    ProResUploader.shared.close(cid: cid, count: segs, streamCid: streamCid, note: why)
    DispatchQueue.main.async { ProResUploader.shared.notice = why }
  }
  /// parar a gravação: fecha tudo e marca o fim (o envio termina sozinho)
  func finish() {
    guard stopped == nil else { return }
    if let p = prev { closePrev(p) }
    let total = segs + ((cur?.started ?? false) ? 1 : 0)
    stopped = "fim"
    if let w = cur { cur = nil; if w.started { seal(w, seq: curSeq, end: nil) } else { w.finish { _ in }; try? FileManager.default.removeItem(at: file(curSeq)) } }
    if let n = next { next = nil; n.finish { _ in }; try? FileManager.default.removeItem(at: file(curSeq + 1)) }
    Diag.step("prores-fim", ["cid": cid, "pedacos": total, "drop": dropped, "sabor": flavor.label])
    ProResUploader.shared.close(cid: cid, count: total, streamCid: streamCid, note: nil)
  }
}

/// Fila de envio dos pedaços: cada pedaço vai pro PC (em casa) ou pra VPS; só sai do iPhone com recibo (sha256 igual).
final class ProResUploader: ObservableObject, @unchecked Sendable {
  static let shared = ProResUploader()
  static let origin = URL(string: "https://cowboy-editor.ybguyl.easypanel.host")!
  static let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CowboyProRes")
  struct Take: Codable {
    var cid: String; var owner: String; var flavor: String; var codec: String; var fps: Double; var width: Int; var height: Int; var rotation: Double
    var title: String; var recordedAt: String; var home: Bool; var closed: Bool; var count: Int
    var streamCid: String? = nil; var take: String? = nil; var note: String? = nil; var doneTo: String? = nil
  }
  struct Seg: Codable { var seq: Int; var frames: Int; var dropped: Int; var v0: Double; var vEnd: Double; var a0: Double?; var samples: Int; var audioSkip: Int; var ok: Bool; var sha256: String? = nil }
  @Published var line = ""
  @Published var notice = ""
  @Published var pendingGB: Double = 0
  @Published var pcOnline = false
  var cookieProvider: (() async -> String?)?
  private let lock = NSLock()
  private var running = false
  private var started = false
  private let monitor = NWPathMonitor()
  private var wifi = false
  private lazy var http: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.httpShouldSetCookies = false; c.timeoutIntervalForRequest = 300; c.timeoutIntervalForResource = 3600
    c.allowsCellularAccess = true; c.allowsExpensiveNetworkAccess = true; c.allowsConstrainedNetworkAccess = true
    return URLSession(configuration: c, delegate: CowboyNoRedirect(), delegateQueue: nil)
  }()

  func start() {
    guard !started else { wake(); return }
    started = true
    try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let w = path.status == .satisfied && path.usesInterfaceType(.wifi)
      self.lock.lock(); let changed = w != self.wifi; self.wifi = w; self.lock.unlock()
      if changed { if !w { HomePC.shared.lost() }; self.wake() }
    }
    monitor.start(queue: DispatchQueue(label: "cowboy.prores.net"))
    Task.detached(priority: .utility) { [weak self] in await self?.recoverOrphans(); self?.wake() }
  }
  /// o app fechou no meio de uma tomada: fecha a tomada e dá ficha aos pedaços que ficaram sem (nada fica pra trás)
  private func recoverOrphans() async {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
    for d in dirs {
      guard var t = load(d.lastPathComponent), !t.closed else { continue }
      let files = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
      var n = 0
      for f in files.filter({ $0.hasPrefix("seg_") && $0.hasSuffix(".mov") }).sorted() {
        n += 1
        let json = d.appendingPathComponent(f.replacingOccurrences(of: ".mov", with: ".json"))
        if FileManager.default.fileExists(atPath: json.path) { continue }
        let url = d.appendingPathComponent(f), seq = Int(f.dropFirst(4).dropLast(4)) ?? 0
        let dur = (try? await AVURLAsset(url: url).load(.duration)).map { $0.seconds } ?? 0
        if !(dur > 0) { try? FileManager.default.removeItem(at: url); continue }
        let seg = Seg(seq: seq, frames: Int((dur * t.fps).rounded()), dropped: 0, v0: 0, vEnd: dur, a0: nil, samples: 0, audioSkip: 0, ok: false)
        if let data = try? JSONEncoder().encode(seg) { try? data.write(to: json, options: .atomic) }
      }
      t.closed = true; t.count = max(t.count, n); t.note = "app fechou gravando — recuperado até o último pedaço salvo"
      save(t)
      Diag.step("prores-recuperado", ["cid": t.cid, "pedacos": n])
    }
  }
  /// reconfere o PC de casa e solta a fila (abrir o app, voltar o Wi-Fi, fim de tomada)
  func wake() {
    Task.detached(priority: .utility) { [weak self] in
      guard let self else { return }
      if let cookie = await self.cookieProvider?(), !cookie.isEmpty { await HomePC.shared.refreshConf(cookie: cookie) }
      self.lock.lock(); let w = self.wifi; self.lock.unlock()
      let ok = w ? await HomePC.shared.probe() : false
      if !w { HomePC.shared.lost() }
      DispatchQueue.main.async { self.pcOnline = ok }
      self.kick()
    }
  }

  // ---- fichas (disco)
  private func takeURL(_ cid: String) -> URL { Self.root.appendingPathComponent(cid).appendingPathComponent("take.json") }
  func save(_ t: Take) { if let d = try? JSONEncoder().encode(t) { try? d.write(to: takeURL(t.cid), options: .atomic) } }
  func load(_ cid: String) -> Take? { (try? Data(contentsOf: takeURL(cid))).flatMap { try? JSONDecoder().decode(Take.self, from: $0) } }
  private func update(_ cid: String, _ fn: (inout Take) -> Void) { lock.lock(); defer { lock.unlock() }; guard var t = load(cid) else { return }; fn(&t); save(t) }
  func sealed(cid: String, seg: Seg) {
    let meta = Self.root.appendingPathComponent(cid).appendingPathComponent(String(format: "seg_%06d.json", seg.seq))
    if let d = try? JSONEncoder().encode(seg) { try? d.write(to: meta, options: .atomic) }
    // 0.13.4: sha256 já no fechamento do pedaço (fora da fila de câmera) — o envio em 2º plano sai na hora, sem recalcular
    DispatchQueue.global(qos: .utility).async {
      let mov = meta.deletingPathExtension().appendingPathExtension("mov")
      guard let h = try? Self.sha256(mov), var s = (try? Data(contentsOf: meta)).flatMap({ try? JSONDecoder().decode(Seg.self, from: $0) }), s.sha256 == nil else { return }
      s.sha256 = h; try? JSONEncoder().encode(s).write(to: meta, options: .atomic)
    }
    kick()
  }
  func close(cid: String, count: Int, streamCid: String?, note: String?) {
    update(cid) { t in t.closed = true; t.count = count; t.streamCid = streamCid; t.note = note; if t.take == nil, let s = streamCid { t.take = CloudStream.shared.takeID(s) } }
    wake()
  }
  func linkTake(streamCid: String, take: String) {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []
    for d in dirs { if let t = load(d.lastPathComponent), t.streamCid == streamCid, t.take == nil { update(t.cid) { $0.take = take } } }
  }

  // ---- envio
  func kick() {
    lock.lock(); if running { lock.unlock(); return }; running = true; lock.unlock()
    Task.detached(priority: .utility) { [weak self] in await self?.run() }
  }
  private struct Wait: Error { let text: String; let seconds: Double }
  private func run() async {
    defer { lock.lock(); running = false; lock.unlock() }
    var backoff = 2.0
    while true {
      let work = scan()
      publishCounters(work)
      guard let (cid, item) = work.next else { if work.total == 0 { setLine("") }; return }
      // 0.13.5: gravando, o mestre não disputa com a câmera — na rua espera parar; em casa só com o aparelho frio
      if !RecGate.allowsProRes(toPC: destination() != nil) {
        setLine("Mestre ProRes guardado no iPhone enquanto grava — sobe sozinho ao parar")
        try? await Task.sleep(nanoseconds: 2_000_000_000); continue
      }
      guard let cookie = await cookieProvider?(), !cookie.isEmpty else { setLine("Mestre ProRes espera o login na conta Cowboy (fica no iPhone)"); return }
      do {
        switch item {
        case .seg(let seg): try await send(cid: cid, seg: seg, cookie: cookie)
        case .done(let t): try await done(t, cookie: cookie)
        }
        backoff = 2
      } catch let w as Wait {
        setLine(w.text)
        if w.seconds <= 0 { return }
        try? await Task.sleep(nanoseconds: UInt64(w.seconds * 1e9))
      } catch {
        HomePC.shared.lost()
        setLine("Mestre ProRes: sem rede (\(error.localizedDescription)) — fica no iPhone e tenta de novo")
        try? await Task.sleep(nanoseconds: UInt64(backoff * 1e9)); backoff = min(backoff * 2, 60)
      }
    }
  }
  private enum Item { case seg(Seg), done(Take) }
  private func scan() -> (next: (String, Item)?, total: Int, bytes: Int64) {
    let dirs = ((try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
    var first: (String, Item)?, total = 0, bytes: Int64 = 0
    for d in dirs {
      guard let t = load(d.lastPathComponent) else { continue }
      let files = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
      let segs = files.filter { $0.hasPrefix("seg_") && $0.hasSuffix(".json") }.sorted()
      for f in files where f.hasSuffix(".mov") { bytes += Int64((try? d.appendingPathComponent(f).resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
      total += segs.count + (t.closed && t.doneTo == nil ? 1 : 0)
      guard first == nil else { continue }
      if let f = segs.first, let s = (try? Data(contentsOf: d.appendingPathComponent(f))).flatMap({ try? JSONDecoder().decode(Seg.self, from: $0) }) { first = (t.cid, .seg(s)) }
      // só fecha a tomada quando não sobrou pedaço gravado sem ficha (o último ainda pode estar fechando)
      else if t.closed && t.doneTo == nil && !files.contains(where: { $0.hasSuffix(".mov") }) { first = (t.cid, .done(t)) }
    }
    return (first, total, bytes)
  }
  private func destination() -> (URL, String)? {
    if HomePC.shared.reachable, let b = HomePC.shared.base { return (b, "pc") }
    return nil
  }
  private func send(cid: String, seg: Seg, cookie: String) async throws {
    let dir = Self.root.appendingPathComponent(cid)
    let mov = dir.appendingPathComponent(String(format: "seg_%06d.mov", seg.seq)), meta = dir.appendingPathComponent(String(format: "seg_%06d.json", seg.seq))
    guard let size = (try? mov.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }), size > 0 else {
      try? FileManager.default.removeItem(at: meta); return   // ficha sem vídeo (pedaço vazio): nada a mandar
    }
    var s = seg
    if s.sha256 == nil { s.sha256 = try Self.sha256(mov); try? JSONEncoder().encode(s).write(to: meta, options: .atomic) }
    let t = load(cid)
    let toPC = destination()
    // fora de casa a banda é de quem grava ao vivo: o mestre espera a fila da gravação de sempre esvaziar
    if toPC == nil, CloudStream.shared.liveBacklog > 3 { throw Wait(text: "Mestre ProRes cede a rede pra gravação ao vivo (fica no iPhone)", seconds: 3) }
    let r = request(cid: cid, seg: s, take: t, toPC: toPC, cookie: cookie)
    let where_ = toPC != nil ? "PC" : "VPS"
    setLine(String(format: "Mestre ProRes → %@: pedaço %d (%.0f MB)", where_, seg.seq, Double(size) / 1e6))
    let (body, resp) = try await http.upload(for: r, fromFile: mov)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    let j = ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:]
    switch code {
    case 200..<300:
      guard j["sha256"] as? String == s.sha256 else { throw Wait(text: "\(where_) não confirmou o pedaço \(seg.seq) (sha256) — reenviando", seconds: 3) }
      // RECIBO: só agora o pedaço sai do iPhone
      try? FileManager.default.removeItem(at: mov); try? FileManager.default.removeItem(at: meta)
      if seg.seq % 30 == 0 { Diag.step("prores-recibo", ["cid": cid, "seq": seg.seq, "destino": where_, "mb": size / 1_000_000], send: false) }
    case 507: throw Wait(text: "VPS sem espaço pro mestre ProRes — fica no iPhone; o PC puxa e libera (tenta de novo em 1 min)", seconds: 60)
    case 401, 403:
      if toPC != nil { HomePC.shared.lost(); throw Wait(text: "PC recusou a senha — usando a VPS", seconds: 1) }
      throw Wait(text: "Login venceu — entre de novo; o mestre espera no iPhone", seconds: 0)
    default:
      if toPC != nil { HomePC.shared.lost() }
      throw Wait(text: "\(where_) respondeu \(code) no pedaço \(seg.seq) — tenta de novo", seconds: 10)
    }
  }
  private func request(cid: String, seg s: Seg, take t: Take?, toPC: (URL, String)?, cookie: String) -> URLRequest {
    var url = toPC.map { $0.0.appendingPathComponent("seg") } ?? URL(string: "/api/rec/prores/seg", relativeTo: Self.origin)!.absoluteURL
    var c = URLComponents(url: url, resolvingAgainstBaseURL: true)!
    c.queryItems = [URLQueryItem(name: "cid", value: cid), URLQueryItem(name: "seq", value: String(s.seq))]
    url = c.url!
    var r = URLRequest(url: url); r.httpMethod = "PUT"; r.timeoutInterval = 600
    if toPC != nil { HomePC.shared.authorize(&r) } else { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
    r.setValue("video/quicktime", forHTTPHeaderField: "Content-Type")
    r.setValue(s.sha256, forHTTPHeaderField: "X-Sha256")
    if let d = try? JSONEncoder().encode(s) { r.setValue(d.base64EncodedString(), forHTTPHeaderField: "X-Seg") }
    if let t, let d = try? JSONEncoder().encode(t) { r.setValue(d.base64EncodedString(), forHTTPHeaderField: "X-Take") }
    return r
  }

  // ---- 0.13.4: envio em 2º plano do mestre (20/11: 5 tomadas HQ na rua ficaram no iPhone — o mestre só andava com o
  // app aberto, um pedaço de ~190 MB por vez). Ao sair do app, cada pedaço com ficha vira upload do iOS (prioridade baixa:
  // a gravação de sempre passa na frente). Recibo = sha256 devolvido igual; só então sai do iPhone.
  func handOff() {
    Task.detached(priority: .utility) { [weak self] in
      guard let self, let cookie = await self.cookieProvider?(), !cookie.isEmpty else { return }
      let already: Set<String> = await withCheckedContinuation { c in BGUpload.shared.pending { c.resume(returning: $0) } }
      let toPC = self.destination()
      let dirs = ((try? FileManager.default.contentsOfDirectory(at: Self.root, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
      var n = 0, gb = 0.0
      for d in dirs {
        guard let t = self.load(d.lastPathComponent) else { continue }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: d.path)) ?? []
        for f in files.filter({ $0.hasPrefix("seg_") && $0.hasSuffix(".json") }).sorted() {
          let meta = d.appendingPathComponent(f), mov = d.appendingPathComponent(f.replacingOccurrences(of: ".json", with: ".mov"))
          guard var s = (try? Data(contentsOf: meta)).flatMap({ try? JSONDecoder().decode(Seg.self, from: $0) }),
                let size = (try? mov.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }), size > 0 else { continue }
          let prefix = "prores|\(t.cid)|\(s.seq)|"
          if already.contains(where: { $0.hasPrefix(prefix) }) { continue }
          if s.sha256 == nil { guard let h = try? Self.sha256(mov) else { continue }; s.sha256 = h; try? JSONEncoder().encode(s).write(to: meta, options: .atomic) }
          BGUpload.shared.upload(request: self.request(cid: t.cid, seg: s, take: t, toPC: toPC, cookie: cookie), file: mov,
            desc: prefix + "\(s.sha256!)|\(toPC != nil ? "pc" : "vps")", low: true)
          n += 1; gb += Double(size) / 1e9
        }
      }
      if n > 0 { Diag.step("prores-2o-plano", ["pedacos": n, "gb": String(format: "%.1f", gb), "destino": toPC != nil ? "pc" : "vps"]) }
    }
  }
  /// resultado de um pedaço do mestre enviado pelo iOS
  func bgDone(desc: String, code: Int, json: [String: Any]) {
    let p = desc.split(separator: "|").map(String.init)
    guard p.count == 5, let seq = Int(p[2]) else { return }
    let cid = p[1], sha = p[3]
    guard (200..<300).contains(code), json["sha256"] as? String == sha else { if p[4] == "pc" && code != 0 { HomePC.shared.lost() }; return }
    let dir = Self.root.appendingPathComponent(cid)
    try? FileManager.default.removeItem(at: dir.appendingPathComponent(String(format: "seg_%06d.mov", seq)))
    try? FileManager.default.removeItem(at: dir.appendingPathComponent(String(format: "seg_%06d.json", seq)))
  }
  private func done(_ t0: Take, cookie: String) async throws {
    var t = t0
    if t.take == nil, let s = t.streamCid { t.take = CloudStream.shared.takeID(s) }
    let body = try JSONEncoder().encode(t)
    var r: URLRequest
    let toPC = destination()
    if let dest = toPC { r = URLRequest(url: dest.0.appendingPathComponent("done")); HomePC.shared.authorize(&r) }
    else { r = URLRequest(url: URL(string: "/api/rec/prores/done", relativeTo: Self.origin)!.absoluteURL); r.setValue(cookie, forHTTPHeaderField: "Cookie") }
    r.httpMethod = "POST"; r.httpBody = body; r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.timeoutInterval = 60
    let (_, resp) = try await http.data(for: r)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else { if toPC != nil { HomePC.shared.lost() }; throw Wait(text: "Fim do mestre não confirmado (\(code)) — tenta de novo", seconds: 10) }
    // tudo entregue com recibo: some a pasta da tomada no iPhone
    try? FileManager.default.removeItem(at: Self.root.appendingPathComponent(t.cid))
    Diag.step("prores-entregue", ["cid": t.cid, "pedacos": t.count, "destino": toPC != nil ? "pc" : "vps", "take": t.take ?? ""])
    setLine("Mestre ProRes entregue (\(t.count) pedaços) — o PC emenda no F:\\CowboyRec\\ProRes")
  }
  static func sha256(_ url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
    var hasher = SHA256()
    while let d = try h.read(upToCount: 8 * 1024 * 1024), !d.isEmpty { hasher.update(data: d) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }
  private func setLine(_ s: String) { DispatchQueue.main.async { self.line = s } }
  private func publishCounters(_ w: (next: (String, Item)?, total: Int, bytes: Int64)) { let gb = Double(w.bytes) / 1e9; DispatchQueue.main.async { self.pendingGB = gb } }
}

/// Ajustes › ProRes Log extra (soma à gravação de sempre; desligado = o app como era)
struct ProResSettingsSection: View {
  let recording: Bool
  @ObservedObject var up = ProResUploader.shared
  @State private var on = ProResPrefs.enabled
  @State private var home = ProResPrefs.home
  @State private var away = ProResPrefs.away
  var body: some View {
    Section("Mestre ProRes (armazenamento)") {
      Toggle("Gravar mestre ProRes (Apple Log 10 bits)", isOn: $on).disabled(recording)
        .onChange(of: on) { _, v in ProResPrefs.enabled = v; if v { ProResUploader.shared.wake() } }
      if !on { Text("DESLIGADO: só a gravação de sempre (HEVC). Ligue para guardar o mestre de cinema.").font(.caption).foregroundStyle(.orange) }
      if on {
        let free = Double(ProResRecorder.freeBytes() - ProResPolicy.minFreeBytes) / 1e9, rate = ProResPolicy.gbPerMinute(away, width: 3840, height: 2160, fps: 30)
        Text(String(format: "iPhone com espaço pra ~%.0f min de mestre %@ 4K (%.1f GB/min) antes de parar com 5 GB livres.", max(0, free) / max(0.1, rate), away.label, rate)).font(.caption)
          .foregroundStyle(free / max(0.1, rate) < 5 ? .orange : .secondary)
      }
      if on {
        Picker("Em casa (Wi-Fi → PC)", selection: $home) { ForEach(ProResFlavor.allCases, id: \.self) { Text($0.label).tag($0) } }
          .disabled(recording).onChange(of: home) { _, v in ProResPrefs.home = v }
        Picker("Fora (internet → VPS)", selection: $away) { ForEach(ProResFlavor.allCases, id: \.self) { Text($0.label).tag($0) } }
          .disabled(recording).onChange(of: away) { _, v in ProResPrefs.away = v }
        Text(up.pcOnline ? "PC de casa achado na rede: o mestre vai direto pro F:\\CowboyRec (\(home.label))." : "PC de casa fora de alcance: o mestre vai pra VPS (\(away.label)) e o PC puxa de lá.").font(.caption)
          .foregroundStyle(up.pcOnline ? .green : .secondary)
        Text(String(format: "4K30: %@ ≈ %.1f GB/min · %@ ≈ %.1f GB/min. Gravando a 60, o mestre sai a 30 (sem SSD é o limite da Apple); a gravação de sempre continua igual. Cada pedaço de 2 s só sai do iPhone com recibo; o iPhone guarda só o que a rede ainda não levou. Fora de casa, no 4G, o HQ acumula no iPhone (sobe depois sozinho); com menos de 5 GB livres o mestre para e a gravação de sempre segue.",
          home.label, ProResPolicy.gbPerMinute(home, width: 3840, height: 2160, fps: 30), away.label, ProResPolicy.gbPerMinute(away, width: 3840, height: 2160, fps: 30))).font(.caption2)
      }
      if up.pendingGB > 0.01 { Text(String(format: "Mestre no iPhone esperando envio: %.1f GB", up.pendingGB)).font(.caption) }
      if !up.line.isEmpty { Text(up.line).font(.caption2) }
      if !up.notice.isEmpty { Text(up.notice).font(.caption2).foregroundStyle(.orange) }
      Button("Procurar o PC / retomar envio") { ProResUploader.shared.wake() }
    }
    .onAppear { ProResUploader.shared.wake() }
  }
}
