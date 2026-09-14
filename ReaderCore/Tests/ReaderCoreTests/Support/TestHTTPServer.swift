import Foundation
import Network

/// 回归测试只访问本机临时端口，响应和延迟由用例控制。
final class TestHTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        let method: String
        let target: String
        let headers: [String: String]
        let body: String
    }

    struct Response: Sendable {
        var status = 200
        var headers: [String: String] = [:]
        var body = "ok"
        var delay: TimeInterval = 0
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "yuedu.test-http")
    private let handler: @Sendable (Request) -> Response

    var port: UInt16 { listener.port!.rawValue }
    var baseURL: String { "http://127.0.0.1:\(port)" }

    init(handler: @escaping @Sendable (Request) -> Response) throws {
        self.handler = handler
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
            if case .failed = state { ready.signal() }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            connection.start(queue: self.queue)
            self.receive(connection, data: Data())
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, listener.port != nil else {
            listener.cancel()
            throw URLError(.cannotConnectToHost)
        }
    }

    deinit { listener.cancel() }

    private func receive(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] chunk, _, done, error in
            guard let self, error == nil else { connection.cancel(); return }
            var data = data
            if let chunk { data.append(chunk) }
            let boundary = Data("\r\n\r\n".utf8)
            if let range = data.range(of: boundary),
               let header = String(data: data[..<range.lowerBound], encoding: .utf8) {
                let lines = header.components(separatedBy: "\r\n")
                let start = (lines.first ?? "").split(separator: " ")
                var headers: [String: String] = [:]
                for line in lines.dropFirst() {
                    let pair = line.split(separator: ":", maxSplits: 1)
                    if pair.count == 2 {
                        headers[pair[0].lowercased()] = pair[1].trimmingCharacters(in: .whitespaces)
                    }
                }
                let length = Int(headers["content-length"] ?? "0") ?? 0
                if start.count >= 2, data.count >= range.upperBound + length {
                    let request = Request(
                        method: String(start[0]), target: String(start[1]), headers: headers,
                        body: String(decoding: data[range.upperBound..<(range.upperBound + length)], as: UTF8.self)
                    )
                    let response = self.handler(request)
                    self.queue.asyncAfter(deadline: .now() + response.delay) {
                        self.send(response, connection: connection)
                    }
                    return
                }
            }
            if done { connection.cancel() }
            else { self.receive(connection, data: data) }
        }
    }

    private func send(_ response: Response, connection: NWConnection) {
        let body = Data(response.body.utf8)
        var headers = response.headers
        headers["Content-Length"] = String(body.count)
        headers["Connection"] = "close"
        if headers["Content-Type"] == nil { headers["Content-Type"] = "text/plain; charset=utf-8" }
        var bytes = Data("HTTP/1.1 \(response.status) Response\r\n".utf8)
        for (key, value) in headers { bytes.append(Data("\(key): \(value)\r\n".utf8)) }
        bytes.append(Data("\r\n".utf8))
        bytes.append(body)
        connection.send(content: bytes, completion: .contentProcessed { _ in connection.cancel() })
    }
}
