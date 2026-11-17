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

    /// 端口必须固定！WKWebView 的 localStorage 是按「协议+主机+端口」隔离的，
    /// 端口一变就等于换了一个网站：仓库源、快照、测速结果、最优源全部清零，
    /// 表现就是「每次重开都要重新接入 16 个仓库源、重新搜一遍、慢半天」。
    /// 所以这里先试上次用过的端口，再试固定的几个，实在被占用才退回随机端口。
    private let fixedPorts: [UInt16] = [47831, 47832, 47833, 47834, 47835]
    private static let lastPortKey = "lanjue.http.port"

    private init() {}

    /// 同步启动并等到监听就绪，返回端口；失败返回 0
    @discardableResult
    func start(waitSeconds: Double = 6) -> UInt16 {
        if port > 0 { return port }

        var order = fixedPorts
        if let last = UserDefaults.standard.object(forKey: LocalHTTPServer.lastPortKey) as? Int,
           last > 0, let p = UInt16(exactly: last) {
            order.removeAll { $0 == p }
            order.insert(p, at: 0)
        }

        for p in order {
            if listen(on: p, waitSeconds: 1.2) {
                UserDefaults.standard.set(Int(port), forKey: LocalHTTPServer.lastPortKey)
                NSLog("[http] listening on 127.0.0.1:\(port) (fixed)")
                return port
            }
        }
        // 兜底：全部被占用（极少见）才用随机端口，这一次数据不会串，但下次多半能回到固定端口
        if listen(on: 0, waitSeconds: waitSeconds) {
            NSLog("[http] listening on 127.0.0.1:\(port) (random fallback)")
            return port
        }
        NSLog("[http] start failed")
        return 0
    }

    /// 在指定端口上起监听；p = 0 表示任意端口
    private func listen(on p: UInt16, waitSeconds: Double) -> Bool {
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            // 只绑回环地址：外部设备连不进来
            let ep: NWEndpoint.Port = (p > 0 ? NWEndpoint.Port(rawValue: p) : nil) ?? .any
            params.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: ep)

            let l = try NWListener(using: params)
            l.stateUpdateHandler = { [weak self] state in
                guard let self = self else { return }
                switch state {
                case .ready:
                    ok = true
                    if let pp = l.port { self.port = pp.rawValue }
                    ready.signal()
                case .failed(let err):
                    NSLog("[http] listen \(p) failed: \(err)")
                    ready.signal()
                default:
                    break
                }
            }
            l.newConnectionHandler = { [weak self] conn in
                self?.accept(conn)
            }
            l.start(queue: queue)
            _ = ready.wait(timeout: .now() + waitSeconds)
            if ok {
                listener = l
                return true
            }
            l.cancel()
            return false
        } catch {
            NSLog("[http] start error on \(p): \(error)")
            return false
        }
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
        if path == "/h" {
            let raw = comps?.queryItems?.first(where: { $0.name == "u" })?.value ?? ""
            proxyHLS(raw, conn: conn)
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
        guard let url = LocalHTTPServer.makeURL(raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            send(conn, status: 400, type: "text/plain; charset=utf-8", body: Data("bad url".utf8))
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
        req.setValue(LocalHTTPServer.ua, forHTTPHeaderField: "User-Agent")

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

    // MARK: - HLS 通道代理 /h?u=
    /// 播放兜底通道：把 m3u8 拉回本机、把所有相对/绝对地址改写成走本机代理，
    /// 再喂给原生播放器。可以绕开：路径里的中文没编码、防盗链要 Referer、
    /// http/https 混播、以及播放器不带 UA 被 CDN 拒掉这几种常见的「播不了」。
    private func proxyHLS(_ raw: String, conn: NWConnection) {
        guard let url = LocalHTTPServer.makeURL(raw),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            send(conn, status: 400, type: "text/plain; charset=utf-8", body: Data("bad url".utf8))
            return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 15
        req.setValue(LocalHTTPServer.ua, forHTTPHeaderField: "User-Agent")
        req.setValue(LocalHTTPServer.originOf(url), forHTTPHeaderField: "Referer")

        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            guard let self = self else { return }
            if let e = err {
                self.send(conn, status: 502, type: "text/plain; charset=utf-8",
                          body: Data(("proxy error: " + e.localizedDescription).utf8))
                return
            }
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode ?? 200
            let type = http?.value(forHTTPHeaderField: "Content-Type") ?? ""
            let body = data ?? Data()

            // 不是播放列表（分片 / 密钥 / 二进制）：原样透传
            guard status == 200,
                  let text = String(data: body, encoding: .utf8),
                  text.contains("#EXTM3U") else {
                self.send(conn, status: status,
                          type: type.isEmpty ? "application/octet-stream" : type,
                          body: body)
                return
            }
            let out = LocalHTTPServer.rewritePlaylist(text, base: url)
            self.send(conn, status: 200, type: "application/vnd.apple.mpegurl",
                      body: Data(out.utf8))
        }.resume()
    }

    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// URL(string:) 遇到没编码的中文路径有时会给 nil，这里补一次百分号编码
    static func makeURL(_ s: String) -> URL? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return nil }
        if let u = URL(string: t), u.host != nil { return u }
        var cs = CharacterSet.urlFragmentAllowed
        cs.insert(charactersIn: "%:/?#[]@!$&'()*+,;=-._~")
        if let e = t.addingPercentEncoding(withAllowedCharacters: cs), let u = URL(string: e) { return u }
        return nil
    }

    static func originOf(_ u: URL) -> String {
        guard let s = u.scheme, let h = u.host else { return "" }
        return h.contains(":") ? "\(s)://[\(h)]" : "\(s)://\(h)"
    }

    static func q(_ s: String) -> String {
        var cs = CharacterSet.urlQueryAllowed
        cs.remove(charactersIn: "&=+#?")
        return s.addingPercentEncoding(withAllowedCharacters: cs) ?? s
    }

    /// 播放列表改写：每个 URI 都换成 /h?u=<绝对地址>，这样分片也会经过本机代理
    static func rewritePlaylist(_ text: String, base: URL) -> String {
        let abs = base.absoluteString
        let dirStr: String
        if let r = abs.range(of: "/", options: .backwards) {
            dirStr = String(abs[abs.startIndex..<r.lowerBound]) + "/"
        } else {
            dirStr = abs + "/"
        }
        let dirURL = URL(string: dirStr)

        func proxyLink(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { return t }
            let full = URL(string: t, relativeTo: dirURL)?.absoluteString ?? t
            return "/h?u=" + q(full)
        }

        func rewriteURIs(_ line: String) -> String {
            guard line.contains("URI=\"") else { return line }
            var out = ""
            var rest = Substring(line)
            while let r = rest.range(of: "URI=\"") {
                out += rest[rest.startIndex..<r.upperBound]
                let after = rest[r.upperBound...]
                if let end = after.firstIndex(of: "\"") {
                    out += proxyLink(String(after[after.startIndex..<end]))
                    out += "\""
                    rest = after[after.index(after: end)...]
                } else {
                    out += after
                    rest = Substring("")
                    break
                }
            }
            out += rest
            return out
        }

        var out: [String] = []
        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { out.append(""); continue }
            if line.hasPrefix("#") {
                out.append(rewriteURIs(line))
            } else {
                out.append(proxyLink(line))
            }
        }
        return out.joined(separator: "\n")
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
