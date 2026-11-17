import Foundation
import Network

/// 本机 HTTP 服务：解决两件事
/// 1) 把打包进 App 的网页资源用 http:// 域名喂给 WKWebView（file:// 下 fetch 会被 CORS 拦，
///    而且 localStorage、视频全屏这些在 http 源上行为才正常）；
/// 2) 把网页版依赖的同源代理 /p?u=<源站地址> 搬到本机，用 URLSession 转发，
///    这样彻底不依赖任何外部服务器（沙箱睡不睡都无关）。
final class LocalHTTPServer {

    static let shared = LocalHTTPServer()

    private let queue = DispatchQueue(label: "com.lanjue.tv.http")
    private var listener: NWListener?
    private(set) var port: UInt16 = 0

    private init() {}

    /// 同步启动并等到监听就绪，返回端口；失败返回 0
    @discardableResult
    func start(waitSeconds: Double = 6) -> UInt16 {
        if port > 0 { return port }

        let ready = DispatchSemaphore(value: 0)
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // 只绑回环地址：外部设备连不进来
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    if let p = l.port { self.port = p.rawValue }
                    ready.signal()
                case .failed(let err):
                    NSLog("[http] listener failed: \(err)")
                    ready.signal()
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("[http] start error: \(error)")
        }

        _ = ready.wait(timeout: .now() + waitSeconds)
        NSLog("[http] listening on 127.0.0.1:\(port)")
        return port
    }

    // MARK: - 连接处理

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, accumulated: Data())
    }

    private func readRequest(_ conn: NWConnection, accumulated: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 128 * 1024) { [weak self] data, _, isComplete, error in
            guard let self = self else { conn.cancel(); return }
            var buf = accumulated
            if let d = data, !d.isEmpty { buf.append(d) }
            if let r = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: buf[buf.startIndex..<r.lowerBound], as: UTF8.self)
                self.route(head: head, conn: conn)
                return
            }
            if isComplete || error != nil || buf.count > 512 * 1024 {
                conn.cancel()
                return
            }
            self.readRequest(conn, accumulated: buf)
        }
    }

    private func route(head: String, conn: NWConnection) {
        let firstLine = head.split(separator: "\r\n").first.map(String.init) ?? ""
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { conn.cancel(); return }

        let method = String(parts[0])
        let target = String(parts[1])
        if method != "GET" && method != "HEAD" {
            send(conn, status: 405, type: "text/plain; charset=utf-8", body: Data("method not allowed".utf8))
            return
        }

        let comps = URLComponents(string: "http://127.0.0.1" + target)
        let path = comps?.path ?? "/"

        if path == "/p" {
            let raw = comps?.queryItems?.first(where: { $0.name == "u" })?.value ?? ""
            proxy(raw, conn: conn)
            return
        }
        serveStatic(path: path, conn: conn)
    }

    // MARK: - 静态资源

    private func serveStatic(path: String, conn: NWConnection) {
        var rel = path.isEmpty ? "/index.html" : path
        if rel == "/" { rel = "/index.html" }
        if rel.contains("..") {
            send(conn, status: 403, type: "text/plain; charset=utf-8", body: Data("forbidden".utf8))
            return
        }
        let full = Bundle.main.bundlePath + rel
        guard let data = FileManager.default.contents(atPath: full) else {
            send(conn, status: 404, type: "text/plain; charset=utf-8", body: Data("not found".utf8))
            return
        }
        send(conn, status: 200, type: LocalHTTPServer.mime(rel), body: data)
    }

    // MARK: - 同源代理 /p?u=

    private func proxy(_ raw: String, conn: NWConnection) {
        guard let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            send(conn, status: 400, type: "text/plain; charset=utf-8", body: Data("bad url".utf8))
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
                     forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            if let e = err {
                self.send(conn, status: 502, type: "text/plain; charset=utf-8",
                          body: Data(("proxy error: " + e.localizedDescription).utf8))
                return
            }
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? "application/octet-stream"
            self.send(conn, status: status, type: type, body: data ?? Data())
        }.resume()
    }

    // MARK: - 响应

    private func send(_ conn: NWConnection, status: Int, type: String, body: Data) {
        var head = "HTTP/1.1 \(status) \(LocalHTTPServer.reason(status))\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Access-Control-Allow-Origin: *\r\n"
        head += "Cache-Control: no-store\r\n"
        head += "Connection: close\r\n\r\n"

        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }

    static func reason(_ s: Int) -> String {
        switch s {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 502: return "Bad Gateway"
        default: return "OK"
        }
    }

    static func mime(_ p: String) -> String {
        let e = (p as NSString).pathExtension.lowercased()
        switch e {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json", "webmanifest": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "svg": return "image/svg+xml"
        case "m3u8": return "application/vnd.apple.mpegurl"
        case "ts": return "video/mp2t"
        case "mp4": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
