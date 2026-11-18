import SwiftUI
import AVFoundation
import CryptoKit
import Foundation
import Network
import UIKit

// PRORES LOG (0.13.0, pedido do operador 17/11). Desenho aprovado por ele:
//  • o MESTRE ProRes (422 HQ/422/LT, Apple Log 10 bits) grava num .mov no aparelho — SSD externo no USB-C quando houver,
//    senão o iPhone (Arquivos › No Meu iPhone › Cowboy Rec › ProRes) — fragmentado a cada 2 s (sobrevive a travamento);
//  • ao mesmo tempo um PROXY 1080p HEVC Log (~20 Mb/s) sobe ao vivo pelo caminho de sempre (pedaços de 1 s com recibo):
//    galeria, HLS, conversão e efeitos da VPS seguem iguais;
//  • ao parar, o mestre sobe SÓ NO WI-FI em trechos de 8 MB com recibo, anexado à MESMA tomada; a VPS só guarda (não
//    converte) e o PC puxa pro F:\CowboyRec conferindo sha256 (arquivar.py) e a VPS apaga a cópia dela;
//  • o iPhone NUNCA apaga o mestre sozinho: só por ação manual do operador (Ajustes › Mestres ProRes).

/// SSD externo (iOS 17+): a API da Apple pra gravar em disco USB-C. Sem SSD, ProRes fica limitado a 4K30.
final class ExternalSSD: ObservableObject, @unchecked Sendable {
  static let shared = ExternalSSD()
  struct Info: Equatable { let name: String; let freeBytes: Int64; let totalBytes: Int64; let notRecommended: Bool }
  @Published private(set) var info: Info?
  @Published private(set) var authorized = AVExternalStorageDevice.authorizationStatus == .authorized
  var onChange: (() -> Void)?
  private var observation: NSKeyValueObservation?
  private var started = false
  var supported: Bool { AVExternalStorageDeviceDiscoverySession.isSupported }

  func start() {
    guard !started else { refresh(); return }
    started = true
    guard supported, let discovery = AVExternalStorageDeviceDiscoverySession.shared else { Diag.step("ssd-api", ["suportado": false], send: false); return }
    if AVExternalStorageDevice.authorizationStatus == .notDetermined {
      AVExternalStorageDevice.requestAccess { ok in
        DispatchQueue.main.async { self.authorized = ok; self.refresh(); self.onChange?() }
      }
    }
    observation = discovery.observe(\.externalStorageDevices, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.refresh(); self?.onChange?() }
    }
    refresh()
  }
  func refresh() {
    authorized = AVExternalStorageDevice.authorizationStatus == .authorized
    let dev = current
    let next = dev.map { Info(name: $0.displayName ?? "SSD", freeBytes: Int64($0.freeSize), totalBytes: Int64($0.totalSize), notRecommended: $0.isNotRecommendedForCaptureUse) }
    if next != info {
      info = next
      Diag.step("ssd", ["ligado": next != nil, "nome": next?.name ?? "", "livre_gb": Double(next?.freeBytes ?? 0) / 1e9, "nao_recomendado": next?.notRecommended ?? false, "autorizado": authorized])
    }
  }
  private var current: AVExternalStorageDevice? {
    guard supported, authorized else { return nil }
    return AVExternalStorageDeviceDiscoverySession.shared?.externalStorageDevices.first { $0.isConnected }
  }
  var connected: Bool { current != nil }
  /// arquivo novo no SSD (nome dado pelo próprio iOS, na pasta de mídia do disco)
  func nextURL() -> URL? {
    guard let dev = current else { return nil }
    var urls: [URL] = []
    if let ex = CowboyObjC.catching({ urls = (try? dev.nextAvailableURLs(withPathExtensions: ["mov"])) ?? [] }) { Diag.step("ssd-url-fail", ["err": ex]); return nil }
    guard let url = urls.first else { return nil }
    _ = url.startAccessingSecurityScopedResource()
    return url
  }
}

/// Fila dos mestres ProRes: guarda (nunca apaga sozinha) e sobe pelo Wi-Fi com recibo, anexado à tomada do proxy.
final class ProResMasters: ObservableObject, @unchecked Sendable {
  static let shared = ProResMasters()
  struct Item: Codable, Identifiable {
    var cid: String
    var owner: String
    var created: Date
    var path: String            // caminho absoluto na hora de gravar
    var relative: String?       // dentro de Documents (iPhone): o caminho absoluto muda a cada instalação do app
    var bookmark: Data?         // SSD: marcador pra reabrir o arquivo depois
    var onSSD: Bool
    var flavor: String
    var format: String
    var state: String           // gravando | pronto | subindo | na-nuvem | no-pc | falhou
    var bytes: Int64 = 0
    var sent: Int64 = 0
    var take: String?
    var sha256: String?
    var note: String?
    var id: String { cid }
  }
  private(set) var items: [Item] = []          // só com lock (fila de envio)
  @Published private(set) var shown: [Item] = []   // cópia pra tela (main)
  @Published private(set) var line = ""
  var cookieProvider: (() async -> String?)?
  /// gravando agora: o mestre espera (a banda é do proxy ao vivo)
  var paused = false { didSet { if !paused { kick() } } }
  static let origin = URL(string: "https://cowboy-editor.ybguyl.easypanel.host")!
  static let chunk = 8 * 1024 * 1024
  private let lock = NSLock()
  private var running = false
  private var wifi = false
  private let monitor = NWPathMonitor()
  private let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CowboyMasters")
  static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("ProRes", isDirectory: true)
  private lazy var http: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.httpShouldSetCookies = false; c.timeoutIntervalForRequest = 120
    c.allowsCellularAccess = false; c.allowsExpensiveNetworkAccess = false   // mestre de GB só no Wi-Fi
    return URLSession(configuration: c, delegate: CowboyNoRedirect(), delegateQueue: nil)
  }()

  init() {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    monitor.pathUpdateHandler = { [weak self] path in
      guard let self else { return }
      let ok = path.status == .satisfied && path.usesInterfaceType(.wifi) && !path.isExpensive
      self.lock.lock(); let changed = ok != self.wifi; self.wifi = ok; self.lock.unlock()
      if changed && ok { self.kick() }
      if changed { self.publishLine() }
    }
    monitor.start(queue: DispatchQueue(label: "cowboy.prores.net"))
    load()
  }

  // ---- arquivo do mestre
  /// destino do próximo mestre: SSD (se ligado) ou Documents/ProRes no iPhone
  func newFile(cid: String) -> (URL, Bool)? {
    if let url = ExternalSSD.shared.nextURL() { return (url, true) }
    try? FileManager.default.createDirectory(at: Self.documents, withIntermediateDirectories: true)
    let f = DateFormatter(); f.locale = Locale(identifier: "pt_BR"); f.timeZone = TimeZone(identifier: "America/Sao_Paulo"); f.dateFormat = "yyyy-MM-dd_HH'h'mm'm'ss"
    return (Self.documents.appendingPathComponent("Cowboy_\(f.string(from: Date()))_\(cid.suffix(6)).mov"), false)
  }
  func begin(cid: String, owner: String, url: URL, onSSD: Bool, flavor: ProResFlavor, format: String) {
    var it = Item(cid: cid, owner: owner, created: Date(), path: url.path, relative: nil, bookmark: nil, onSSD: onSSD, flavor: flavor.label, format: format, state: "gravando")
    if !onSSD { it.relative = url.lastPathComponent }
    save(it)
  }
  /// gravador fechou: marca pronto (ou falhou — o arquivo fica do mesmo jeito, fragmentado ele ainda toca até o fim salvo)
  func finished(cid: String, ok: Bool, note: String?) {
    update(cid) { it in
      if let url = self.url(of: it) {
        it.bytes = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        if it.onSSD { it.bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) }
      }
      it.state = ok ? "pronto" : (it.bytes > 0 ? "pronto" : "falhou")
      if it.take == nil { it.take = CloudStream.shared.takeID(it.cid) }
      it.note = ok ? nil : (note ?? "o gravador ProRes terminou com erro — o que foi salvo continua no aparelho")
    }
    kick()
  }
  /// a VPS deu o número da tomada do proxy (CloudStream): o mestre vai anexado a ela
  func linkTake(cid: String, take: String) {
    guard FileManager.default.fileExists(atPath: file(cid).path) else { return }
    update(cid) { $0.take = take }
    kick()
  }
  func url(of it: Item) -> URL? {
    if let r = it.relative { return Self.documents.appendingPathComponent(r) }
    if let b = it.bookmark {
      var stale = false
      if let u = try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) { _ = u.startAccessingSecurityScopedResource(); return u }
    }
    let u = URL(fileURLWithPath: it.path)
    return FileManager.default.fileExists(atPath: u.path) ? u : (it.state == "gravando" ? u : nil)
  }
  /// Apagar do aparelho: SÓ por ação manual do operador (confirmada na tela)
  func discard(_ cid: String) {
    lock.lock(); let it = items.first { $0.cid == cid }; lock.unlock()
    guard let it, it.state != "gravando", it.state != "subindo" else { return }
    if let u = url(of: it) { try? FileManager.default.removeItem(at: u) }
    try? FileManager.default.removeItem(at: file(cid))
    Diag.step("prores-apagado-manual", ["cid": cid, "estado": it.state, "gb": Double(it.bytes) / 1e9])
    load()
  }

  // ---- envio (Wi-Fi)
  func kick() {
    lock.lock()
    let go = !running && wifi && !paused && items.contains { $0.take != nil && ["pronto", "subindo"].contains($0.state) }
    if go { running = true }
    lock.unlock()
    publishLine()
    guard go else { return }
    Task.detached(priority: .utility) { [weak self] in await self?.run() }
  }
  private func run() async {
    defer { lock.lock(); running = false; lock.unlock(); publishLine() }
    while true {
      lock.lock(); let ok = wifi && !paused; let next = items.first { $0.take != nil && ["pronto", "subindo"].contains($0.state) }; lock.unlock()
      guard ok, let it = next else { return }
      guard let cookie = await cookieProvider?(), !cookie.isEmpty else { setLine("Mestre ProRes espera o login na conta Cowboy"); return }
      do { try await upload(it, cookie: cookie) }
      catch let e as Stop { setLine(e.text); if e.wait > 0 { try? await Task.sleep(nanoseconds: UInt64(e.wait) * 1_000_000_000) } else { return } }
      catch { setLine("Mestre ProRes: rede caiu (\(error.localizedDescription)) — continua sozinho no Wi-Fi"); try? await Task.sleep(nanoseconds: 15_000_000_000) }
    }
  }
  struct Stop: Error { let text: String; let wait: Int }
  private func upload(_ it0: Item, cookie: String) async throws {
    guard let take = it0.take else { return }
    guard let url = url(of: it0), let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).flatMap({ $0 }), size > 0 else {
      update(it0.cid) { $0.note = $0.onSSD ? "Ligue o SSD pra subir este mestre" : "Arquivo não encontrado no iPhone" }
      throw Stop(text: it0.onSSD ? "Mestre ProRes no SSD: ligue o SSD no USB-C pra subir" : "Mestre ProRes não encontrado", wait: 0)
    }
    let count = (size + Self.chunk - 1) / Self.chunk
    let q = take.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? take
    let (sc, sj) = try await call("/api/rec/master-status?take=\(q)", cookie: cookie)
    if sc == 404 || sc == 410 { update(it0.cid) { $0.state = "falhou"; $0.note = "a tomada do proxy não existe mais na VPS — o mestre fica no aparelho" }; return }
    guard (200..<300).contains(sc) else { throw Stop(text: "Mestre ProRes: VPS respondeu \(sc)", wait: 60) }
    if let st = sj["state"] as? String, st == "pronto" || st == "arquivado" {
      update(it0.cid) { $0.state = st == "arquivado" ? "no-pc" : "na-nuvem"; $0.sent = Int64(size); $0.sha256 = sj["sha256"] as? String }
      return
    }
    var next = sj["next"] as? Int ?? 0
    guard next >= 0, next <= count else { throw Stop(text: "Recibo do mestre inválido", wait: 60) }
    update(it0.cid) { $0.state = "subindo"; $0.bytes = Int64(size) }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    while next < count {
      lock.lock(); let stop = paused || !wifi; lock.unlock()
      if stop { throw Stop(text: paused ? "Mestre ProRes pausado enquanto grava" : "Mestre ProRes espera o Wi-Fi", wait: 0) }
      try handle.seek(toOffset: UInt64(next) * UInt64(Self.chunk))
      guard let data = try handle.read(upToCount: Self.chunk), !data.isEmpty else { throw Stop(text: "Não consegui ler o mestre ProRes", wait: 30) }
      let (code, j) = try await call("/api/rec/master?take=\(q)&seq=\(next)&size=\(size)&chunks=\(count)", method: "PUT", data: data, cookie: cookie)
      switch code {
      case 200..<300:
        guard let ack = j["next"] as? Int, ack == next + 1 else { throw Stop(text: "VPS não confirmou o trecho \(next) do mestre", wait: 10) }
        next = ack
        let sent = Int64(min(size, next * Self.chunk))
        update(it0.cid) { $0.sent = sent }
        setLine(String(format: "Subindo mestre ProRes: %.1f de %.1f GB (Wi-Fi)", Double(sent) / 1e9, Double(size) / 1e9))
      case 409:
        if let n = j["next"] as? Int, n >= 0, n <= count { next = n } else { throw Stop(text: "Mestre fora de ordem", wait: 10) }
      case 507:
        throw Stop(text: "VPS sem espaço pro mestre ProRes (\(String(format: "%.1f", Double(size) / 1e9)) GB) — espera o PC arquivar e tenta de novo", wait: 300)
      case 401: throw Stop(text: "Login venceu — entre de novo; o mestre espera no aparelho", wait: 0)
      default: throw Stop(text: "Mestre ProRes: VPS respondeu \(code)", wait: 30)
      }
    }
    setLine("Conferindo o mestre ProRes (sha256)…")
    let digest = try Self.sha256(url)
    let (dc, dj) = try await call("/api/rec/master-done", method: "POST", json: ["take": take, "bytes": size, "chunks": count, "sha256": digest, "flavor": it0.flavor, "format": it0.format], cookie: cookie, timeout: 900)
    guard (200..<300).contains(dc), dj["ok"] as? Bool == true else {
      if dc == 422 { update(it0.cid) { $0.sent = 0; $0.state = "pronto"; $0.note = "a VPS recebeu diferente (\(dj["error"] as? String ?? "?")) — reenviando do começo" } }
      throw Stop(text: "VPS não confirmou o mestre: \(dj["error"] as? String ?? "HTTP \(dc)")", wait: 30)
    }
    update(it0.cid) { $0.state = "na-nuvem"; $0.sha256 = digest; $0.note = nil }
    Diag.step("prores-na-nuvem", ["cid": it0.cid, "take": take, "gb": Double(size) / 1e9, "sha": String(digest.prefix(12))])
    setLine("Mestre ProRes na nuvem (sha256 conferido) — o PC puxa pro F:\\CowboyRec")
  }
  /// estado no servidor dos que já subiram (na-nuvem → no-pc depois que o PC arquivou)
  func refreshRemote() {
    Task.detached(priority: .utility) { [weak self] in
      guard let self, let cookie = await self.cookieProvider?(), !cookie.isEmpty else { return }
      self.lock.lock(); let list = self.items.filter { $0.state == "na-nuvem" && $0.take != nil }; self.lock.unlock()
      for it in list {
        let q = it.take!.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? it.take!
        if case let (c, j)? = try? await self.call("/api/rec/master-status?take=\(q)", cookie: cookie), (200..<300).contains(c), j["state"] as? String == "arquivado" {
          self.update(it.cid) { $0.state = "no-pc" }
        }
      }
    }
  }
  static func sha256(_ url: URL) throws -> String {
    let h = try FileHandle(forReadingFrom: url); defer { try? h.close() }
    var hasher = SHA256()
    while let d = try h.read(upToCount: 8 * 1024 * 1024), !d.isEmpty { hasher.update(data: d) }
    return hasher.finalize().map { String(format: "%02x", $0) }.joined()
  }

  // ---- persistência
  private func file(_ cid: String) -> URL { dir.appendingPathComponent(cid + ".json") }
  private func save(_ it: Item) {
    if let d = try? JSONEncoder().encode(it) { try? d.write(to: file(it.cid), options: .atomic) }
    load()
  }
  private func update(_ cid: String, _ fn: (inout Item) -> Void) {
    guard let d = try? Data(contentsOf: file(cid)), var it = try? JSONDecoder().decode(Item.self, from: d) else { return }
    fn(&it); save(it)
  }
  func load() {
    let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var list = files.filter { $0.pathExtension == "json" }.compactMap { (try? Data(contentsOf: $0)).flatMap { try? JSONDecoder().decode(Item.self, from: $0) } }
    list.sort { $0.created > $1.created }
    lock.lock(); items = list; lock.unlock()
    DispatchQueue.main.async { self.shown = list }
  }
  /// app reaberto depois de morrer gravando: o mestre fragmentado continua válido até o último pedaço salvo
  func recoverInterrupted() {
    lock.lock(); let stuck = items.filter { $0.state == "gravando" }; lock.unlock()
    for it in stuck { finished(cid: it.cid, ok: false, note: "o app fechou gravando — o mestre ficou até o último trecho salvo") }
  }
  private func setLine(_ s: String) { DispatchQueue.main.async { self.line = s } }
  private func publishLine() {
    lock.lock(); let w = wifi, list = items, p = paused; lock.unlock()
    let pend = list.filter { ["pronto", "subindo"].contains($0.state) }
    let waiting = pend.filter { $0.take == nil }.count
    let s: String
    if pend.isEmpty { s = list.isEmpty ? "" : "Nenhum mestre ProRes pendente" }
    else if p { s = "\(pend.count) mestre(s) ProRes esperam a gravação acabar" }
    else if !w { s = "\(pend.count) mestre(s) ProRes esperam o Wi-Fi (não sobem no 4G)" }
    else if waiting == pend.count { s = "\(pend.count) mestre(s) ProRes esperam a tomada do proxy chegar na VPS" }
    else { s = line.isEmpty ? "Subindo mestre ProRes pelo Wi-Fi" : line }
    setLine(s)
  }
  private func call(_ path: String, method: String = "GET", json: [String: Any]? = nil, data: Data? = nil, cookie: String, timeout: TimeInterval = 120) async throws -> (Int, [String: Any]) {
    var r = URLRequest(url: URL(string: path, relativeTo: Self.origin)!.absoluteURL)
    r.httpMethod = method; r.timeoutInterval = timeout
    r.setValue(cookie, forHTTPHeaderField: "Cookie")
    r.setValue(json == nil ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
    r.httpBody = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? data
    let (body, response) = try await http.data(for: r)
    guard let h = response as? HTTPURLResponse else { throw Stop(text: "sem resposta", wait: 15) }
    if (300..<400).contains(h.statusCode) { return (401, [:]) }
    return (h.statusCode, ((try? JSONSerialization.jsonObject(with: body)) as? [String: Any]) ?? [:])
  }
}

/// Ajustes › Gravar em: HEVC (nuvem ao vivo) × ProRes (mestre no aparelho + proxy) — com destino, teto e mestres guardados
struct ProResSettingsSection: View {
  @ObservedObject var camera: NativeCamera
  @ObservedObject var ssd = ExternalSSD.shared
  @ObservedObject var masters = ProResMasters.shared
  let disabled: Bool
  @State private var confirm: ProResMasters.Item?
  private func gb(_ b: Int64) -> String { String(format: "%.1f GB", Double(b) / 1e9) }
  private var internalFree: Int64 { Int64((try? URL(fileURLWithPath: NSHomeDirectory()).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0) }
  var body: some View {
    Section("Gravar em") {
      Picker("Codec", selection: Binding(get: { camera.proresOn }, set: { camera.setProRes($0) })) {
        Text("HEVC Log").tag(false); Text("ProRes Log").tag(true)
      }.pickerStyle(.segmented).disabled(disabled || (camera.proresFlavors.isEmpty && !camera.proresOn))
      if camera.proresFlavors.isEmpty && !camera.proresOn { Text("Este iPhone/formato não oferece ProRes ao gravador.").font(.caption2) }
      if camera.proresOn {
        Picker("ProRes", selection: Binding(get: { camera.proresFlavor }, set: { camera.setProResFlavor($0) })) {
          ForEach(ProResFlavor.allCases.filter { camera.proresFlavors.isEmpty || camera.proresFlavors.contains($0.rawValue) }, id: \.rawValue) { f in Text(f.label).tag(f.rawValue) }
        }.pickerStyle(.segmented).disabled(disabled)
        let flavor = ProResFlavor(rawValue: camera.proresFlavor) ?? .hq
        let p = camera.profiles.first { $0.id == camera.profileID } ?? .main
        let rate = ProResPolicy.gbPerMinute(flavor, p)
        if let s = ssd.info {
          Text("Destino: SSD \(s.name) · \(gb(s.freeBytes)) livres (~\(Int(Double(s.freeBytes) / 1e9 / max(rate, 0.1))) min)").font(.caption)
          if s.notRecommended { Text("O iOS marcou este SSD como lento pra gravar — pode perder quadros.").font(.caption2).foregroundStyle(.orange) }
        } else {
          Text("Destino: iPhone · \(gb(internalFree)) livres (~\(Int(Double(internalFree) / 1e9 / max(rate, 0.1))) min)").font(.caption)
          Text(ssd.authorized || !ssd.supported ? "No iPhone o ProRes vai até 4K30. Pra 4K60, ligue um SSD no USB-C (exFAT ou APFS)." : "Permita o acesso a discos externos (aparece ao ligar o SSD) pra gravar 4K60 nele.").font(.caption2)
        }
        if camera.proresCapped { Text("Escolhido \(camera.proresWanted) → gravando \(camera.formatLabel) (sem SSD)").font(.caption.bold()).foregroundStyle(.orange) }
        Text(String(format: "ProRes %@ em %@ ≈ %.1f GB por minuto. Junto sobe ao vivo um proxy 1080p HEVC Log (galeria, aprovação, montagem). O mestre sobe depois SÓ NO WI-FI, com recibo, e o PC guarda no F:\CowboyRec. Do aparelho, só você apaga.", flavor.label, p.label, rate)).font(.caption2)
        if camera.bake709 { Text("No ProRes o arquivo fica em Log puro (o \"Rec.709 no iPhone\" vale só pro HEVC); a tela continua com Log→709 + look.").font(.caption2).foregroundStyle(.secondary) }
      }
      if !masters.shown.isEmpty {
        Text("Mestres ProRes").font(.caption.bold())
        if !masters.line.isEmpty { Text(masters.line).font(.caption2) }
        ForEach(masters.shown) { it in
          VStack(alignment: .leading, spacing: 3) {
            Text("\(it.created.formatted(date: .abbreviated, time: .shortened)) · \(it.flavor) · \(it.format) · \(gb(it.bytes))\(it.onSSD ? " · SSD" : "")").font(.caption)
            Text(Self.label(it)).font(.caption2).foregroundStyle(it.state == "no-pc" || it.state == "na-nuvem" ? .green : it.state == "falhou" ? .red : .secondary)
            if let n = it.note { Text(n).font(.caption2).foregroundStyle(.orange) }
            if it.state != "gravando" && it.state != "subindo" {
              Button(it.state == "no-pc" ? "Apagar do aparelho (já está no PC)" : "Apagar do aparelho", role: .destructive) { confirm = it }.buttonStyle(.bordered).font(.caption)
            }
          }
        }
        Button("Retomar envio dos mestres") { ProResMasters.shared.kick(); ProResMasters.shared.refreshRemote() }
      }
    }
    .onAppear { ssd.refresh(); ProResMasters.shared.refreshRemote() }
    .alert("Apagar o mestre ProRes do aparelho?", isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } }), presenting: confirm) { it in
      Button("Apagar", role: .destructive) { ProResMasters.shared.discard(it.cid) }
      Button("Cancelar", role: .cancel) {}
    } message: { it in
      Text(it.state == "no-pc" ? "Ele já está no PC (sha256 conferido). Libera \(gb(it.bytes))." : it.state == "na-nuvem" ? "Ele está na VPS, mas o PC ainda não arquivou. Libera \(gb(it.bytes))." : "ATENÇÃO: este mestre ainda NÃO subiu. Apagar perde o ProRes (o proxy continua na nuvem).")
    }
  }
  static func label(_ it: ProResMasters.Item) -> String {
    switch it.state {
    case "gravando": return "Gravando…"
    case "pronto": return it.take == nil ? "No aparelho — espera a tomada do proxy chegar na VPS" : "No aparelho — sobe no Wi-Fi"
    case "subindo": return String(format: "Subindo: %.0f%%", it.bytes > 0 ? Double(it.sent) / Double(it.bytes) * 100 : 0)
    case "na-nuvem": return "Na VPS (sha256 conferido) — o PC puxa pro F:\CowboyRec"
    case "no-pc": return "No PC (F:\CowboyRec) ✓"
    default: return "Falhou — o arquivo fica no aparelho"
    }
  }
}
