import Foundation
import Darwin

final class HTTPServer {
    private let port: UInt16
    private let handler: MCPHandler
    private let store: EventKitStore
    private var listenFD: Int32 = -1
    private let queue = DispatchQueue(label: "com.zayden.apple-remcal-mcp.http", attributes: .concurrent)

    init(port: UInt16, handler: MCPHandler, store: EventKitStore) {
        self.port = port
        self.handler = handler
        self.store = store
    }

    func start() throws {
        listenFD = socket(AF_INET, SOCK_STREAM, 0)
        guard listenFD >= 0 else {
            throw NSError(domain: "HTTPServer", code: Int(errno), userInfo: [NSLocalizedDescriptionKey: "socket() failed"])
        }

        var yes: Int32 = 1
        setsockopt(listenFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        // Bind strictly to loopback 127.0.0.1 for local-only access
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listenFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let err = errno
            close(listenFD)
            throw NSError(domain: "HTTPServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "bind(127.0.0.1:\(port)) failed with errno \(err)"])
        }

        guard listen(listenFD, 64) == 0 else {
            let err = errno
            close(listenFD)
            throw NSError(domain: "HTTPServer", code: Int(err), userInfo: [NSLocalizedDescriptionKey: "listen() failed with errno \(err)"])
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.acceptLoop()
        }
    }

    private func acceptLoop() {
        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listenFD, $0, &clientLen)
                }
            }
            if clientFD < 0 {
                if errno == EINTR { continue }
                break
            }
            queue.async { [weak self] in
                self?.handleClient(clientFD)
            }
        }
    }

    private func handleClient(_ fd: Int32) {
        defer { close(fd) }

        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        guard let (method, path, body) = readHTTPRequest(fd) else {
            return
        }

        if path == "/health" && method == "GET" {
            let payload: [String: Any] = [
                "status": "ok",
                "permissions": store.checkPermissions()
            ]
            let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
            sendResponse(fd, status: 200, body: data)
            return
        }

        if path == "/mcp" {
            switch method {
            case "POST":
                let (status, data) = handler.handleRPC(body: body)
                sendResponse(fd, status: status, body: data)
            case "OPTIONS":
                sendResponse(fd, status: 204, body: nil)
            case "DELETE":
                sendResponse(fd, status: 204, body: nil)
            case "GET":
                sendResponse(fd, status: 405, body: Data("{\"error\":\"Method Not Allowed\"}".utf8))
            default:
                sendResponse(fd, status: 405, body: nil)
            }
            return
        }

        sendResponse(fd, status: 404, body: Data("{\"error\":\"Not Found\"}".utf8))
    }

    private func readHTTPRequest(_ fd: Int32) -> (String, String, Data)? {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let sep = Data("\r\n\r\n".utf8)
        var headerEndRange: Range<Data.Index>? = nil

        while headerEndRange == nil {
            let n = recv(fd, &chunk, chunk.count, 0)
            if n <= 0 { return nil }
            buffer.append(chunk, count: n)
            headerEndRange = buffer.range(of: sep)
            if buffer.count > 65536 && headerEndRange == nil { return nil }
        }

        guard let range = headerEndRange else { return nil }
        let headerData = buffer.subdata(in: 0..<range.lowerBound)
        guard let headerStr = String(data: headerData, encoding: .utf8) else { return nil }

        let lines = headerStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let fullPath = String(parts[1])
        let path = fullPath.split(separator: "?").first.map(String.init) ?? fullPath

        var contentLength = 0
        for line in lines.dropFirst() {
            if let colon = line.firstIndex(of: ":") {
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                if key == "content-length" {
                    let val = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    contentLength = Int(val) ?? 0
                }
            }
        }

        var body = buffer.subdata(in: range.upperBound..<buffer.count)
        while body.count < contentLength {
            let remaining = contentLength - body.count
            let toRead = min(remaining, chunk.count)
            let n = recv(fd, &chunk, toRead, 0)
            if n <= 0 { break }
            body.append(chunk, count: n)
        }
        if body.count > contentLength {
            body = body.subdata(in: 0..<contentLength)
        }

        return (method, path, body)
    }

    private func statusText(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        default: return "OK"
        }
    }

    private func sendResponse(_ fd: Int32, status: Int, body: Data?) {
        let len = body?.count ?? 0
        var header = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        if len > 0 {
            header += "Content-Type: application/json\r\n"
        }
        header += "Content-Length: \(len)\r\n"
        header += "Connection: close\r\n\r\n"

        var out = Data(header.utf8)
        if let body = body, len > 0 {
            out.append(body)
        }

        out.withUnsafeBytes { rawBuf in
            guard let base = rawBuf.baseAddress else { return }
            var totalSent = 0
            while totalSent < out.count {
                let n = send(fd, base.advanced(by: totalSent), out.count - totalSent, 0)
                if n <= 0 { break }
                totalSent += n
            }
        }
    }
}
