import Foundation
import UIKit

// FILMAR DIRETO NA VPS: o gravador entrega um pedaço de MP4 fragmentado por segundo (init + fragmentos) e cada pedaço sobe
// NA HORA, em ordem, com recibo do servidor (/api/rec/chunk). Os mesmos endpoints do Rec web: a VPS remonta o MP4
// (faststart), converte Log/HLG -> Rec.709 e gera o reprodutor.
// NUNCA PERDER FILMAGEM (0.11.11, regra do operador 01/11): todo pedaço vai pro disco do iPhone no instante em que nasce
// (memória só se o disco recusar) e só sai do iPhone com o recibo do servidor. Recusa da nuvem (507 sem espaço, 404/410,
// 409) NÃO apaga nada: a tomada fica "guardada no iPhone" e só o operador apaga, à mão (discard). A 0.11.10 apagava a
// pasta da tomada no 507 — perdeu 7 min de gravação em 01/11 com a VPS sem cota.
final class CloudStream: ObservableObject, @unchecked Sendable {
  static let shared = CloudStream()
  enum Health: String { case idle, ok, slow, offline, error }
  @Published var health = Health.idle
  @Published var line = ""
  @Published var pendingMB: Double = 0
  @Published var diskMB: Double = 0
  struct Kept: Identifiable { let id: String; let title: String; let mb: Double; let why: String }
  @Published var kept: [Kept] = []   // tomadas que a nuvem recusou: ficam no iPhone até o operador reenviar ou apagar

  struct Manifest: Codable {
    var cid: String
    var owner: String
    var created: Date
    var session: String?
    var take: String?
    var produced: Int
    var closed: Bool
    var durationMs: Int
    var body: Data
    var title: String
    var dead: String?
  }
  private final class Take {
    var m: Manifest
    let dir: URL
    var mem: [Int: Data] = [:]
    var disk = Set<Int>()
    var serverNext: Int?
    init(m: Manifest, dir: URL) { self.m = m; self.dir = dir }
    var memBytes: Int { mem.values.reduce(0) { $0 + $1.count } }
  }

  static let origin = URL(string: "https://cowboy-editor.ybguyl.easypanel.host")!
  var cookieProvider: (() async -> String?)?
  private let lock = NSLock()
  private var takes: [Take] = []
  private var running = false
  private var background: UIBackgroundTaskIdentifier = .invalid
  private let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CowboyStream")
  private lazy var http: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.httpShouldSetCookies = false; c.timeoutIntervalForRequest = 90; c.allowsCellularAccess = true
    c.allowsExpensiveNetworkAccess = true; c.allowsConstrainedNetworkAccess = true
    return URLSession(configuration: c, delegate: CowboyNoRedirect(), delegateQueue: nil)
  }()
  private var diskFail = 0
  private var keptCount = 0
  private var lastOk = Date.distantPast
  private var rate: Double = 0   // bytes/s medidos
  private var netDown = false

  private func publish(_ action: @escaping @Sendable () -> Void) { DispatchQueue.main.async(execute: action) }

  // ---- gravação (chamado da fila de captura)
  func begin(owner: String, title: String, body: [String: Any]) -> String {
    let cid = "ios" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(20).lowercased()
    let dir = root.appendingPathComponent(cid)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    let t = Take(m: Manifest(cid: cid, owner: owner, created: Date(), produced: 0, closed: false, durationMs: 0, body: data, title: title), dir: dir)
    save(t)
    lock.lock(); takes.append(t); lock.unlock()
    kick()
    return cid
  }
  func sideFile(_ cid: String, kind: String) -> URL { root.appendingPathComponent(cid).appendingPathComponent("side." + kind) }
  func push(_ cid: String, _ data: Data, durationMs: Int) {
    lock.lock()
    guard let t = takes.first(where: { $0.m.cid == cid }) else { lock.unlock(); return }
    let seq = t.m.produced
    t.m.produced += 1; t.m.durationMs = max(t.m.durationMs, durationMs)
    lock.unlock()
    // salvamento imediato: o pedaço vai pro disco antes de qualquer envio; memória só se o iPhone recusar a escrita (cheio)
    let url = t.dir.appendingPathComponent(String(format: "%06d.m4s", seq))
    let onDisk = (try? data.write(to: url, options: .atomic)) != nil
    lock.lock()
    if onDisk { t.disk.insert(seq) } else { t.mem[seq] = data; diskFail += 1 }
    let fails = diskFail
    lock.unlock()
    if !onDisk && (fails == 1 || fails % 60 == 0) { Diag.step("stream-disco-recusou", ["pedaco": seq, "falhas": fails]) }
    save(t)
    kick()
  }
  func side(_ cid: String, kind: String, data: Data) { try? data.write(to: sideFile(cid, kind: kind), options: .atomic) }
  func close(_ cid: String, durationMs: Int) {
    lock.lock()
    if let t = takes.first(where: { $0.m.cid == cid }) {
      t.m.closed = true; t.m.durationMs = max(t.m.durationMs, durationMs); let wasDead = t.m.dead != nil; lock.unlock()
      if wasDead { spillAll() } else { save(t) }   // spillAll também grava o take.json
      if wasDead { refreshKept() }
    } else { lock.unlock() }
    kick()
  }
  // Fila de memória -> disco (rede ruim, app indo pro fundo). Assim nada se perde se o iOS encerrar o app.
  func spillAll() {
    lock.lock(); let list = takes; lock.unlock()
    for t in list {
      lock.lock(); let items = t.mem; lock.unlock()
      for (seq, data) in items {
        let url = t.dir.appendingPathComponent(String(format: "%06d.m4s", seq))
        if (try? data.write(to: url, options: .atomic)) != nil { lock.lock(); t.mem[seq] = nil; t.disk.insert(seq); lock.unlock() }
      }
      save(t)
    }
    refreshCounters()
  }
  func enterBackground() {
    spillAll()
    publish {
      guard self.background == .invalid else { return }
      self.background = UIApplication.shared.beginBackgroundTask(withName: "cowboy-upload") { [weak self] in
        guard let self else { return }
        self.spillAll(); UIApplication.shared.endBackgroundTask(self.background); self.background = .invalid
      }
    }
  }
  private func endBackground() {
    publish { if self.background != .invalid { UIApplication.shared.endBackgroundTask(self.background); self.background = .invalid } }
  }

  // ---- retomada: o que ficou no aparelho (app fechado, sem rede, iOS encerrou) sobe de onde parou
  func resume(owner: String) {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    for dir in dirs {
      let manifestURL = dir.appendingPathComponent("take.json")
      guard let data = try? Data(contentsOf: manifestURL), var m = try? JSONDecoder().decode(Manifest.self, from: data), m.owner == owner else { continue }
      lock.lock(); let known = takes.contains { $0.m.cid == m.cid }; lock.unlock()
      if known || m.dead != nil { continue }   // recusadas ficam guardadas (lista "kept"), não voltam sozinhas pra fila
      let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".m4s") }.sorted()
      var seqs = files.compactMap { Int($0.replacingOccurrences(of: ".m4s", with: "")) }.sorted()
      if !m.closed {
        // app morreu gravando: o que estava só na memória se perdeu. Renumera o que sobrou em sequência (o MP4 fragmentado
        // continua tocando, só pula o trecho perdido) e fecha a tomada.
        let first = seqs.first ?? 0
        for (i, s) in seqs.enumerated() where s != first + i {
          try? FileManager.default.moveItem(at: dir.appendingPathComponent(String(format: "%06d.m4s", s)), to: dir.appendingPathComponent(String(format: "%06d.m4s", first + i)))
        }
        seqs = seqs.indices.map { first + $0 }
        m.produced = (seqs.last.map { $0 + 1 }) ?? m.produced
        m.closed = true
      }
      let t = Take(m: m, dir: dir); t.disk = Set(seqs)
      save(t)
      lock.lock(); takes.append(t); takes.sort { $0.m.created < $1.m.created }; lock.unlock()
    }
    refreshCounters()
    refreshKept()
    kick()
  }

  // ---- guardadas no iPhone: só o operador decide (reenviar ou apagar)
  func refreshKept() {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
    var list: [Kept] = []
    for dir in dirs {
      guard let data = try? Data(contentsOf: dir.appendingPathComponent("take.json")), let m = try? JSONDecoder().decode(Manifest.self, from: data), let why = m.dead else { continue }
      let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
      let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
      list.append(Kept(id: m.cid, title: m.title, mb: Double(bytes) / 1_048_576, why: why))
    }
    list.sort { $0.title < $1.title }
    lock.lock(); keptCount = list.count; lock.unlock()
    publish { self.kept = list }
  }
  /// Reenviar: volta pra fila do começo — sessão e tomada novas no servidor, com todos os pedaços guardados.
  func retry(_ cid: String, owner: String) {
    let dir = root.appendingPathComponent(cid), url = dir.appendingPathComponent("take.json")
    guard let data = try? Data(contentsOf: url), var m = try? JSONDecoder().decode(Manifest.self, from: data) else { return }
    lock.lock(); takes.removeAll { $0.m.cid == cid && $0.m.dead != nil }; lock.unlock()
    m.dead = nil; m.session = nil; m.take = nil; m.owner = owner; m.closed = true
    if let d = try? JSONEncoder().encode(m) { try? d.write(to: url, options: .atomic) }
    Diag.step("stream-reenviar", ["cid": cid])
    resume(owner: owner)
  }
  /// Apagar do iPhone: SÓ por ação manual do operador (confirmada na tela).
  func discard(_ cid: String) {
    lock.lock(); takes.removeAll { $0.m.cid == cid && $0.m.dead != nil && $0.m.closed }; let active = takes.contains { $0.m.cid == cid }; lock.unlock()
    guard !active else { return }
    try? FileManager.default.removeItem(at: root.appendingPathComponent(cid))
    Diag.step("stream-apagado-manual", ["cid": cid])
    refreshKept()
  }

  // ---- envio
  func kick() {
    lock.lock(); if running || takes.isEmpty { lock.unlock(); return }; running = true; lock.unlock()
    Task.detached(priority: .userInitiated) { [weak self] in await self?.run() }
  }
  private func run() async {
    var backoff: UInt64 = 500_000_000
    while true {
      lock.lock()
      // recusada ainda gravando continua na lista (os pedaços seguintes ainda vão pro disco dela); sai só depois de fechada
      takes.removeAll { $0.m.dead != nil && $0.m.closed }
      guard let t = takes.first(where: { $0.m.dead == nil }) else {
        running = false; let k = keptCount; lock.unlock()
        setHealth(k == 0 ? .idle : .error, k == 0 ? "Tudo na nuvem" : "\(k) gravação(ões) guardada(s) no iPhone — veja em Ajustes"); endBackground(); return
      }
      lock.unlock()
      guard let cookie = await cookieProvider?(), !cookie.isEmpty else {
        setHealth(.error, "Entre na conta Cowboy — a gravação espera no iPhone"); spillAll()
        try? await Task.sleep(nanoseconds: 4_000_000_000); continue
      }
      do {
        try await ensureServer(t, cookie: cookie)
        if let item = nextItem(t) {
          let (seq, data) = item
          let t0 = Date()
          let (code, json) = try await call("/api/rec/chunk?take=\(t.m.take!)&seq=\(seq)&dur=\(t.m.durationMs)", method: "PUT", data: data, cookie: cookie)
          switch code {
          case 200..<300:
            let next = json["next"] as? Int ?? seq + 1
            ack(t, below: next)
            let dt = Date().timeIntervalSince(t0); if dt > 0 { rate = rate == 0 ? Double(data.count) / dt : rate * 0.7 + Double(data.count) / dt * 0.3 }
            lastOk = Date(); backoff = 500_000_000
            let behind = pendingCount(t)
            setHealth(behind > 3 ? .slow : .ok, behind > 3 ? "Rede lenta — \(behind) s na fila (sobe sozinho)" : "Gravando direto na nuvem")
          case 409:
            if let next = json["next"] as? Int, next > seq { ack(t, below: next) }
            else if let next = json["next"] as? Int { dead(t, "o servidor tem \(next) pedaços e o iPhone começa no \(seq) — o que subiu está salvo") }
            else { throw CloudCallError.http(409) }
          case 507: await cloudFull(t, json["error"] as? String)
          case 404, 410: dead(t, json["error"] as? String ?? "Tomada não existe mais no servidor")
          case 401: setHealth(.error, "Login venceu — entre de novo; nada se perde"); spillAll(); try? await Task.sleep(nanoseconds: 5_000_000_000)
          default: throw CloudCallError.http(code)
          }
          continue
        }
        lock.lock(); let closed = t.m.closed, produced = t.m.produced, empty = t.mem.isEmpty && t.disk.isEmpty; lock.unlock()
        if closed && empty {
          try await finish(t, chunks: produced, cookie: cookie)
          continue
        }
        try? await Task.sleep(nanoseconds: 120_000_000)   // esperando o próximo pedaço da gravação
      } catch {
        spillAll()
        setHealth(.offline, "Sem rede — guardando no iPhone, sobe quando voltar")
        try? await Task.sleep(nanoseconds: backoff); backoff = min(backoff * 2, 8_000_000_000)
      }
    }
  }
  enum CloudCallError: LocalizedError { case http(Int), bad(String)
    var errorDescription: String? { switch self { case .http(let c): return "HTTP \(c)"; case .bad(let s): return s } }
  }
  private func ensureServer(_ t: Take, cookie: String) async throws {
    if t.m.session == nil {
      let (code, j) = try await call("/api/rec/session", method: "POST", json: ["cid": "s" + t.m.cid, "title": t.m.title, "device": "Cowboy Rec iOS (nativo, direto na nuvem)", "source": ["type": "iphone", "model": "iPhone", "method": "native-stream"]], cookie: cookie)
      guard (200..<300).contains(code), let id = j["session"] as? String else { if code == 507 { await cloudFull(t, j["error"] as? String); return }; throw CloudCallError.http(code) }
      lock.lock(); t.m.session = id; lock.unlock(); save(t)
    }
    if t.m.take == nil {
      var body = ((try? JSONSerialization.jsonObject(with: t.m.body)) as? [String: Any]) ?? [:]
      body["session"] = t.m.session!; body["cid"] = t.m.cid
      let (code, j) = try await call("/api/rec/take", method: "POST", json: body, cookie: cookie)
      guard (200..<300).contains(code), let id = j["take"] as? String else { if code == 507 { await cloudFull(t, j["error"] as? String); return }; throw CloudCallError.http(code) }
      lock.lock(); t.m.take = id; lock.unlock(); save(t)
    }
    if t.serverNext == nil {
      let (code, j) = try await call("/api/rec/take-status?take=\(t.m.take!)", cookie: cookie)
      if code == 404 || code == 410 { dead(t, "Tomada não existe mais no servidor"); return }
      guard (200..<300).contains(code) else { throw CloudCallError.http(code) }
      ack(t, below: j["next"] as? Int ?? 0)
    }
  }
  private func nextItem(_ t: Take) -> (Int, Data)? {
    lock.lock(); defer { lock.unlock() }
    guard t.m.dead == nil, t.m.take != nil, let next = t.serverNext else { return nil }
    if let d = t.mem[next] { return (next, d) }
    if t.disk.contains(next), let d = try? Data(contentsOf: t.dir.appendingPathComponent(String(format: "%06d.m4s", next))) { return (next, d) }
    return nil
  }
  private func ack(_ t: Take, below next: Int) {
    lock.lock()
    t.serverNext = next
    for s in t.mem.keys where s < next { t.mem[s] = nil }
    let gone = t.disk.filter { $0 < next }
    for s in gone { t.disk.remove(s); try? FileManager.default.removeItem(at: t.dir.appendingPathComponent(String(format: "%06d.m4s", s))) }
    lock.unlock()
    refreshCounters()
  }
  private func pendingCount(_ t: Take) -> Int { lock.lock(); defer { lock.unlock() }; return t.mem.count + t.disk.count }
  private func finish(_ t: Take, chunks: Int, cookie: String) async throws {
    for kind in ["thumb", "gcsv", "space", "cube", "fx"] {
      let url = sideFile(t.m.cid, kind: kind)
      guard let data = try? Data(contentsOf: url) else { continue }
      let (code, _) = try await call("/api/rec/side?take=\(t.m.take!)&kind=\(kind)", method: "PUT", data: data, cookie: cookie, type: kind == "thumb" ? "image/jpeg" : "text/plain; charset=utf-8")
      if (200..<300).contains(code) || code == 400 { try? FileManager.default.removeItem(at: url) } else { throw CloudCallError.http(code) }
    }
    let (code, j) = try await call("/api/rec/stop", method: "POST", json: ["take": t.m.take!, "chunks": chunks, "duration_ms": t.m.durationMs, "reason": "iPhone nativo — direto na nuvem"], cookie: cookie)
    if code == 404 || code == 410 { dead(t, j["error"] as? String ?? "Tomada não existe mais no servidor"); return }
    guard (200..<300).contains(code) else { throw CloudCallError.http(code) }
    let status = j["status"] as? String ?? "?"
    // aqui todos os pedaços já têm recibo (saíram do iPhone um a um): sobra só take.json e acompanhantes enviados
    try? FileManager.default.removeItem(at: t.dir)
    lock.lock(); takes.removeAll { $0 === t }; lock.unlock()
    setHealth(.ok, status == "done" ? "Tomada completa na nuvem" : "Tomada salva (\(status))")
  }
  // recusa definitiva do servidor: a tomada sai da fila mas FICA no iPhone (spill grava o que estava na memória)
  private func dead(_ t: Take, _ why: String) {
    spillAll()
    lock.lock(); t.m.dead = why; lock.unlock()
    save(t)
    Diag.step("stream-guardada", ["cid": t.m.cid, "por": why, "pedacos": t.disk.count, "memoria": t.mem.count])
    setHealth(.error, "Guardada no iPhone: \(why)")
    refreshKept()
  }
  // nuvem sem espaço (507): espera e tenta de novo — nunca descarta (a VPS libera espaço arquivando no PC)
  private func cloudFull(_ t: Take, _ why: String?) async {
    spillAll()
    Diag.step("stream-nuvem-cheia", ["cid": t.m.cid, "err": why ?? ""])
    setHealth(.error, "Nuvem sem espaço — guardando no iPhone, tenta de novo sozinho")
    try? await Task.sleep(nanoseconds: 60_000_000_000)
  }
  private func save(_ t: Take) {
    lock.lock(); let m = t.m; lock.unlock()
    if let data = try? JSONEncoder().encode(m) { try? data.write(to: t.dir.appendingPathComponent("take.json"), options: .atomic) }
  }
  private func refreshCounters() {
    lock.lock()
    let mem = takes.reduce(0) { $0 + $1.memBytes }
    var disk = 0
    for t in takes { for s in t.disk { disk += (try? t.dir.appendingPathComponent(String(format: "%06d.m4s", s)).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 } }
    lock.unlock()
    let total = Double(mem + disk) / 1_048_576, onDisk = Double(disk) / 1_048_576
    publish { self.pendingMB = total; self.diskMB = onDisk }
  }
  private func setHealth(_ h: Health, _ text: String) { lock.lock(); netDown = h == .offline; lock.unlock(); publish { self.health = h; self.line = text } }
  var uploadMbps: Double { rate * 8 / 1_000_000 }

  private func call(_ path: String, method: String = "GET", json: [String: Any]? = nil, data: Data? = nil, cookie: String, type: String? = nil) async throws -> (Int, [String: Any]) {
    var request = URLRequest(url: URL(string: path, relativeTo: Self.origin)!.absoluteURL)
    request.httpMethod = method
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue(type ?? (json == nil ? "application/octet-stream" : "application/json"), forHTTPHeaderField: "Content-Type")
    request.httpBody = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? data
    let (body, response) = try await http.data(for: request)
    guard let r = response as? HTTPURLResponse else { throw CloudCallError.bad("sem resposta") }
    if (300..<400).contains(r.statusCode) { return (401, [:]) }
    return (r.statusCode, ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:])
  }
}
