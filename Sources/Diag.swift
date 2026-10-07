import Foundation
import UIKit

// Diagnóstico do aparelho -> /api/rec-diag da VPS (sem login, igual ao Rec web): o que deu errado chega no servidor,
// sem precisar de cabo nem de print. Travamento: o motivo + os últimos passos ficam num arquivo e sobem na próxima abertura.
enum Diag {
  private static let lock = NSLock()
  private static var steps: [String] = []
  private static let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  private static var crashURL: URL { dir.appendingPathComponent("last_crash.txt") }
  private static var stepsURL: URL { dir.appendingPathComponent("last_steps.txt") }
  static var version: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?") + "(" + (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?") + ")" }

  // passo importante: vai pra memória, pro disco (sobrevive ao travamento) e pra VPS
  static func step(_ name: String, _ extra: [String: Any] = [:], send: Bool = true) {
    let line = "\(Date().timeIntervalSince1970) \(name) \(extra.isEmpty ? "" : String(describing: extra))"
    lock.lock(); steps.append(line); if steps.count > 40 { steps.removeFirst(steps.count - 40) }; let all = steps.joined(separator: "\n"); lock.unlock()
    try? all.write(to: stepsURL, atomically: false, encoding: .utf8)
    if send { post(["step": "ios-" + name].merging(extra.mapValues { "\($0)" }) { a, _ in a }) }
  }
  static func post(_ body: [String: Any]) {
    var b = body; b["app"] = "cowboy-rec-ios " + version; b["ios"] = UIDevice.current.systemVersion; b["model"] = model()
    guard JSONSerialization.isValidJSONObject(b), let data = try? JSONSerialization.data(withJSONObject: b) else { return }
    var r = URLRequest(url: URL(string: "https://cowboy-editor.ybguyl.easypanel.host/api/rec-diag")!)
    r.httpMethod = "POST"; r.httpBody = data.prefix(7900); r.setValue("text/plain", forHTTPHeaderField: "Content-Type")
    URLSession.shared.dataTask(with: r).resume()
  }
  static func model() -> String {
    var info = utsname(); uname(&info)
    return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
  }
  static func install() {
    // travamento anterior: sobe o relatório
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let text = try? String(contentsOf: crashURL, encoding: .utf8) {
      post(["step": "ios-crash", "report": String(text.prefix(6500))])
      try? FileManager.default.removeItem(at: crashURL)
    }
    NSSetUncaughtExceptionHandler { e in
      Diag.writeCrash("EXCEÇÃO \(e.name.rawValue): \(e.reason ?? "")\n" + e.callStackSymbols.prefix(25).joined(separator: "\n"))
    }
    for s in [SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE] {
      signal(s) { sig in
        Diag.writeCrash("SINAL \(sig)\n" + Thread.callStackSymbols.prefix(25).joined(separator: "\n"))
        signal(sig, SIG_DFL); raise(sig)
      }
    }
  }
  static func writeCrash(_ text: String) {
    if let previous = try? String(contentsOf: crashURL, encoding: .utf8), previous.hasPrefix("EXCEÇÃO") {
      try? (previous + "\n--- depois ---\n" + text.prefix(800)).write(to: crashURL, atomically: false, encoding: .utf8); return
    }
    let steps = (try? String(contentsOf: stepsURL, encoding: .utf8)) ?? ""
    try? (text + "\n--- últimos passos ---\n" + steps).write(to: crashURL, atomically: false, encoding: .utf8)
  }
}
