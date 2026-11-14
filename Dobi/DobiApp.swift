import SwiftUI
import WebKit
import Network

@main struct DobiApp: App {
    var body: some Scene {
        WindowGroup { ControllerView().preferredColorScheme(.dark) }
    }
}

struct ControllerView: UIViewRepresentable {
    func makeCoordinator() -> Bridge { Bridge() }
    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.add(context.coordinator, name: "dobi")
        let web = WKWebView(frame: .zero, configuration: configuration)
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.navigationDelegate = context.coordinator
        web.scrollView.contentInsetAdjustmentBehavior = .never
        context.coordinator.web = web
        if let url = Bundle.main.url(forResource: "index", withExtension: "html", subdirectory: "Web") {
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        }
        return web
    }
    func updateUIView(_ view: WKWebView, context: Context) {}
}

final class Bridge: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
    weak var web: WKWebView?
    private var waiting: [([String: Any], Int)] = []
    private var request: LampRequest?
    private let allowed: Set<String> = ["get_prop", "set_power", "set_bright", "set_ct_abx", "set_hsv", "set_rgb", "start_cf", "stop_cf", "cron_add", "cron_del", "set_default"]
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let id = body["id"] as? Int else { return }
        switch body["kind"] as? String {
        case "load":
            let saved = UserDefaults.standard.data(forKey: "DobiControllerSettings")
            let value = saved.flatMap { try? JSONSerialization.jsonObject(with: $0) }
            reply(id, value: value ?? ["ip": UserDefaults.standard.string(forKey: "lampIP") ?? "", "name": "Dobi", "room": "Bedroom", "favorites": [], "schedules": []])
        case "save":
            guard let value = body["value"], let data = try? JSONSerialization.data(withJSONObject: value) else { reply(id, error: "Invalid settings"); return }
            UserDefaults.standard.set(data, forKey: "DobiControllerSettings")
            reply(id, value: true)
        case "command":
            guard let method = body["method"] as? String, allowed.contains(method),
                  let ip = body["ip"] as? String, Self.validIP(ip), body["params"] is [Any] else {
                reply(id, error: "Enter a local IPv4 address in Connection settings."); return
            }
            waiting.append((body, id)); next()
        default: reply(id, error: "Unknown request")
        }
    }
    static func validIP(_ ip: String) -> Bool {
        let parts = ip.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let values = parts.compactMap { Int($0) }
        guard values.count == 4, values.allSatisfy({ (0...255).contains($0) }) else { return false }
        return values[0] == 10 || (values[0] == 192 && values[1] == 168) || (values[0] == 172 && (16...31).contains(values[1]))
    }
    private func next() {
        guard request == nil, !waiting.isEmpty else { return }
        let (body, id) = waiting.removeFirst()
        let current = LampRequest(ip: body["ip"] as! String, method: body["method"] as! String, params: body["params"] as! [Any]) { [weak self] result in
            guard let self = self else { return }
            self.request = nil
            switch result {
            case .success(let value): self.reply(id, value: value)
            case .failure(let error): self.reply(id, error: error.localizedDescription)
            }
            self.next()
        }
        request = current
        current.start()
    }
    private func reply(_ id: Int, value: Any = NSNull(), error: String? = nil) {
        let envelope: [String: Any] = ["id": id, "value": value, "error": error as Any? ?? NSNull()]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope), let json = String(data: data, encoding: .utf8) else { return }
        web?.evaluateJavaScript("window.dobiReply(\(json))", completionHandler: nil)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(navigationAction.request.url?.isFileURL == true ? .allow : .cancel)
    }
}

// A request buffers TCP fragments and ignores unsolicited property notifications.
final class LampRequest {
    private let connection: NWConnection
    private let method: String
    private let params: [Any]
    private var buffer = Data()
    private var finished = false
    private var timeout: DispatchWorkItem?
    private let completion: (Result<Any, Error>) -> Void
    init(ip: String, method: String, params: [Any], completion: @escaping (Result<Any, Error>) -> Void) {
        connection = NWConnection(host: NWEndpoint.Host(ip), port: 55443, using: .tcp)
        self.method = method; self.params = params; self.completion = completion
    }
    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self = self, !self.finished else { return }
            switch state {
            case .ready:
                do {
                    var data = try JSONSerialization.data(withJSONObject: ["id": 1, "method": self.method, "params": self.params])
                    data.append(contentsOf: [13, 10])
                    self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                        guard let self = self else { return }
                        if let error = error { self.finish(.failure(error)) } else { self.receive() }
                    })
                } catch { self.finish(.failure(error)) }
            case .failed(let error): self.finish(.failure(error))
            default: break
            }
        }
        let timer = DispatchWorkItem { [weak self] in self?.fail("Lamp did not respond. Check Wi-Fi, IP address and Local Network permission in iPhone Settings.") }
        timeout = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: timer)
        connection.start(queue: .main)
    }
    private func receive() {
        guard !finished else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, complete, error in
            guard let self = self, !self.finished else { return }
            if let data = data { self.buffer.append(data) }
            if self.buffer.count > 65536 { self.fail("Invalid lamp response"); return }
            while let end = self.buffer.firstIndex(of: 10) {
                let line = self.buffer.prefix(upTo: end)
                self.buffer.removeSubrange(...end)
                do {
                    guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any], object["id"] as? Int == 1 else { continue }
                    if let error = object["error"] { self.fail("Lamp: \(error)"); return }
                    guard let result = object["result"] else { self.fail("Missing lamp result"); return }
                    self.finish(.success(result)); return
                } catch { self.finish(.failure(error)); return }
            }
            if let error = error { self.finish(.failure(error)) }
            else if complete { self.fail("Lamp closed connection before replying") }
            else { self.receive() }
        }
    }
    private func fail(_ message: String) { finish(.failure(NSError(domain: "Dobi", code: 1, userInfo: [NSLocalizedDescriptionKey: message]))) }
    private func finish(_ result: Result<Any, Error>) {
        guard !finished else { return }
        finished = true; timeout?.cancel(); timeout = nil
        connection.stateUpdateHandler = nil; connection.cancel()
        completion(result)
    }
}
