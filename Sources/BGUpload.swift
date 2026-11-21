import Foundation
import UIKit

// ENVIO EM 2º PLANO (0.13.2, 18/11): até a 0.13.1 a fila só andava com o app aberto na tela — bloqueou o iPhone ou trocou de
// app, parava (medido: 21 pedaços em 7 min com o app indo e voltando; aberto, 18 pedaços em 32 s). Agora, ao sair do app,
// cada pedaço que está no disco vira uma tarefa de upload do sistema (URLSession em 2º plano): o iOS sobe sozinho, com o
// iPhone bloqueado e até com o app fechado. O servidor (rec.js 0.13.2) aceita pedaço fora de ordem e emenda na vez.
// O pedaço só sai do iPhone com recibo (held = guardado no servidor, ou next acima dele).
final class BGUpload: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  static let shared = BGUpload()
  static let identifier = "com.cowboy.rec.envio-2o-plano"
  private let lock = NSLock()
  private var bodies: [Int: Data] = [:]
  var finishEvents: (() -> Void)?

  lazy var session: URLSession = {
    let c = URLSessionConfiguration.background(withIdentifier: Self.identifier)
    c.isDiscretionary = false
    c.sessionSendsLaunchEvents = true
    c.allowsCellularAccess = true; c.allowsExpensiveNetworkAccess = true; c.allowsConstrainedNetworkAccess = true
    c.httpShouldSetCookies = false
    c.timeoutIntervalForResource = 7 * 24 * 3600
    c.httpMaximumConnectionsPerHost = 4
    return URLSession(configuration: c, delegate: self, delegateQueue: nil)
  }()

  func wake() { _ = session }

  /// sobe um pedaço do disco: descrição "cid|seq" pra saber de quem é quando o iOS devolver o resultado
  func upload(file: URL, take: String, cid: String, seq: Int, durationMs: Int, cookie: String) {
    var r = URLRequest(url: URL(string: "/api/rec/chunk?take=\(take)&seq=\(seq)&dur=\(durationMs)", relativeTo: CloudStream.origin)!.absoluteURL)
    r.httpMethod = "PUT"
    r.setValue(cookie, forHTTPHeaderField: "Cookie")
    r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
    let task = session.uploadTask(with: r, fromFile: file)
    task.taskDescription = "\(cid)|\(seq)"
    task.priority = URLSessionTask.highPriority   // gravação de sempre (galeria) passa na frente do mestre ProRes
    task.resume()
  }
  /// 0.13.4: pedido pronto (mestre ProRes: PC de casa ou VPS); descrição começa com "prores|"
  func upload(request r: URLRequest, file: URL, desc: String, low: Bool) {
    let task = session.uploadTask(with: r, fromFile: file)
    task.taskDescription = desc
    task.priority = low ? URLSessionTask.lowPriority : URLSessionTask.defaultPriority
    task.resume()
  }

  func pending(_ done: @escaping @Sendable (Set<String>) -> Void) {
    session.getAllTasks { tasks in done(Set(tasks.filter { $0.state == .running || $0.state == .suspended }.compactMap { $0.taskDescription })) }
  }

  func cancelAll(_ done: @escaping @Sendable (Int) -> Void) {
    session.getAllTasks { tasks in tasks.forEach { $0.cancel() }; done(tasks.count) }
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    lock.lock(); bodies[dataTask.taskIdentifier, default: Data()].append(data); lock.unlock()
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    lock.lock(); let body = bodies.removeValue(forKey: task.taskIdentifier); lock.unlock()
    guard let desc = task.taskDescription else { return }
    let code = (task.response as? HTTPURLResponse)?.statusCode ?? 0
    let json = body.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] } ?? [:]
    if desc.hasPrefix("prores|") { ProResUploader.shared.bgDone(desc: desc, code: error == nil ? code : 0, json: json); return }
    let parts = desc.split(separator: "|")
    guard parts.count == 2, let seq = Int(parts[1]) else { return }
    CloudStream.shared.bgDone(cid: String(parts[0]), seq: seq, code: error == nil ? code : 0, json: json)
  }

  func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
    DispatchQueue.main.async { self.finishEvents?(); self.finishEvents = nil }
  }
}

final class CowboyAppDelegate: NSObject, UIApplicationDelegate {
  func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    BGUpload.shared.wake()   // recria a sessão de 2º plano: resultados que chegaram com o app fechado são entregues aqui
    return true
  }
  func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
    guard identifier == BGUpload.identifier else { completionHandler(); return }
    BGUpload.shared.finishEvents = completionHandler
    BGUpload.shared.wake()
  }
}
