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
    var holdUntil = Date.distantPast   // 0.13.1: em espera depois de erros seguidos do servidor (as outras passam na frente)
    var httpFails = 0
    var gapSince: Date?                // 0.13.1: o pedaço que o servidor pede não existe no iPhone desde quando
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
  private var bgMode = false   // 0.13.2: app fora da tela — quem sobe é o iOS (BGUpload); o laço daqui espera

  private init() {
    // 0.13.2: aviso de memória do iOS = nada pode ficar só na RAM (17/11: a 0.11.10 segurava pedaços na memória no 4G,
    // o iPhone esquentou, perdeu quadros e o iOS matou o app — 31 s da tomada 17:02 e 12 s da 17:07 sumiram)
    NotificationCenter.default.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: nil) { [weak self] _ in
      guard let self else { return }
      self.lock.lock(); let mb = self.takes.reduce(0) { $0 + $1.memBytes } / 1_048_576; self.lock.unlock()
      self.spillAll()
      Diag.step("memoria-aviso", ["fila_ram_mb": mb])
    }
  }

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
  /// número da tomada no servidor (se já foi registrada) — o mestre ProRes leva junto pra o PC achar a tomada da galeria
  func takeID(_ cid: String) -> String? {
    lock.lock(); let mem = takes.first { $0.m.cid == cid }?.m.take; lock.unlock()
    if let mem { return mem }
    guard let d = try? Data(contentsOf: root.appendingPathComponent(cid).appendingPathComponent("take.json")), let m = try? JSONDecoder().decode(Manifest.self, from: d) else { return nil }
    return m.take
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
    handOffToSystem()
    publish {
      guard self.background == .invalid else { return }
      self.background = UIApplication.shared.beginBackgroundTask(withName: "cowboy-upload") { [weak self] in
        guard let self else { return }
        self.spillAll(); UIApplication.shared.endBackgroundTask(self.background); self.background = .invalid
      }
    }
  }
  // ---- 0.13.2: envio em 2º plano (o iOS sobe com o app fora da tela / iPhone bloqueado / app fechado)
  /// Ao sair do app: registra cada tomada no servidor (precisa do número dela) e entrega TODOS os pedaços do disco ao iOS.
  private func handOffToSystem() {
    lock.lock(); bgMode = true; lock.unlock()
    Task.detached(priority: .userInitiated) { [weak self] in
      guard let self, let cookie = await self.cookieProvider?(), !cookie.isEmpty else { return }
      let already: Set<String> = await withCheckedContinuation { c in BGUpload.shared.pending { c.resume(returning: $0) } }
      self.lock.lock(); let list = self.takes.filter { $0.m.dead == nil }; self.lock.unlock()
      var queued = 0, takesN = 0
      for t in list {
        do { try await self.ensureServer(t, cookie: cookie) } catch { continue }
        self.lock.lock()
        guard let take = t.m.take, t.m.dead == nil else { self.lock.unlock(); continue }
        let from = t.serverNext ?? 0
        let seqs = t.disk.filter { $0 >= from }.sorted()
        let dur = t.m.durationMs, cid = t.m.cid
        self.lock.unlock()
        var any = false
        for s in seqs where !already.contains("\(cid)|\(s)") {
          let f = t.dir.appendingPathComponent(String(format: "%06d.m4s", s))
          guard FileManager.default.fileExists(atPath: f.path) else { continue }
          BGUpload.shared.upload(file: f, take: take, cid: cid, seq: s, durationMs: dur, cookie: cookie)
          queued += 1; any = true
        }
        if any { takesN += 1 }
      }
      Diag.step("envio-2o-plano", ["pedacos": queued, "tomadas": takesN, "ja_no_ios": already.count])
    }
  }
  /// Voltou pra tela: cancela o que o iOS ainda não terminou e o laço normal segue de onde o servidor está (sem duplicar).
  func leaveBackground() {
    lock.lock(); let was = bgMode; bgMode = false; for t in takes { t.serverNext = nil }; lock.unlock()
    guard was else { return }
    BGUpload.shared.cancelAll { n in if n > 0 { Diag.step("envio-2o-plano-volta", ["canceladas": n]) } }
    kick()
  }
  /// Resultado de um pedaço enviado pelo iOS (pode chegar com o app recém-acordado em 2º plano, sem a fila carregada:
  /// trabalha direto nos arquivos). Só apaga do iPhone com recibo do servidor.
  func bgDone(cid: String, seq: Int, code: Int, json: [String: Any]) {
    guard (200..<300).contains(code) else { return }
    let dir = root.appendingPathComponent(cid)
    let next = json["next"] as? Int ?? 0
    var gone = Set<Int>()
    if json["held"] as? Bool == true || seq < next { gone.insert(seq) }
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".m4s") }
    for f in files { if let s = Int(f.replacingOccurrences(of: ".m4s", with: "")), s < next { gone.insert(s) } }
    lock.lock()
    let t = takes.first { $0.m.cid == cid }
    for s in gone { try? FileManager.default.removeItem(at: dir.appendingPathComponent(String(format: "%06d.m4s", s))); t?.disk.remove(s); t?.mem[s] = nil }
    if let t, next > (t.serverNext ?? 0) { t.serverNext = next }
    lock.unlock()
    refreshCounters()
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
    reportQueue()
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
      if bgMode { running = false; lock.unlock(); return }   // 0.13.2: fora da tela quem sobe é o iOS (BGUpload)
      // recusada ainda gravando continua na lista (os pedaços seguintes ainda vão pro disco dela); sai só depois de fechada
      takes.removeAll { $0.m.dead != nil && $0.m.closed }
      let live = takes.filter { $0.m.dead == nil }
      guard !live.isEmpty else {
        running = false; let k = keptCount; lock.unlock()
        setHealth(k == 0 ? .idle : .error, k == 0 ? "Tudo na nuvem" : "\(k) gravação(ões) guardada(s) no iPhone — veja em Ajustes"); endBackground(); return
      }
      // 0.13.1: uma tomada com erro do servidor NUNCA segura a fila (18/11: a tomada 17/11 17:02 parou no pedaço 15 e
      // nada mais subiu — nem as tomadas novas). A que está em espera vai pro fim; as outras sobem.
      let now = Date()
      // 0.13.5: gravando, só a tomada atual e só com o aparelho frio (o resto fica no disco e sobe ao parar)
      let open = live.filter { RecGate.allows(stream: $0.m.cid) }
      if open.isEmpty {
        lock.unlock()
        setHealth(.ok, "Gravando no iPhone — sobe ao parar")
        try? await Task.sleep(nanoseconds: 1_000_000_000); continue
      }
      guard let t = open.first(where: { $0.holdUntil <= now }) else {
        let wait = open.map { $0.holdUntil }.min()!.timeIntervalSince(now); lock.unlock()
        try? await Task.sleep(nanoseconds: UInt64(max(0.5, min(wait, 30)) * 1e9)); continue
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
            lock.lock(); t.httpFails = 0; t.gapSince = nil; lock.unlock()
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
        if skipGap(t) { continue }   // 0.13.1: pedaço que o servidor pede sumiu do iPhone — antes ficava esperando pra sempre
        try? await Task.sleep(nanoseconds: 120_000_000)   // esperando o próximo pedaço da gravação
      } catch {
        spillAll()
        if case CloudCallError.http(let code) = error {
          // o servidor respondeu (a rede está boa): erro repetido nesta tomada → ela espera 60 s no fim da fila
          lock.lock(); t.httpFails += 1; let n = t.httpFails; if n >= 3 { t.holdUntil = Date().addingTimeInterval(60) }; let pend = t.disk.count + t.mem.count; lock.unlock()
          if n == 1 || n % 10 == 0 { Diag.step("stream-erro-http", ["cid": t.m.cid, "take": t.m.take ?? "", "http": code, "pedaco": t.serverNext ?? -1, "falhas": n, "na_fila": pend]) }
          setHealth(.error, "Servidor recusou (HTTP \(code)) — tenta de novo sozinho; as outras tomadas seguem")
          if n >= 3 { continue }
        } else {
          setHealth(.offline, "Sem rede — guardando no iPhone, sobe quando voltar")
        }
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
      ProResUploader.shared.linkTake(streamCid: t.m.cid, take: id)   // 0.13.0: o mestre ProRes leva o número desta tomada
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
  /// 0.13.1 — tomada FECHADA cujo pedaço pedido pelo servidor não existe mais no iPhone (sumiu/ilegível), mas há pedaços
  /// depois dele: renumera o que sobrou pra continuar dali (o MP4 fragmentado toca, só pula o trecho perdido — mesma regra
  /// da retomada). Antes a fila ficava esperando esse pedaço pra sempre e NENHUMA tomada subia mais.
  private func skipGap(_ t: Take) -> Bool {
    lock.lock()
    guard t.m.closed, let next = t.serverNext, t.mem[next] == nil else { lock.unlock(); return false }
    if t.disk.contains(next) { t.disk.remove(next) }   // listado mas ilegível (nextItem não conseguiu ler)
    let ahead = Set(t.mem.keys).union(t.disk).filter { $0 > next }.sorted()
    guard let first = ahead.first else { lock.unlock(); return false }
    let shift = first - next
    for s in ahead {
      if let d = t.mem.removeValue(forKey: s) { t.mem[s - shift] = d }
      if t.disk.remove(s) != nil {
        let from = t.dir.appendingPathComponent(String(format: "%06d.m4s", s)), to = t.dir.appendingPathComponent(String(format: "%06d.m4s", s - shift))
        try? FileManager.default.removeItem(at: to)
        if (try? FileManager.default.moveItem(at: from, to: to)) != nil { t.disk.insert(s - shift) }
      }
    }
    t.m.produced = max(next, t.m.produced - shift)
    let left = t.disk.count + t.mem.count
    lock.unlock()
    save(t)
    Diag.step("stream-buraco", ["cid": t.m.cid, "take": t.m.take ?? "", "faltou_de": next, "faltou_ate": first - 1, "restam": left])
    return true
  }
  /// 0.13.1 — retrato da fila ao abrir o app (prova do que está preso no iPhone, sem precisar de print do operador)
  func reportQueue() {
    lock.lock()
    let rows = takes.map { t -> String in
      let seqs = Set(t.mem.keys).union(t.disk)
      return "\(t.m.title)|\(t.m.cid.suffix(6))|take=\(t.m.take ?? "-")|fech=\(t.m.closed ? 1 : 0)|prod=\(t.m.produced)|srv=\(t.serverNext.map(String.init) ?? "?")|n=\(seqs.count)|min=\(seqs.min().map(String.init) ?? "-")|dead=\(t.m.dead ?? "")"
    }
    let kept = keptCount
    lock.unlock()
    Diag.step("stream-fila", ["n": rows.count, "guardadas": kept, "fila": rows.prefix(12).joined(separator: " ; ")])
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
  private var lastHealth: (Health, String)?
  private func setHealth(_ h: Health, _ text: String) {
    lock.lock(); netDown = h == .offline; let same = lastHealth?.0 == h && lastHealth?.1 == text; lastHealth = (h, text); lock.unlock()
    if same { return }   // 0.13.7: mesmo aviso não é republicado (24/11: "vários avisos" na tela durante a gravação)
    publish { self.health = h; self.line = text }
  }
  var uploadMbps: Double { rate * 8 / 1_000_000 }
  /// pedaços da gravação ao vivo ainda não enviados (o mestre ProRes cede a rede quando > 3)
  var liveBacklog: Int { lock.lock(); defer { lock.unlock() }; return takes.filter { !$0.m.closed && $0.m.dead == nil }.reduce(0) { $0 + $1.mem.count + $1.disk.count } }

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

/// 0.13.5 — GRAVANDO, o envio não disputa com a câmera (rádio, CPU, memória e calor). Medido 20/11 (0.13.3, 4G, calor
/// crítico): a tomada de 2:28 gravou 6.473 de ~8.866 quadros, com os buracos grandes junto dos avisos de memória, enquanto
/// subiam as tomadas antigas e os pedaços ProRes (~190 MB). Agora: gravando, só a tomada ATUAL sobe e só com o aparelho
/// frio; tomadas antigas e o mestre ProRes esperam no disco e saem sozinhos ao parar (nada se apaga).
enum RecGate {
  private static let lock = NSLock()
  private static var current: String?   // tomada gravando agora ("?" = gravando sem nuvem); nil = parado
  private static var hot = false        // calor ≥ quente ou pressão da câmera ≥ séria
  private static var strict = false     // 0.13.8 modo mestre: gravando, nada sobe
  static func begin(_ cid: String?, strict s: Bool = false) { lock.lock(); current = cid ?? "?"; strict = s; lock.unlock() }
  static func end() { lock.lock(); current = nil; lock.unlock(); CloudStream.shared.kick(); ProResUploader.shared.kick() }
  static func setHot(_ h: Bool) { lock.lock(); hot = h; lock.unlock() }
  static var recording: Bool { lock.lock(); defer { lock.unlock() }; return current != nil }
  static var isHot: Bool { lock.lock(); defer { lock.unlock() }; return hot }
  /// pode subir pedaço da tomada `cid` agora?
  static func allows(stream cid: String) -> Bool { lock.lock(); defer { lock.unlock() }; guard let c = current else { return true }; return !strict && !hot && c == cid }
  /// mestre ProRes: gravando, só pro PC de casa (Wi-Fi) e com o aparelho frio; na rua espera parar
  static func allowsProRes(toPC: Bool) -> Bool { lock.lock(); defer { lock.unlock() }; return current == nil || (!strict && toPC && !hot) }
}
