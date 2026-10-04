import Foundation
import Observation
import SwiftUI
import WebKit

final class CowboyNoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

@MainActor @Observable final class CowboyCloud {
  static let shared = CowboyCloud()
  static let origin = URL(string: "https://cowboy-editor.ybguyl.easypanel.host")!
  var email: String?
  var status = "Entre na conta Cowboy antes de gravar"
  private var cookie = ""
  private var busy = false
  private var queueRevision = 0
  private let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("CowboyNativePending")
  struct Pending: Codable {
    var owner: String
    var cid: String
    var session: String?
    var take: String?
  }
  enum CloudError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
  }
  func checkCapacity() throws {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    let bytes = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    guard bytes < 256 * 1024 * 1024 else { throw CloudError.message("Fila local cheia. Retome os envios antes de gravar") }
  }
  func refresh() async {
    let cookies = await WKWebsiteDataStore.default().httpCookieStore.allCookies()
    cookie = cookies.filter { $0.name == "ce_sess" && $0.domain.trimmingCharacters(in: CharacterSet(charactersIn: ".")) == Self.origin.host }.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    do {
      let me = try await request("/api/me", cookie: cookie)
      guard let owner = me["email"] as? String, !owner.isEmpty else { throw CloudError.message("Faça login no Cowboy") }
      email = owner
      status = "Conta: \(owner)"
      await resume()
    } catch { email = nil; status = error.localizedDescription }
  }
  func enqueue(_ source: URL, owner: String?) throws {
    guard let owner else { throw CloudError.message("Entre na conta Cowboy antes de gravar") }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let cid = "native" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let video = directory.appendingPathComponent(cid + ".mov")
    try FileManager.default.copyItem(at: source, to: video)
    do { try save(Pending(owner: owner, cid: cid), at: directory.appendingPathComponent(cid + ".json")) }
    catch { try? FileManager.default.removeItem(at: video); throw error }
    queueRevision += 1
    status = "Vídeo salvo no iPhone; aguardando envio"
    Task { await resume() }
  }
  private func save(_ item: Pending, at url: URL) throws {
    try JSONEncoder().encode(item).write(to: url, options: .atomic)
  }
  func resume() async {
    guard !busy, let owner = email, !cookie.isEmpty else { return }
    busy = true
    defer { busy = false }
    let credential = cookie
    let revision = queueRevision
    do {
      let me = try await request("/api/me", cookie: credential)
      guard me["email"] as? String == owner else { throw CloudError.message("Conta mudou; entre novamente") }
      let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
      for metadata in files.filter({ $0.pathExtension == "json" }).sorted(by: { $0.path < $1.path }) {
        var item = try JSONDecoder().decode(Pending.self, from: Data(contentsOf: metadata))
        guard item.owner == owner else { continue }
        let video = directory.appendingPathComponent(item.cid + ".mov")
        if item.session == nil {
          let result = try await request("/api/rec/session", method: "POST", json: ["cid": item.cid, "title": "Câmera do iPhone", "device": "Cowboy Rec iOS AVFoundation", "source": ["type": "iphone", "model": "iPhone", "method": "native"]], cookie: credential)
          guard let id = result["session"] as? String else { throw CloudError.message("Resposta de sessão inválida") }
          item.session = id; try save(item, at: metadata)
        }
        if item.take == nil {
          let result = try await request("/api/rec/take", method: "POST", json: ["session": item.session!, "cid": item.cid, "label": "Câmera do iPhone", "mime": "video/quicktime", "convert": "none", "stabilization": ["enabled": false]], cookie: credential)
          guard let id = result["take"] as? String else { throw CloudError.message("Resposta de gravação inválida") }
          item.take = id; try save(item, at: metadata)
        }
        let size = try video.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        let chunkSize = 8 * 1024 * 1024
        let count = (size + chunkSize - 1) / chunkSize
        guard count > 0 else { throw CloudError.message("Arquivo de vídeo vazio") }
        let receipt = try await request("/api/rec/take-status?take=\(item.take!)", cookie: credential)
        var next = receipt["next"] as? Int ?? receipt["chunks"] as? Int ?? 0
        guard next >= 0, next <= count else { throw CloudError.message("Recibo de envio inválido") }
        let handle = try FileHandle(forReadingFrom: video)
        defer { try? handle.close() }
        while next < count {
          status = "Enviando vídeo: \(next + 1)/\(count)"
          try handle.seek(toOffset: UInt64(next * chunkSize))
          guard let data = try handle.read(upToCount: chunkSize), !data.isEmpty else { throw CloudError.message("Não foi possível ler o vídeo") }
          let result = try await request("/api/rec/chunk?take=\(item.take!)&seq=\(next)", method: "PUT", data: data, cookie: credential)
          guard let acknowledged = result["next"] as? Int, acknowledged == next + 1 else { throw CloudError.message("Servidor não confirmou o trecho") }
          next = acknowledged
        }
        let result = try await request("/api/rec/stop", method: "POST", json: ["take": item.take!, "chunks": count, "reason": "iPhone AVFoundation"], cookie: credential)
        guard result["status"] as? String == "done", result["bytes"] as? Int == size else { throw CloudError.message("Servidor não confirmou o vídeo completo") }
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.removeItem(at: video)
      }
      status = "Envios concluídos · \(owner)"
      if queueRevision != revision { Task { await resume() } }
    } catch { status = "Envio pendente: \(error.localizedDescription). Toque em Retomar." }
  }
  private func request(_ path: String, method: String = "GET", json: [String: Any]? = nil, data: Data? = nil, cookie: String) async throws -> [String: Any] {
    var request = URLRequest(url: URL(string: path, relativeTo: Self.origin)!.absoluteURL)
    request.httpMethod = method
    request.setValue(cookie, forHTTPHeaderField: "Cookie")
    request.setValue(json == nil ? "application/octet-stream" : "application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try json.map { try JSONSerialization.data(withJSONObject: $0) } ?? data
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    let session = URLSession(configuration: configuration, delegate: CowboyNoRedirect(), delegateQueue: nil)
    defer { session.invalidateAndCancel() }
    let (body, response) = try await session.data(for: request)
    guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode), http.url?.host == Self.origin.host,
      let result = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { throw CloudError.message("Falha no envio ou login expirado") }
    return result
  }
}

struct CowboyAccountView: UIViewRepresentable {
  func makeCoordinator() -> Coordinator { Coordinator() }
  func makeUIView(context: Context) -> WKWebView {
    let web = WKWebView()
    web.navigationDelegate = context.coordinator
    web.load(URLRequest(url: CowboyCloud.origin.appendingPathComponent("studio")))
    return web
  }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
  final class Coordinator: NSObject, WKNavigationDelegate {
    @MainActor func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
      let url = navigationAction.request.url
      decisionHandler(url?.scheme == "https" && url?.host == CowboyCloud.origin.host ? .allow : .cancel)
    }
  }
}
