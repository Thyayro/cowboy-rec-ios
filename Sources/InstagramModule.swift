import SwiftUI
import UIKit
import AVKit

// INSTAGRAM (0.10.0) — módulo DESLIGADO por padrão (Ajustes > Instagram). Usa a câmera do app inteira: o que vai pro
// Instagram é o que o app grava (Apple Log -> Rec.709, look, Extrema, zoom, desfoque, igualar lentes, dissolve da troca).
// NADA vai pro ar sem APROVAÇÃO: todo pedido vira RASCUNHO (arquivo no padrão do Instagram + capa + legenda) e para em
// "aguardando aprovação" com a prévia; só o botão Aprovar publica.
//  - Fontes: tomada BRUTA da biblioteca, a gravação que acabou de parar ("preparar ao parar") ou um vídeo EDITADO do Studio.
//  - Reels (com/sem feed), Stories (com ou sem áudio), foto do feed; um ou os dois perfis.
//  - Capa: quadro escolhido, ou IA no estilo Cowboy (placas de madeira do padrão aprovado) ou livre. Legenda: à mão ou IA.
//    A IA é o MESMO processo das sessões do Claude Code: worker do Cowboy Studio no PC com a skill edicao-shorts-cowboy.
//  - Galeria: selecionar tomadas e mandar pra EDIÇÃO no molde (Ricardo MT, Ricardo Boreal, Ricardo Premium, Fernando,
//    Teteba, referências do Thyayrô, livre). O resultado aparece em "Editados" e também só sai com aprovação.
//  - Perfil real (posts, stories, curtidas, comentários, responder) e LIVE: com a live armada, ao gravar o app faz um 2º vídeo
//    leve (H.264 720p, 30 qps) dos MESMOS quadros do arquivo; a nuvem empurra pro Instagram (endereço + chave do Live Producer).
// Tudo passa pela nuvem Cowboy (/api/ig/*): o token do Instagram nunca vem pro iPhone.

struct IGAccount: Codable, Identifiable, Hashable {
  struct Quota: Codable, Hashable { var used: Int; var total: Int }
  var id: String; var username: String; var name: String?; var pic: String?; var followers: Int?; var following: Int?; var posts: Int?; var bio: String?; var page: String?; var quota: Quota?
}
struct IGTake: Codable, Identifiable, Hashable {
  struct Posted: Codable, Hashable { var user: String?; var kind: String?; var url: String?; var at: String? }
  var id: String; var title: String?; var created: String?; var kind: String; var dur: Double; var w: Int; var h: Int; var color: String?; var busy: String?; var thumb: String?; var url: String?; var ig: [Posted]?
}
struct IGEdit: Codable, Identifiable, Hashable {
  struct Post: Codable, Hashable { var status: String?; var permalink: String? }
  var id: String; var title: String?; var created: String?; var from_app: Bool?; var molde: String?; var busy: String?; var stage: String?; var done: Int?; var total: Int?
  var final: String?; var thumb: String?; var caption: String?; var post: Post?; var whatsapp: String?
}
struct IGJob: Codable, Identifiable, Hashable {
  struct Acc: Codable, Hashable { var id: String; var username: String; var state: String; var step: String?; var err: String?; var permalink: String? }
  var id: String; var take: String?; var studio: String?; var kind: String; var caption: String?; var audio: Bool?; var fit: String?; var cover: String?
  var state: String; var step: String?; var pct: Int; var err: String?; var created: String; var approved_by: String?; var preview: String?; var cover_url: String?; var accounts: [Acc]
}
struct IGPost: Codable, Identifiable, Hashable { var id: String; var caption: String?; var type: String; var url: String?; var thumb: String?; var t: String?; var likes: Int?; var comments: Int? }
struct IGStory: Codable, Identifiable, Hashable { var id: String; var url: String?; var thumb: String?; var t: String?; var type: String? }
struct IGComment: Codable, Identifiable, Hashable {
  struct Reply: Codable, Hashable, Identifiable { var id: String; var user: String?; var text: String?; var t: String? }
  var id: String; var user: String?; var text: String?; var t: String?; var likes: Int?; var replies: [Reply]?
}
struct IGLiveStatus: Codable, Hashable {
  struct C: Codable, Hashable, Identifiable { var id: String; var user: String?; var text: String?; var t: String? }
  var id: String; var status: String; var err: String?; var kb: Int?; var chunks: Int?; var account: String?; var ig_live: String?; var comments: [C]?
}
/// o que vai virar rascunho
enum IGSource: Identifiable, Hashable {
  case take(IGTake), edit(IGEdit)
  var id: String { switch self { case .take(let t): return "t" + t.id; case .edit(let e): return "e" + e.id } }
  var isPhoto: Bool { if case .take(let t) = self { return t.kind == "photo" }; return false }
  var title: String { switch self { case .take(let t): return t.title ?? t.id; case .edit(let e): return e.title ?? "Editado" } }
  var thumb: String? { switch self { case .take(let t): return t.thumb; case .edit(let e): return e.thumb } }
  /// vídeo de onde sai o quadro da capa
  var video: String? { switch self { case .take(let t): return t.kind == "photo" ? nil : t.url; case .edit(let e): return e.final } }
}

// ---------------------------------------------------------------- envio da live (fila própria, nunca atrasa a gravação)
// O 1º pedaço do gravador é o início do MP4 (descrição das faixas): sempre vai. Depois, se a rede não acompanhar, os pedaços
// mais velhos são descartados (live atrasada não serve) — a numeração enviada continua sem buraco, a nuvem nem percebe.
final class IGLiveUplink: @unchecked Sendable {
  private static let armLock = NSLock()
  private static var armed: (id: String, cookie: String)?
  static func arm(id: String, cookie: String) { armLock.lock(); armed = (id, cookie); armLock.unlock() }
  static func disarm() { armLock.lock(); armed = nil; armLock.unlock() }
  static var isArmed: Bool { armLock.lock(); defer { armLock.unlock() }; return armed != nil }
  /// chamado pela câmera ao começar a gravar: consome a live armada (uma live por armada)
  static func take() -> IGLiveUplink? { armLock.lock(); defer { armLock.unlock() }; guard let a = armed else { return nil }; armed = nil; return IGLiveUplink(id: a.id, cookie: a.cookie) }

  let id: String
  private let cookie: String
  private let q = DispatchQueue(label: "cowboy.ig.live")
  private var queue: [Data] = []
  private var initSent = false, sending = false, closed = false, stopSent = false, dead = false
  private var seq = 0, retries = 0
  private(set) var sent = 0, dropped = 0
  private lazy var http: URLSession = {
    let c = URLSessionConfiguration.ephemeral; c.httpShouldSetCookies = false; c.timeoutIntervalForRequest = 12
    return URLSession(configuration: c, delegate: CowboyNoRedirect(), delegateQueue: nil)
  }()
  private init(id: String, cookie: String) { self.id = id; self.cookie = cookie }
  func push(_ data: Data) {
    q.async {
      guard !self.dead else { return }
      self.queue.append(data)
      let keepFirst = !self.initSent ? 1 : 0
      while self.queue.count - keepFirst > 4 { self.queue.remove(at: keepFirst); self.dropped += 1 }
      self.pump()
    }
  }
  func close() { q.async { self.closed = true; if !self.sending { self.pump() } } }
  private func pump() {
    guard !sending else { return }
    guard let data = queue.first, !dead else { if closed { sendStop() }; return }
    sending = true
    var r = URLRequest(url: URL(string: "/api/ig/live/chunk?id=\(id)&seq=\(seq)", relativeTo: CowboyCloud.origin)!.absoluteURL)
    r.httpMethod = "PUT"; r.setValue(cookie, forHTTPHeaderField: "Cookie"); r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type"); r.httpBody = data
    http.dataTask(with: r) { _, resp, _ in
      self.q.async {
        self.sending = false
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 { self.queue.removeFirst(); self.seq += 1; self.sent += 1; self.retries = 0; self.initSent = true; self.pump() }
        else if code == 410 || code == 404 || code == 401 { self.dead = true; self.queue.removeAll(); Diag.step("ig-live-dead", ["http": code]) }
        else {
          self.retries += 1
          if self.retries > 3 && self.initSent { self.queue.removeFirst(); self.dropped += 1; self.retries = 0 }
          self.q.asyncAfter(deadline: .now() + 0.4) { self.pump() }
        }
      }
    }.resume()
  }
  private func sendStop() {
    guard !stopSent else { return }; stopSent = true
    var r = URLRequest(url: URL(string: "/api/ig/live/stop?id=\(id)", relativeTo: CowboyCloud.origin)!.absoluteURL)
    r.httpMethod = "POST"; r.setValue(cookie, forHTTPHeaderField: "Cookie")
    http.dataTask(with: r) { _, _, _ in }.resume()
    Diag.step("ig-live-stop", ["enviados": sent, "descartados": dropped])
  }
}

// ---------------------------------------------------------------- estado do módulo
@MainActor final class IGModule: ObservableObject {
  static let shared = IGModule()
  @Published var enabled = UserDefaults.standard.bool(forKey: "igModule") { didSet { UserDefaults.standard.set(enabled, forKey: "igModule"); if !enabled { disarmLive(); autoPost = false } } }
  @Published var accounts: [IGAccount] = []
  @Published var selected: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "igSelected") ?? []) { didSet { UserDefaults.standard.set(Array(selected), forKey: "igSelected") } }
  @Published var takes: [IGTake] = []
  @Published var edits: [IGEdit] = []
  @Published var jobs: [IGJob] = []
  @Published var posts: [String: [IGPost]] = [:]
  @Published var stories: [String: [IGStory]] = [:]
  @Published var error: String?
  @Published var busy = false
  // padrão do rascunho (também usado pelo "preparar ao parar")
  @Published var kind = UserDefaults.standard.string(forKey: "igKind") ?? "reels" { didSet { UserDefaults.standard.set(kind, forKey: "igKind") } }
  @Published var fit = UserDefaults.standard.string(forKey: "igFit") ?? "cover" { didSet { UserDefaults.standard.set(fit, forKey: "igFit") } }
  @Published var audio = true
  @Published var cover = UserDefaults.standard.string(forKey: "igCover") ?? "frame" { didSet { UserDefaults.standard.set(cover, forKey: "igCover") } }
  @Published var coverSec = 0.0
  @Published var aiCaption = UserDefaults.standard.bool(forKey: "igAiCaption") { didSet { UserDefaults.standard.set(aiCaption, forKey: "igAiCaption") } }
  @Published var caption = ""
  @Published var hint = ""
  @Published var autoPost = false
  // live
  @Published var liveURL = UserDefaults.standard.string(forKey: "igLiveURL") ?? "" { didSet { UserDefaults.standard.set(liveURL, forKey: "igLiveURL") } }
  @Published var liveKey = ""   // só na memória
  @Published var liveAccount = UserDefaults.standard.string(forKey: "igLiveAccount") ?? "" { didSet { UserDefaults.standard.set(liveAccount, forKey: "igLiveAccount") } }
  @Published var liveId: String?
  @Published var liveRunning = false
  @Published var liveStatus: IGLiveStatus?
  private var liveTimer: Timer?
  private var jobTimer: Timer?

  static let kinds: [(id: String, label: String, icon: String)] = [("reels", "Reels + Feed", "film.stack"), ("reels_only", "Só Reels", "film"), ("story", "Stories", "circle.dashed"), ("feed", "Foto feed", "photo")]
  static let covers: [(id: String, label: String)] = [("frame", "Quadro"), ("ai_cowboy", "IA Cowboy"), ("ai_livre", "IA livre"), ("studio", "Da edição")]
  static let moldes: [(id: String, label: String)] = [("ricardo_boreal", "Ricardo (Boreal) — normal"), ("ricardo_premium", "Ricardo Premium"), ("ricardo_mt", "Ricardo (MT)"), ("fernando", "Fernando"), ("teteba", "Teteba"), ("thyayro", "Referências do Thyayrô"), ("livre", "Livre (o agente decide)")]
  var pendingApproval: Int { jobs.filter { $0.state == "aguardando aprovação" }.count }

  // ---- rede
  struct Failure: LocalizedError { var errorDescription: String? }
  func call(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
    guard let cookie = CowboyCloud.shared.credential else { throw Failure(errorDescription: "Entre na conta Cowboy") }
    var r = URLRequest(url: URL(string: path, relativeTo: CowboyCloud.origin)!.absoluteURL)
    r.httpMethod = method; r.setValue(cookie, forHTTPHeaderField: "Cookie"); r.timeoutInterval = 40
    if let body { r.setValue("application/json", forHTTPHeaderField: "Content-Type"); r.httpBody = try JSONSerialization.data(withJSONObject: body) }
    let c = URLSessionConfiguration.ephemeral; c.httpShouldSetCookies = false
    let s = URLSession(configuration: c, delegate: CowboyNoRedirect(), delegateQueue: nil); defer { s.finishTasksAndInvalidate() }
    let (data, resp) = try await s.data(for: r)
    let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(code) else {
      let msg = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any])?["error"] as? String
      throw Failure(errorDescription: msg ?? (code == 401 ? "Entre novamente na conta Cowboy" : "Nuvem respondeu HTTP \(code)"))
    }
    return data
  }
  func get<T: Decodable>(_ path: String, _ key: String, as: T.Type) async throws -> T {
    let d = try await call(path)
    let obj = (try JSONSerialization.jsonObject(with: d) as? [String: Any])?[key] ?? []
    return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: obj))
  }
  func decodeJob(_ d: Data) -> IGJob? {
    guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any], let j = o["job"], let dd = try? JSONSerialization.data(withJSONObject: j) else { return nil }
    return try? JSONDecoder().decode(IGJob.self, from: dd)
  }

  func refresh() async {
    busy = true; defer { busy = false }
    do {
      accounts = try await get("/api/ig/accounts", "accounts", as: [IGAccount].self)
      if selected.isEmpty, let first = accounts.first(where: { $0.username == "cowboydoconsorcio" }) ?? accounts.first { selected = [first.id] }
      if liveAccount.isEmpty { liveAccount = selected.first ?? accounts.first?.id ?? "" }
      takes = try await get("/api/ig/takes", "takes", as: [IGTake].self)
      jobs = try await get("/api/ig/jobs", "jobs", as: [IGJob].self)
      edits = (try? await get("/api/ig/edits", "edits", as: [IGEdit].self)) ?? edits
      error = nil
      if jobs.contains(where: { Self.moving($0.state) }) { watchJobs() }
    } catch { self.error = error.localizedDescription }
  }
  static func moving(_ s: String) -> Bool { ["na fila", "aguardando", "preparando", "aprovado", "enviando"].contains(s) }
  func loadProfile(_ account: String) async {
    do {
      let d = try await call("/api/ig/media?account=\(account)&limit=30")
      let o = try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
      posts[account] = try JSONDecoder().decode([IGPost].self, from: JSONSerialization.data(withJSONObject: o["posts"] ?? []))
      stories[account] = try JSONDecoder().decode([IGStory].self, from: JSONSerialization.data(withJSONObject: o["stories"] ?? []))
      error = nil
    } catch { self.error = error.localizedDescription }
  }
  func comments(_ media: String) async -> [IGComment] { (try? await get("/api/ig/comments?media=\(media)", "comments", as: [IGComment].self)) ?? [] }
  func reply(media: String, to comment: String?, text: String) async -> Bool {
    do { _ = try await call("/api/ig/comments", method: "POST", body: ["media": media, "reply_to": comment ?? NSNull(), "text": text]); return true }
    catch { self.error = error.localizedDescription; return false }
  }

  // ---- rascunho -> aprovação -> publicação
  private func draftBody() -> [String: Any] {
    ["accounts": Array(selected), "kind": kind, "fit": fit, "audio": audio, "cover": cover, "cover_ms": Int(coverSec * 1000), "caption": caption, "ai_caption": aiCaption && caption.isEmpty, "hint": hint]
  }
  func draft(_ source: IGSource) async -> Bool {
    let extra: [String: Any]
    switch source { case .take(let t): extra = ["take": t.id]; case .edit(let e): extra = ["studio": e.id] }
    return await draft(extra: extra)
  }
  func draft(extra: [String: Any]) async -> Bool {
    guard !selected.isEmpty else { error = "Escolha pelo menos um perfil"; return false }
    var b = draftBody(); for (k, v) in extra { b[k] = v }
    do { _ = try await call("/api/ig/publish", method: "POST", body: b); jobs = (try? await get("/api/ig/jobs", "jobs", as: [IGJob].self)) ?? jobs; watchJobs(); error = nil; return true }
    catch { self.error = error.localizedDescription; return false }
  }
  func approve(_ job: IGJob, caption: String) async {
    do { _ = try await call("/api/ig/approve", method: "POST", body: ["id": job.id, "caption": caption]); await reloadJobs(); watchJobs(); error = nil }
    catch { self.error = error.localizedDescription }
  }
  func adjust(_ job: IGJob, _ b: [String: Any]) async {
    var body = b; body["id"] = job.id
    do { _ = try await call("/api/ig/draft", method: "POST", body: body); await reloadJobs(); watchJobs(); error = nil }
    catch { self.error = error.localizedDescription }
  }
  func cancel(_ job: String) async { _ = try? await call("/api/ig/cancel", method: "POST", body: ["id": job]); await reloadJobs() }
  func reloadJobs() async { jobs = (try? await get("/api/ig/jobs", "jobs", as: [IGJob].self)) ?? jobs }
  func watchJobs() {
    jobTimer?.invalidate()
    jobTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] t in
      Task { @MainActor in
        guard let self else { t.invalidate(); return }
        await self.reloadJobs()
        if !self.jobs.contains(where: { Self.moving($0.state) }) { t.invalidate(); self.takes = (try? await self.get("/api/ig/takes", "takes", as: [IGTake].self)) ?? self.takes }
      }
    }
  }
  /// legenda por IA agora (worker do Studio), pra conferir antes de criar o rascunho
  func generateCaption(_ source: IGSource) async {
    var b: [String: Any] = ["kind": kind, "accounts": Array(selected), "hint": hint]
    switch source { case .take(let t): b["take"] = t.id; case .edit(let e): b["studio"] = e.id }
    do {
      let d = try await call("/api/ig/ai/copy", method: "POST", body: b)
      guard let id = ((try JSONSerialization.jsonObject(with: d)) as? [String: Any])?["task"] as? String else { return }
      for _ in 0..<240 {
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let r = try JSONSerialization.jsonObject(with: try await call("/api/ig/ai/task?id=\(id)")) as? [String: Any] ?? [:]
        let st = r["status"] as? String ?? ""
        if st == "done" { caption = r["caption"] as? String ?? caption; error = nil; return }
        if st == "failed" { error = "IA: " + (r["error"] as? String ?? "falhou"); return }
        error = st == "queued" ? "IA na fila do Studio (o PC do worker precisa estar ligado)" : "IA escrevendo… " + (r["msg"] as? String ?? "")
      }
    } catch { self.error = error.localizedDescription }
  }
  // ---- edição pelo Studio
  func sendToEdit(_ takes: [String], molde: String, notes: String, whatsapp: Bool) async -> Bool {
    do { _ = try await call("/api/ig/edit", method: "POST", body: ["takes": takes, "molde": molde, "notes": notes, "whatsapp": whatsapp]); edits = (try? await get("/api/ig/edits", "edits", as: [IGEdit].self)) ?? edits; error = nil; return true }
    catch { self.error = error.localizedDescription; return false }
  }
  /// a câmera terminou uma gravação (direto na nuvem): "preparar ao parar" (vai pra aprovação) e fim da live
  func recordingFinished(cid: String) {
    if liveRunning { liveRunning = false; liveId = nil; liveKey = ""; DispatchQueue.main.asyncAfter(deadline: .now() + 6) { self.liveTimer?.invalidate(); self.liveTimer = nil } }
    guard enabled, autoPost else { return }
    autoPost = false
    Task { _ = await draft(extra: ["cid": cid]) }
  }

  // ---- live
  func armLive() async {
    guard let cookie = CowboyCloud.shared.credential else { error = "Entre na conta Cowboy"; return }
    do {
      let d = try await call("/api/ig/live/start", method: "POST", body: ["url": liveURL.trimmingCharacters(in: .whitespacesAndNewlines), "key": liveKey.trimmingCharacters(in: .whitespacesAndNewlines), "account": liveAccount])
      let st = try JSONDecoder().decode(IGLiveStatus.self, from: d)
      liveId = st.id; liveStatus = st; IGLiveUplink.arm(id: st.id, cookie: cookie); error = nil
    } catch { self.error = error.localizedDescription }
  }
  func disarmLive() {
    IGLiveUplink.disarm()
    if let id = liveId, !liveRunning { Task { _ = try? await call("/api/ig/live/stop?id=\(id)", method: "POST") }; liveId = nil; liveStatus = nil }
  }
  var liveArmed: Bool { liveId != nil && !liveRunning }
  /// a câmera começou a gravar com a live armada
  func liveStarted() {
    guard let id = liveId else { return }
    liveRunning = true
    liveTimer?.invalidate()
    liveTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
      Task { @MainActor in
        guard let self, let d = try? await self.call("/api/ig/live/status?id=\(id)"), let st = try? JSONDecoder().decode(IGLiveStatus.self, from: d) else { return }
        self.liveStatus = st
      }
    }
  }
}

// ---------------------------------------------------------------- imagens e vídeo (os da nuvem precisam do login)
@MainActor final class IGImageCache { static let shared = NSCache<NSString, UIImage>() }
struct IGImage: View {
  let path: String?
  var corner: CGFloat = 6
  @State private var image: UIImage?
  var body: some View {
    ZStack {
      Rectangle().fill(Color.white.opacity(0.08))
      if let image { Image(uiImage: image).resizable().scaledToFill() } else { Image(systemName: "photo").foregroundStyle(.white.opacity(0.3)) }
    }
    .clipShape(RoundedRectangle(cornerRadius: corner))
    .task(id: path) { await load() }
  }
  @MainActor private func load() async {
    guard let path, !path.isEmpty else { image = nil; return }
    if let c = IGImageCache.shared.object(forKey: path as NSString) { image = c; return }
    let url = URL(string: path, relativeTo: CowboyCloud.origin)!.absoluteURL
    var r = URLRequest(url: url)
    if url.host == CowboyCloud.origin.host, let cookie = CowboyCloud.shared.credential { r.setValue(cookie, forHTTPHeaderField: "Cookie") }
    guard let (d, _) = try? await URLSession.shared.data(for: r), let img = UIImage(data: d) else { return }
    IGImageCache.shared.setObject(img, forKey: path as NSString); image = img
  }
}
struct IGVideoSheet: View {
  let path: String
  @Environment(\.dismiss) private var dismiss
  @State private var player: AVPlayer?
  var body: some View {
    NavigationStack {
      ZStack { Color.black.ignoresSafeArea(); if let player { VideoPlayer(player: player) } else { ProgressView() } }
        .toolbar { Button("OK") { player?.pause(); dismiss() } }
    }
    .onAppear {
      let url = URL(string: path, relativeTo: CowboyCloud.origin)!.absoluteURL
      let headers = ["Cookie": CowboyCloud.shared.credential ?? ""]
      let p = AVPlayer(playerItem: AVPlayerItem(asset: AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])))
      player = p; p.play()
    }
    .preferredColorScheme(.dark)
  }
}
struct IGVideoLink: Identifiable { let path: String; var id: String { path } }

// ---------------------------------------------------------------- painel
struct InstagramPanel: View {
  @ObservedObject var ig: IGModule
  var logWithoutBake: Bool
  var recording: Bool
  @Environment(\.dismiss) private var dismiss
  @State private var tab = 0
  @State private var compose: IGSource?
  @State private var selecting = false
  @State private var picked: Set<String> = []
  @State private var editSheet = false
  @State private var profile = ""
  @State private var openPost: IGPost?
  @State private var video: IGVideoLink?
  private let gold = Color(red: 1, green: 0.8, blue: 0)

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        Picker("", selection: $tab) {
          Text(ig.pendingApproval > 0 ? "Publicar (\(ig.pendingApproval))" : "Publicar").tag(0); Text("Editados").tag(1); Text("Perfil").tag(2); Text("Ao vivo").tag(3)
        }.pickerStyle(.segmented).padding(.horizontal).padding(.vertical, 8)
        if let e = ig.error { Text(e).font(.caption).foregroundStyle(.orange).padding(.horizontal).frame(maxWidth: .infinity, alignment: .leading) }
        switch tab {
        case 0: publishTab
        case 1: editsTab
        case 2: profileTab
        default: liveTab
        }
      }
      .navigationTitle("Instagram").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { if ig.busy { ProgressView() } else { Button { Task { await ig.refresh() } } label: { Image(systemName: "arrow.clockwise") } } }
        ToolbarItem(placement: .topBarTrailing) { Button("OK") { dismiss() } }
      }
      .sheet(item: $openPost) { p in IGPostView(ig: ig, post: p) }
      .sheet(item: $compose) { s in IGComposeView(ig: ig, source: s) }
      .sheet(item: $video) { v in IGVideoSheet(path: v.path) }
      .sheet(isPresented: $editSheet) { IGEditOrderView(ig: ig, takes: Array(picked)) { selecting = false; picked = []; tab = 1 } }
    }
    .tint(gold).preferredColorScheme(.dark)
    .task { await ig.refresh(); if profile.isEmpty { profile = ig.selected.first ?? ig.accounts.first?.id ?? "" } }
  }

  // ---- publicar: aprovação, preparar ao parar, biblioteca
  private var publishTab: some View {
    Form {
      let waiting = ig.jobs.filter { $0.state == "aguardando aprovação" }
      if !waiting.isEmpty {
        Section { ForEach(waiting) { j in IGApprovalCard(ig: ig, job: j) { video = IGVideoLink(path: $0) } } } header: { Text("Aguardando aprovação") } footer: { Text("Nada vai pro Instagram sem o Aprovar.") }
      }
      let other = ig.jobs.filter { $0.state != "aguardando aprovação" }
      if !other.isEmpty { Section("Envios") { ForEach(other.prefix(8)) { j in jobRow(j) } } }
      Section {
        Toggle(isOn: $ig.autoPost) { Label("Preparar a próxima gravação", systemImage: "record.circle") }.disabled(ig.selected.isEmpty || ig.kind == "feed")
        if ig.autoPost {
          IGFormatFields(ig: ig, photo: false, edit: false)
          Text("Grave com todos os ajustes da câmera. Ao parar, a tomada sobe, a nuvem termina cor/efeitos, prepara \(IGModule.kinds.first { $0.id == ig.kind }?.label ?? ig.kind) com capa e legenda e deixa aqui pra você APROVAR. Desliga sozinho depois.").font(.caption2)
        }
      } header: { Text("Direto da câmera") }
      Section {
        ForEach(ig.takes) { t in
          Button {
            if selecting { if picked.contains(t.id) { picked.remove(t.id) } else { picked.insert(t.id) } } else { compose = .take(t) }
          } label: { takeRow(t) }.buttonStyle(.plain)
        }
      } header: {
        HStack {
          Text("Galeria da nuvem")
          Spacer()
          Button(selecting ? "Cancelar" : "Selecionar") { selecting.toggle(); picked = [] }.font(.caption.weight(.bold))
        }
      } footer: {
        if selecting { Button { editSheet = true } label: { Label("Mandar \(picked.count) pra edição", systemImage: "wand.and.stars") }.disabled(picked.isEmpty).buttonStyle(.borderedProminent).padding(.top, 6) }
        else { Text("Toque numa tomada pra preparar o post (vídeo bruto). \"Selecionar\" manda várias pra edição no molde.") }
      }
    }
    .refreshable { await ig.refresh() }
  }
  private func takeRow(_ t: IGTake) -> some View {
    HStack(spacing: 10) {
      if selecting { Image(systemName: picked.contains(t.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(picked.contains(t.id) ? gold : .secondary).font(.title3) }
      IGImage(path: t.thumb).frame(width: 46, height: 64)
      VStack(alignment: .leading, spacing: 3) {
        Text(t.title ?? t.id).font(.subheadline.weight(.semibold)).lineLimit(1)
        Text([t.kind == "photo" ? "Foto" : Self.dur(t.dur), t.w > 0 ? "\(t.w)×\(t.h)" : nil, t.color].compactMap { $0 }.joined(separator: " · ")).font(.caption2).foregroundStyle(.secondary)
        if let b = t.busy { Text(b).font(.caption2).foregroundStyle(.orange) }
        if let p = t.ig, !p.isEmpty { Text("Postada: " + p.compactMap { $0.user.map { "@" + $0 } }.joined(separator: ", ")).font(.caption2).foregroundStyle(gold) }
      }
      Spacer()
      if !selecting { Image(systemName: "chevron.right").foregroundStyle(.secondary) }
    }
  }
  private func jobRow(_ j: IGJob) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(IGModule.kinds.first { $0.id == j.kind }?.label ?? j.kind).font(.subheadline.weight(.semibold))
        Spacer()
        Text(j.state + (j.state == "preparando" && j.pct > 0 && j.pct < 100 ? " \(j.pct)%" : "")).font(.caption.weight(.semibold)).foregroundStyle(j.state == "publicado" ? .green : ["falhou", "cancelado"].contains(j.state) ? .red : .orange)
      }
      if let s = j.step { Text(s).font(.caption2).foregroundStyle(.secondary) }
      if let e = j.err { Text(e).font(.caption2).foregroundStyle(.red) }
      ForEach(j.accounts, id: \.id) { a in
        HStack(spacing: 6) {
          Text("@" + a.username).font(.caption2)
          Text(a.state + (a.step.map { " · " + $0 } ?? "")).font(.caption2).foregroundStyle(a.state == "publicado" ? .green : a.state == "falhou" ? .red : .secondary)
          Spacer()
          if let l = a.permalink, let u = URL(string: l) { Link("Abrir", destination: u).font(.caption2.weight(.bold)) }
        }
        if let e = a.err { Text(e).font(.caption2).foregroundStyle(.red) }
      }
      if ["na fila", "aguardando", "preparando"].contains(j.state) { Button("Cancelar", role: .destructive) { Task { await ig.cancel(j.id) } }.font(.caption) }
    }
  }
  static func dur(_ s: Double) -> String { let n = Int(s.rounded()); return String(format: "%d:%02d", n / 60, n % 60) }

  // ---- editados (Studio)
  private var editsTab: some View {
    List {
      if ig.edits.isEmpty { Text("Nada editado ainda. Na aba Publicar, toque em Selecionar na galeria e mande pra edição.").font(.caption) }
      ForEach(ig.edits) { e in
        HStack(alignment: .top, spacing: 10) {
          IGImage(path: e.thumb).frame(width: 54, height: 96)
          VStack(alignment: .leading, spacing: 4) {
            Text(e.title ?? e.id).font(.subheadline.weight(.semibold)).lineLimit(2)
            if let m = e.molde { Text("Molde: " + (IGModule.moldes.first { $0.id == m }?.label ?? m)).font(.caption2).foregroundStyle(.secondary) }
            if let b = e.busy { Text(b + (e.stage.map { " · " + $0 } ?? "") + " (\(e.done ?? 0)/\(e.total ?? 0))").font(.caption2).foregroundStyle(.orange) }
            if e.post?.status == "publicado" { Text("Publicado").font(.caption2).foregroundStyle(.green) }
            if let w = e.whatsapp { Label(w == "enviado" ? "Enviado no seu WhatsApp" : "Vai pro seu WhatsApp ao terminar", systemImage: "paperplane").font(.caption2).foregroundStyle(w == "enviado" ? .green : .secondary) }
            HStack(spacing: 14) {
              if let f = e.final { Button { video = IGVideoLink(path: f) } label: { Label("Ver", systemImage: "play.fill") } }
              if e.final != nil && e.busy == nil { Button { compose = .edit(e) } label: { Label("Preparar post", systemImage: "paperplane.fill") } }
              if let l = e.post?.permalink, let u = URL(string: l) { Link("Abrir", destination: u) }
            }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
          }
        }
      }
    }
    .refreshable { await ig.refresh() }
  }

  // ---- perfil (o Instagram real)
  private var profileTab: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        Picker("Perfil", selection: $profile) { ForEach(ig.accounts) { a in Text("@" + a.username).tag(a.id) } }.pickerStyle(.segmented).padding(.horizontal)
        if let a = ig.accounts.first(where: { $0.id == profile }) {
          HStack(spacing: 14) {
            IGImage(path: a.pic, corner: 34).frame(width: 68, height: 68)
            VStack(alignment: .leading, spacing: 4) {
              Text(a.name ?? a.username).font(.headline)
              HStack(spacing: 14) { stat(a.posts, "posts"); stat(a.followers, "seguidores"); stat(a.following, "seguindo") }
            }
          }.padding(.horizontal)
          if let b = a.bio, !b.isEmpty { Text(b).font(.caption).padding(.horizontal) }
          if let st = ig.stories[profile], !st.isEmpty {
            Text("Stories no ar").font(.caption.weight(.bold)).padding(.horizontal)
            ScrollView(.horizontal, showsIndicators: false) {
              HStack(spacing: 8) { ForEach(st) { s in Link(destination: URL(string: s.url ?? "https://instagram.com")!) { IGImage(path: s.thumb, corner: 8).frame(width: 64, height: 110).overlay(RoundedRectangle(cornerRadius: 8).stroke(gold, lineWidth: 2)) } } }.padding(.horizontal)
            }
          }
          LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 2), count: 3), spacing: 2) {
            ForEach(ig.posts[profile] ?? []) { p in
              Button { openPost = p } label: {
                IGImage(path: p.thumb, corner: 0).aspectRatio(4.0 / 5.0, contentMode: .fill)
                  .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 6) { Label("\(p.likes ?? 0)", systemImage: "heart.fill"); Label("\(p.comments ?? 0)", systemImage: "bubble.right.fill") }
                      .font(.system(size: 9, weight: .bold)).padding(4).background(.black.opacity(0.55), in: Capsule()).padding(3)
                  }
                  .overlay(alignment: .topTrailing) { if p.type == "reels" || p.type == "video" { Image(systemName: "play.fill").font(.caption2).padding(4) } }
              }.buttonStyle(.plain)
            }
          }
        }
      }.padding(.vertical, 8)
    }
    .refreshable { await ig.loadProfile(profile) }
    .task(id: profile) { if !profile.isEmpty { await ig.loadProfile(profile) } }
  }
  private func stat(_ n: Int?, _ l: String) -> some View { VStack(spacing: 0) { Text("\(n ?? 0)").font(.subheadline.weight(.bold)); Text(l).font(.caption2).foregroundStyle(.secondary) } }

  // ---- ao vivo
  private var liveTab: some View {
    Form {
      Section {
        Text("1. No instagram.com (computador, ou Safari > \"Versão para computador\"), no perfil certo: Criar > Ao vivo. Copie a URL e a Chave do stream.\n2. Cole aqui e toque em Armar.\n3. Grave com a câmera do app: a live usa a mesma imagem do arquivo (cor, look, Extrema, zoom, desfoque).\n4. Quando a prévia aparecer no instagram.com, toque em \"Transmitir ao vivo\" lá (é a sua aprovação). Parar a gravação encerra a transmissão.").font(.caption)
        if logWithoutBake { Label("A câmera está em LOG sem conversão no iPhone: a live sairia lavada. Ligue \"Arquivo final em Rec.709 + look\" nos Ajustes.", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange) }
      } header: { Text("Como funciona") }
      Section("Transmissão") {
        Picker("Comentários de", selection: $ig.liveAccount) { ForEach(ig.accounts) { a in Text("@" + a.username).tag(a.id) } }
        HStack {
          TextField("URL do stream (rtmps://…)", text: $ig.liveURL).textInputAutocapitalization(.never).autocorrectionDisabled().font(.caption)
          Button { ig.liveURL = UIPasteboard.general.string ?? ig.liveURL } label: { Image(systemName: "doc.on.clipboard") }
        }
        HStack {
          SecureField("Chave do stream", text: $ig.liveKey).font(.caption)
          Button { ig.liveKey = UIPasteboard.general.string ?? ig.liveKey } label: { Image(systemName: "doc.on.clipboard") }
        }
        if ig.liveRunning { Label("Transmitindo — pare a gravação pra encerrar", systemImage: "dot.radiowaves.left.and.right").foregroundStyle(.red) }
        else if ig.liveArmed { Label("Armada: começa quando você apertar gravar", systemImage: "checkmark.seal.fill").foregroundStyle(.green); Button("Desarmar", role: .destructive) { ig.disarmLive() } }
        else { Button { Task { await ig.armLive() } } label: { Label("Armar live", systemImage: "dot.radiowaves.left.and.right") }.disabled(ig.liveURL.isEmpty || ig.liveKey.isEmpty || recording) }
      }
      if let st = ig.liveStatus {
        Section("Estado") {
          Text("\(st.status) · \(st.kb ?? 0) KB enviados · \(st.chunks ?? 0) pedaços").font(.caption)
          if let e = st.err { Text(e).font(.caption).foregroundStyle(.red) }
          ForEach(st.comments ?? []) { c in Text("@\(c.user ?? "?"): \(c.text ?? "")").font(.caption) }
        }
      }
    }
  }
}

// ---- campos do formato (rascunho e "preparar ao parar")
struct IGFormatFields: View {
  @ObservedObject var ig: IGModule
  var photo: Bool
  var edit: Bool
  var video: String? = nil
  @State private var pickFrame = false
  var body: some View {
    Picker("Onde", selection: $ig.kind) {
      ForEach(IGModule.kinds.filter { photo ? ($0.id == "feed" || $0.id == "story") : $0.id != "feed" }, id: \.id) { k in Text(k.label).tag(k.id) }
    }
    Picker("Enquadrar", selection: $ig.fit) { Text("Preencher 9:16").tag("cover"); Text("Inteiro").tag("contain") }
    if !photo { Toggle("Com áudio", isOn: $ig.audio) }
    if !photo && ig.kind != "story" {
      Picker("Capa", selection: $ig.cover) { ForEach(IGModule.covers.filter { edit || $0.id != "studio" }, id: \.id) { c in Text(c.label).tag(c.id) } }
      if ig.cover == "frame" {
        if let v = video {
          Button { pickFrame = true } label: { HStack { Text("Quadro da capa"); Spacer(); Text(String(format: "%.2f s", ig.coverSec)).foregroundStyle(.secondary); Image(systemName: "photo.on.rectangle") } }
            .sheet(isPresented: $pickFrame) { IGFramePickerSheet(path: v, start: ig.coverSec) { ig.coverSec = $0 } }
        } else { Text("O quadro da capa se escolhe na aprovação, vendo a prévia").font(.caption2).foregroundStyle(.secondary) }
      }
    }
    if ig.kind != "story" { Toggle("Legenda por IA (se ficar em branco)", isOn: $ig.aiCaption) }
    TextField("Observações pra IA (opcional)", text: $ig.hint, axis: .vertical).lineLimit(1...3)
  }
}

// ---- preparar um post (vira rascunho e vai pra aprovação)
struct IGComposeView: View {
  @ObservedObject var ig: IGModule
  let source: IGSource
  @Environment(\.dismiss) private var dismiss
  @State private var working = false
  @State private var genCaption = false
  var body: some View {
    NavigationStack {
      Form {
        Section {
          HStack(spacing: 12) {
            IGImage(path: source.thumb).frame(width: 54, height: 96)
            Text(source.title).font(.subheadline.weight(.semibold))
          }
        }
        Section("Perfis") {
          ForEach(ig.accounts) { a in
            Button { if ig.selected.contains(a.id) { ig.selected.remove(a.id) } else { ig.selected.insert(a.id) } } label: {
              HStack { Text("@" + a.username); Spacer(); Image(systemName: ig.selected.contains(a.id) ? "checkmark.circle.fill" : "circle") }
            }.buttonStyle(.plain)
          }
        }
        Section("Formato") { IGFormatFields(ig: ig, photo: source.isPhoto, edit: { if case .edit = source { return true }; return false }(), video: source.video) }
        if ig.kind != "story" {
          Section {
            TextField("Legenda", text: $ig.caption, axis: .vertical).lineLimit(3...12)
            Button { genCaption = true; Task { await ig.generateCaption(source); genCaption = false } } label: {
              HStack { Label("Gerar copy por IA agora", systemImage: "sparkles"); if genCaption { Spacer(); ProgressView() } }
            }.disabled(genCaption)
          } header: { Text("Legenda") } footer: { Text("A IA roda no worker do Studio (Claude Code + skill do Cowboy): transcreve, olha os quadros e escreve no estilo do perfil.") }
        }
        if let e = ig.error { Text(e).font(.caption).foregroundStyle(.orange) }
        Section {
          Button {
            working = true
            Task { if await ig.draft(source) { ig.caption = ""; dismiss() }; working = false }
          } label: { HStack { Spacer(); if working { ProgressView() } else { Label("Preparar e mandar pra aprovação", systemImage: "checkmark.shield") }; Spacer() } }
            .disabled(working || ig.selected.isEmpty)
        } footer: { Text("Prepara o arquivo no padrão do Instagram, a capa e a legenda. Só publica quando você aprovar na aba Publicar.") }
      }
      .navigationTitle("Preparar post").navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Fechar") { dismiss() } }
      .onAppear {
        if source.isPhoto && ig.kind != "story" { ig.kind = "feed" } else if !source.isPhoto && ig.kind == "feed" { ig.kind = "reels" }
        if case .edit(let e) = source { if ig.caption.isEmpty { ig.caption = e.caption ?? "" }; if e.thumb != nil { ig.cover = "studio" } } else if ig.cover == "studio" { ig.cover = "frame" }
      }
    }.preferredColorScheme(.dark)
  }
}

// ---- aprovação: prévia, ajustes e Aprovar
struct IGApprovalCard: View {
  @ObservedObject var ig: IGModule
  let job: IGJob
  var play: (String) -> Void
  @State private var caption = ""
  @State private var sec = 0.0
  @State private var sending = false
  @State private var pickFrame = false
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(alignment: .top, spacing: 10) {
        Button { if let p = job.preview, p.hasSuffix(".mp4") { play(p) } } label: {
          IGImage(path: job.cover_url ?? (job.preview?.hasSuffix(".jpg") == true ? job.preview : nil)).frame(width: 72, height: 128)
            .overlay { if job.preview?.hasSuffix(".mp4") == true { Image(systemName: "play.circle.fill").font(.title).shadow(radius: 3) } }
        }.buttonStyle(.plain)
        VStack(alignment: .leading, spacing: 3) {
          Text(IGModule.kinds.first { $0.id == job.kind }?.label ?? job.kind).font(.subheadline.weight(.bold))
          Text(job.accounts.map { "@" + $0.username }.joined(separator: ", ")).font(.caption2)
          Text((job.audio == false ? "sem áudio · " : "") + (job.fit == "contain" ? "inteiro" : "preenchido 9:16")).font(.caption2).foregroundStyle(.secondary)
          if let e = job.err { Text(e).font(.caption2).foregroundStyle(.red) }
        }
      }
      if job.kind != "story" { TextField("Legenda", text: $caption, axis: .vertical).lineLimit(3...10).font(.caption) }
      if job.kind != "story" && job.preview?.hasSuffix(".mp4") == true {
        Button { pickFrame = true } label: { Label("Escolher o quadro da capa", systemImage: "photo.on.rectangle") }.font(.caption.weight(.semibold)).buttonStyle(.borderless)
          .sheet(isPresented: $pickFrame) { if let p = job.preview { IGFramePickerSheet(path: p, start: sec) { s in sec = s; Task { await ig.adjust(job, ["cover_ms": Int((s * 1000).rounded())]) } } } }
        HStack(spacing: 14) {
          Button("Capa IA Cowboy") { Task { await ig.adjust(job, ["redo_cover": "cowboy", "caption": caption]) } }
          Button("Capa IA livre") { Task { await ig.adjust(job, ["redo_cover": "livre", "caption": caption]) } }
          Button("Refazer legenda") { Task { await ig.adjust(job, ["redo_caption": true]) } }
        }.font(.caption2.weight(.semibold)).buttonStyle(.borderless)
      }
      HStack {
        Button(role: .destructive) { Task { await ig.cancel(job.id) } } label: { Text("Descartar") }.buttonStyle(.borderless)
        Spacer()
        Button { sending = true; Task { await ig.approve(job, caption: caption); sending = false } } label: { if sending { ProgressView() } else { Label("Aprovar e publicar", systemImage: "checkmark.seal.fill") } }
          .buttonStyle(.borderedProminent).disabled(sending)
      }
    }
    .padding(.vertical, 4)
    .onAppear { caption = job.caption ?? "" }
    .onChange(of: job.caption) { _, v in caption = v ?? caption }
  }
}

// ---- mandar pra edição (Studio, no molde)
struct IGEditOrderView: View {
  @ObservedObject var ig: IGModule
  let takes: [String]
  var done: () -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var molde = UserDefaults.standard.string(forKey: "igMolde") ?? "ricardo_boreal"
  @State private var notes = ""
  @State private var working = false
  @State private var whatsapp = UserDefaults.standard.object(forKey: "igEditWA") as? Bool ?? true
  var body: some View {
    NavigationStack {
      Form {
        Section("\(takes.count) tomada(s)") {
          Picker("Molde", selection: $molde) { ForEach(IGModule.moldes, id: \.id) { m in Text(m.label).tag(m.id) } }
          TextField("Observações pro editor (cliente, história, o que destacar, onde estão as referências…)", text: $notes, axis: .vertical).lineLimit(3...8)
          Toggle("Enviar o resultado pro Thyayrô no WhatsApp (documento original)", isOn: $whatsapp)
        }
        Section {
          Button {
            working = true; UserDefaults.standard.set(molde, forKey: "igMolde")
            UserDefaults.standard.set(whatsapp, forKey: "igEditWA")
            Task { if await ig.sendToEdit(takes, molde: molde, notes: notes, whatsapp: whatsapp) { done(); dismiss() }; working = false }
          } label: { HStack { Spacer(); if working { ProgressView() } else { Label("Mandar pra edição", systemImage: "wand.and.stars") }; Spacer() } }.disabled(working)
        } footer: { Text("O agente do Cowboy Studio (Claude Code no PC, skill edicao-shorts-cowboy) edita no molde escolhido. O resultado aparece em Editados e só vai pro Instagram com a sua aprovação.") }
        if let e = ig.error { Text(e).font(.caption).foregroundStyle(.orange) }
      }
      .navigationTitle("Edição").navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("Fechar") { dismiss() } }
    }.preferredColorScheme(.dark)
  }
}

// ---- um post: legenda, comentários reais, responder
struct IGPostView: View {
  @ObservedObject var ig: IGModule
  let post: IGPost
  @State private var comments: [IGComment] = []
  @State private var text = ""
  @State private var replyTo: IGComment?
  @Environment(\.dismiss) private var dismiss
  var body: some View {
    NavigationStack {
      List {
        Section {
          IGImage(path: post.thumb).aspectRatio(4.0 / 5.0, contentMode: .fit).frame(maxHeight: 280)
          if let c = post.caption, !c.isEmpty { Text(c).font(.caption) }
          HStack { Label("\(post.likes ?? 0)", systemImage: "heart.fill"); Label("\(post.comments ?? 0)", systemImage: "bubble.right.fill"); Spacer(); if let u = post.url, let url = URL(string: u) { Link("Abrir no Instagram", destination: url) } }.font(.caption)
        }
        Section("Comentários") {
          if comments.isEmpty { Text("Nenhum comentário").font(.caption).foregroundStyle(.secondary) }
          ForEach(comments) { c in
            VStack(alignment: .leading, spacing: 4) {
              Text("@\(c.user ?? "?")").font(.caption.weight(.bold)) + Text("  " + (c.text ?? "")).font(.caption)
              ForEach(c.replies ?? []) { r in (Text("↳ @\(r.user ?? "?")").font(.caption2.weight(.bold)) + Text("  " + (r.text ?? "")).font(.caption2)).padding(.leading, 12) }
              Button("Responder") { replyTo = c }.font(.caption2)
            }
          }
        }
      }
      .safeAreaInset(edge: .bottom) {
        HStack {
          TextField(replyTo.map { "Responder @\($0.user ?? "")" } ?? "Comentar no post", text: $text, axis: .vertical).lineLimit(1...3)
          if replyTo != nil { Button { replyTo = nil } label: { Image(systemName: "xmark.circle.fill") } }
          Button {
            let t = text; Task { if await ig.reply(media: post.id, to: replyTo?.id, text: t) { text = ""; replyTo = nil; comments = await ig.comments(post.id) } }
          } label: { Image(systemName: "paperplane.fill") }.disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
        }.padding(10).background(.bar)
      }
      .navigationTitle("Post").navigationBarTitleDisplayMode(.inline)
      .toolbar { Button("OK") { dismiss() } }
      .task { comments = await ig.comments(post.id) }
    }.preferredColorScheme(.dark)
  }
}

// ---- na tela da câmera, gravando com a live: estado + últimos comentários da live do Instagram
struct IGLiveOverlay: View {
  @ObservedObject var ig: IGModule
  var body: some View {
    if ig.liveRunning {
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 6) {
          Circle().fill(ig.liveStatus?.status == "no ar" ? Color.red : .orange).frame(width: 8, height: 8)
          Text("IG " + (ig.liveStatus?.status ?? "conectando")).font(.system(size: 11, weight: .heavy))
        }.padding(.horizontal, 8).padding(.vertical, 4).background(.black.opacity(0.6), in: Capsule())
        ForEach((ig.liveStatus?.comments ?? []).suffix(4)) { c in
          (Text("@\(c.user ?? "?") ").font(.system(size: 11, weight: .bold)) + Text(c.text ?? "").font(.system(size: 11)))
            .padding(.horizontal, 8).padding(.vertical, 3).background(.black.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        }
      }.foregroundStyle(.white).allowsHitTesting(false)
    }
  }
}

// ---- capa: escolher o quadro VENDO a imagem, quadro a quadro (o arquivo vem da nuvem, com o login)
struct IGFramePickerSheet: View {
  let path: String
  let start: Double
  var onPick: (Double) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var seconds = 0.0
  @State private var duration = 0.0
  @State private var fps = 30.0
  @State private var image: UIImage?
  @State private var loading = true
  @State private var failed: String?
  @State private var gen: AVAssetImageGenerator?
  var body: some View {
    NavigationStack {
      VStack(spacing: 14) {
        ZStack {
          Rectangle().fill(Color.black)
          if let image { Image(uiImage: image).resizable().scaledToFit() }
          if loading { ProgressView() }
          if let failed { Text(failed).font(.caption).foregroundStyle(.orange).padding() }
        }.frame(maxWidth: .infinity).frame(height: 420).clipShape(RoundedRectangle(cornerRadius: 10))
        Text(String(format: "%.3f s  ·  quadro %d de %d", seconds, Int((seconds * fps).rounded()), Int((duration * fps).rounded()))).font(.callout.monospacedDigit())
        if duration > 0 { Slider(value: $seconds, in: 0...duration) }
        HStack(spacing: 10) {
          step("gobackward", -1, "−1 s"); step("chevron.left", -1 / fps, "−1 quadro"); step("chevron.right", 1 / fps, "+1 quadro"); step("goforward", 1, "+1 s")
        }
        Spacer()
      }
      .padding()
      .navigationTitle("Quadro da capa").navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarLeading) { Button("Cancelar") { dismiss() } }
        ToolbarItem(placement: .topBarTrailing) { Button("Usar este") { onPick(seconds); dismiss() }.bold().disabled(image == nil) }
      }
      .task { await setup() }
      .onChange(of: seconds) { _, _ in render() }
    }.preferredColorScheme(.dark)
  }
  private func step(_ icon: String, _ d: Double, _ label: String) -> some View {
    Button { seconds = snap(min(max(0, seconds + d), duration)) } label: {
      VStack(spacing: 3) { Image(systemName: icon).font(.title3); Text(label).font(.caption2) }.frame(maxWidth: .infinity).padding(.vertical, 8)
        .background(Color.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }.buttonStyle(.plain).disabled(duration == 0)
  }
  private func snap(_ s: Double) -> Double { (s * fps).rounded() / fps }
  @MainActor private func setup() async {
    let url = URL(string: path, relativeTo: CowboyCloud.origin)!.absoluteURL
    let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": ["Cookie": CowboyCloud.shared.credential ?? ""]])
    do {
      duration = try await asset.load(.duration).seconds
      if let track = try await asset.loadTracks(withMediaType: .video).first { let f = Double(try await track.load(.nominalFrameRate)); if f > 1 { fps = f } }
    } catch { failed = "Não abri o vídeo: \(error.localizedDescription)"; loading = false; return }
    let g = AVAssetImageGenerator(asset: asset)
    g.appliesPreferredTrackTransform = true
    g.requestedTimeToleranceBefore = .zero; g.requestedTimeToleranceAfter = .zero   // quadro EXATO
    g.maximumSize = CGSize(width: 1080, height: 1080)
    gen = g
    seconds = snap(min(max(0, start), duration))
    render()
  }
  private func render() {
    guard let g = gen else { return }
    g.cancelAllCGImageGeneration()
    loading = true
    let t = CMTime(seconds: seconds, preferredTimescale: 60000)
    g.generateCGImageAsynchronously(for: t) { cg, _, err in
      DispatchQueue.main.async {
        if let cg { image = UIImage(cgImage: cg); failed = nil; loading = false }
        else if let e = err as NSError?, e.code != NSUserCancelledError, e.code != -11819 { failed = e.localizedDescription; loading = false }
      }
    }
  }
}
