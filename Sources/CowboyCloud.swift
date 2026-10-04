import Foundation
import Observation
import SwiftUI
import WebKit
import AVFoundation

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
    var capture: NativeCaptureMetadata?
    var hasAR: Bool? = nil
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
    guard !cookie.isEmpty else { email = nil; status = "Entre com a mesma conta usada no Rec web"; return }
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
    let capture=(try? Data(contentsOf:source.appendingPathExtension("capture"))).flatMap { try? JSONDecoder().decode(NativeCaptureMetadata.self,from:$0) }
    let hasAR=FileManager.default.fileExists(atPath:source.appendingPathExtension("ar").path)
    do {
      if hasAR { try FileManager.default.copyItem(at:source.appendingPathExtension("ar"),to:directory.appendingPathComponent(cid+".ar.json")) }
      try save(Pending(owner: owner, cid: cid,capture:capture,hasAR:hasAR), at: directory.appendingPathComponent(cid + ".json"))
    }
    catch { try? FileManager.default.removeItem(at: video);try? FileManager.default.removeItem(at:directory.appendingPathComponent(cid+".ar.json")); throw error }
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
          let result = try await request("/api/rec/take", method: "POST", json: ["session": item.session!, "cid": item.cid, "label": item.capture?.lens ?? "Câmera do iPhone", "mime": "video/quicktime", "convert": item.capture?.convertRec709 == true ? "keep" : "none", "settings": item.capture?.settings ?? [:], "stabilization": ["enabled": false]], cookie: credential)
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
        if item.hasAR == true {
          let data=try Data(contentsOf:directory.appendingPathComponent(item.cid+".ar.json"))
          let receipt=try await request("/api/rec/side?take=\(item.take!)&kind=ar",method:"PUT",data:data,cookie:credential)
          guard receipt["ok"] as? Bool == true else { throw CloudError.message("Servidor não confirmou as poses AR") }
        }
        let duration=try? await AVURLAsset(url:video).load(.duration)
        let milliseconds=duration.flatMap { $0.seconds.isFinite ? Int($0.seconds*1000) : nil } ?? 0
        let result = try await request("/api/rec/stop", method: "POST", json: ["take": item.take!, "chunks": count, "duration_ms": milliseconds, "reason": "iPhone AVFoundation"], cookie: credential)
        guard result["status"] as? String == "done", result["bytes"] as? Int == size else { throw CloudError.message("Servidor não confirmou o vídeo completo") }
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.removeItem(at: video)
        if item.hasAR == true { try? FileManager.default.removeItem(at:directory.appendingPathComponent(item.cid+".ar.json")) }
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
    guard let http = response as? HTTPURLResponse else { throw CloudError.message("Servidor sem resposta") }
    if http.statusCode == 401 || (300..<400).contains(http.statusCode) { throw CloudError.message("Entre novamente na conta Cowboy pelo app") }
    let result = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    guard (200..<300).contains(http.statusCode), http.url?.host == Self.origin.host, let result else {
      throw CloudError.message(result?["error"] as? String ?? "Servidor retornou HTTP \(http.statusCode)")
    }
    return result
  }
}

enum CowboyPortal: String, Identifiable {
  case account, rec, library
  var id: String { rawValue }
  var title: String { self == .account ? "Conta Cowboy" : self == .library ? "Biblioteca da VPS" : "Rec completo" }
}

@MainActor @Observable final class CowboyPortalControl {
  weak var web: WKWebView?
  func canReturnToCamera() async -> Bool {
    guard let web else { return true }
    // Do not unload the full Rec while it is capturing or transmitting live.
    let value = try? await web.evaluateJavaScript("document.body.classList.contains('recording') || document.body.classList.contains('live')")
    return value as? Bool != true
  }
}

struct CowboyAccountView: UIViewRepresentable {
  var destination: CowboyPortal = .account
  var control: CowboyPortalControl
  func makeCoordinator() -> Coordinator { Coordinator(destination: destination) }
  func makeUIView(context: Context) -> WKWebView {
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = []
    if destination == .library {
      // Uses the real Rec library, including its account permissions and actions.
      let script = "let attempts=0;const open=setInterval(()=>{const b=document.getElementById('libbtn');if(b){clearInterval(open);b.click();}else if(++attempts>100)clearInterval(open);},100);"
      config.userContentController.addUserScript(WKUserScript(source: script,injectionTime: .atDocumentEnd,forMainFrameOnly: true))
    }
    let web = WKWebView(frame: .zero,configuration: config)
    control.web = web
    web.navigationDelegate = context.coordinator
    web.uiDelegate = context.coordinator
    web.isOpaque = false
    web.backgroundColor = .black
    web.scrollView.contentInsetAdjustmentBehavior = .never
    web.load(URLRequest(url: CowboyCloud.origin.appendingPathComponent(destination == .account ? "login" : "rec")))
    return web
  }
  func updateUIView(_ uiView: WKWebView, context: Context) {}
  final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let destination: CowboyPortal
    private var downloads: [ObjectIdentifier: URL] = [:]
    init(destination: CowboyPortal) { self.destination=destination }
    @MainActor func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
      Task { await CowboyCloud.shared.refresh() }
      if destination == .account, webView.url?.path != "/login" {
        // Login is shared with uploads; the same account sees its VPS recordings.
        if webView.url?.path != "/rec" { webView.load(URLRequest(url: CowboyCloud.origin.appendingPathComponent("rec"))) }
      }
    }
    @MainActor func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
      let url = navigationAction.request.url
      guard url?.host == CowboyCloud.origin.host && url?.scheme == "https" || url?.scheme == "blob" else { decisionHandler(.cancel); return }
      decisionHandler(navigationAction.shouldPerformDownload ? .download : .allow)
    }
    @MainActor func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
      let attachment = (navigationResponse.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")?.lowercased().contains("attachment") == true
      decisionHandler(attachment || !navigationResponse.canShowMIMEType ? .download : .allow)
    }
    @MainActor func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate=self }
    @MainActor func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate=self }
    @MainActor func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
      let directory=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
      do {
        try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
        let file=directory.appendingPathComponent((suggestedFilename as NSString).lastPathComponent)
        downloads[ObjectIdentifier(download)]=file; completionHandler(file)
      } catch { completionHandler(nil) }
    }
    @MainActor func downloadDidFinish(_ download: WKDownload) {
      guard let file=downloads.removeValue(forKey: ObjectIdentifier(download)),
        let scene=UIApplication.shared.connectedScenes.first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
        var controller=scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
      while let presented=controller.presentedViewController { controller=presented }
      controller.present(UIActivityViewController(activityItems: [file],applicationActivities: nil),animated: true)
    }
    @MainActor func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
      downloads.removeValue(forKey: ObjectIdentifier(download))
      CowboyCloud.shared.status="Download interrompido: \(error.localizedDescription)"
    }
    @MainActor func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin, initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType, decisionHandler: @escaping (WKPermissionDecision) -> Void) {
      decisionHandler(origin.protocol == "https" && origin.host == CowboyCloud.origin.host ? .prompt : .deny)
    }
    @MainActor func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
      if navigationAction.targetFrame == nil, let url=navigationAction.request.url, url.host == CowboyCloud.origin.host { webView.load(navigationAction.request) }
      return nil
    }
  }
}
