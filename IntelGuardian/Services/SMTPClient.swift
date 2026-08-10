import Foundation
import Network

enum SMTPError: LocalizedError {
    case cannotOpenConnection(String)
    case tlsHandshakeFailed(String)
    case sendFailed(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpenConnection(let detail):
            return "无法连接到 SMTP 服务器。\(detail)"
        case .tlsHandshakeFailed(let detail):
            return "TLS 加密握手失败：\(detail)。请检查网络、VPN/代理是否拦截了 SMTP 端口（465）。"
        case .sendFailed(let detail):
            return "SMTP 发送失败：\(detail)"
        }
    }
}

/// A minimal SMTP client that authenticates and sends a single email over
/// Network.framework, so it runs on both iOS and macOS. Uses implicit TLS
/// (port 465), which Gmail, QQ Mail, 163 and Outlook all support.
///
/// The whole conversation is driven as a state machine on the connection's
/// serial queue, so all mutable state stays on a single thread. Marked
/// nonisolated so it is not confined to the main actor (the project defaults
/// to MainActor isolation); all state is accessed only from its own queue.
nonisolated final class SMTPClient: @unchecked Sendable {
    private let host: String
    private let port: Int
    private let username: String
    private let password: String
    private let recipient: String

    private let queue = DispatchQueue(label: "IntelGuardian.SMTPClient")
    private var connection: NWConnection?
    private var recvBuffer = Data()
    private var completion: CheckedContinuation<Void, Error>?
    private var messageData = Data()
    private var step = 0
    private var waitingSince: Date?
    private var overallTimeoutWork: DispatchWorkItem?

    init(host: String, port: Int, username: String, password: String, recipient: String) {
        self.host = Self.normalizedHost(host)
        self.port = port
        self.username = username
        self.password = password
        self.recipient = recipient
    }

    /// Strips a scheme/path so "https://smtp.qq.com" or "smtp.qq.com/" become
    /// "smtp.qq.com". SMTP servers should be entered as bare hostnames.
    private static func normalizedHost(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let schemeRange = host.range(of: "://") {
            host = String(host[schemeRange.upperBound...])
        }
        if let slashRange = host.firstIndex(of: "/") {
            host = String(host[..<slashRange])
        }
        return host
    }

    /// Runs the full SMTP conversation and sends `messageData`. Throws on failure.
    func send(messageData: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                guard completion == nil else {
                    cont.resume(throwing: SMTPError.sendFailed("client already in use"))
                    return
                }
                completion = cont
                self.messageData = messageData
                runSession()
            }
        }
    }

    // MARK: - Connection setup (on queue)

    private func runSession() {
        let tlsOptions = NWProtocolTLS.Options()
        sec_protocol_options_set_verify_block(tlsOptions.securityProtocolOptions, { _, _, completion in
            // Disable server certificate validation so any SMTP provider works
            // without bundling its CA.
            completion(true)
        }, queue)

        let params = NWParameters(tls: tlsOptions)
        connection = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: UInt16(port))!,
            using: params
        )
        connection?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            self.queue.async {
                switch state {
                case .ready:
                    self.waitingSince = nil
                    // Start receiving; the server sends the 220 greeting which
                    // drives the state machine.
                    self.receiveLoop()
                case .failed(let error):
                    self.fail(SMTPError.cannotOpenConnection(error.localizedDescription))
                case .waiting(let error):
                    // Network.framework enters .waiting while it retries (e.g. TLS
                    // handshake rejected, transient network loss). Fail fast if it
                    // stays stuck instead of waiting for the 30s overall timeout.
                    if self.waitingSince == nil {
                        self.waitingSince = Date()
                        self.queue.asyncAfter(deadline: .now() + 8) { [weak self] in
                            guard let self, let since = self.waitingSince,
                                  Date().timeIntervalSince(since) >= 8, self.completion != nil else { return }
                            self.fail(SMTPError.tlsHandshakeFailed(error.localizedDescription))
                        }
                    }
                default:
                    break
                }
            }
        }
        connection?.start(queue: queue)

        // Overall timeout: a hung server must not block future alerts forever.
        overallTimeoutWork = DispatchWorkItem { [weak self] in
            guard let self, self.step < 10, self.completion != nil else { return }
            self.fail(SMTPError.sendFailed("timed out waiting for the server"))
        }
        queue.asyncAfter(deadline: .now() + 30, execute: overallTimeoutWork!)
    }

    // MARK: - Receive (on queue)

    /// Accumulates incoming bytes into complete SMTP reply lines. SMTP replies
    /// can be multi-line (lines prefixed `250-` continue until a line prefixed
    /// `250 ` or a different code), so we only dispatch once a full reply is in.
    private func receiveLoop() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            self.queue.async {
                if let data, !data.isEmpty {
                    self.recvBuffer.append(data)
                    self.consumeReplies()
                }
                if isComplete || error != nil {
                    self.fail(SMTPError.sendFailed("connection closed"))
                    return
                }
                self.receiveLoop()
            }
        }
    }

    /// Pulls as many complete replies as are buffered and feeds them to the
    /// state machine, one reply (possibly spanning several `250-` lines) at a time.
    private func consumeReplies() {
        while let reply = takeReply() {
            advance(reply: reply)
        }
    }

    /// Extracts one complete SMTP reply from the buffer without discarding
    /// partial data. A reply is one or more CRLF lines; continuation lines
    /// start with `NNN-`, and the reply ends at the first line whose code is
    /// followed by a space (or any non-`-` character).
    private func takeReply() -> String? {
        var searchStart = recvBuffer.startIndex
        var lines: [String] = []
        while let range = recvBuffer.range(of: Data("\r\n".utf8), in: searchStart..<recvBuffer.endIndex) {
            let lineData = recvBuffer.subdata(in: searchStart..<range.lowerBound)
            searchStart = range.upperBound
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            lines.append(line)
            let isContinuation = line.count >= 4 && line[line.index(line.startIndex, offsetBy: 3)] == "-"
            if !isContinuation {
                // Complete reply: consume it and return.
                recvBuffer.removeSubrange(recvBuffer.startIndex..<searchStart)
                return lines.joined(separator: "\n")
            }
        }
        // No complete reply yet; leave the buffer untouched for the next chunk.
        return nil
    }

    // MARK: - Protocol state machine (on queue)

    /// Consumes one server reply (or the greeting) and issues the next command.
    private func advance(reply: String) {
        do {
            // The reply's status code is the first three chars of the last line.
            guard let code = replyStatus(reply) else {
                throw SMTPError.sendFailed("malformed server reply: \(reply)")
            }
            try validate(code: code)
            switch step {
            case 0:
                sendLine("EHLO IntelGuardian")
                step = 1
            case 1:
                sendLine("AUTH LOGIN")
                step = 2
            case 2:
                sendLine(base64(username))
                step = 3
            case 3:
                sendLine(base64(password))
                step = 4
            case 4:
                sendLine("MAIL FROM:<\(username)>")
                step = 5
            case 5:
                sendLine("RCPT TO:<\(recipient)>")
                step = 6
            case 6:
                sendLine("DATA")
                step = 7
            case 7:
                sendBytes(messageData)
                step = 8
            case 8:
                sendLine("QUIT")
                step = 9
            case 9:
                succeed()
            default:
                throw SMTPError.sendFailed("unexpected state")
            }
        } catch {
            fail(error)
        }
    }

    /// Extracts the 3-digit status code from the final line of a reply.
    private func replyStatus(_ reply: String) -> String? {
        let lines = reply.components(separatedBy: "\n")
        guard let last = lines.last, last.count >= 3 else { return nil }
        let start = last.startIndex
        let end = last.index(start, offsetBy: 3)
        let code = String(last[start..<end])
        return code.allSatisfy(\.isNumber) ? code : nil
    }

    private func validate(code: String) throws {
        let expected: Set<String>
        switch step {
        case 0: expected = ["220"] // greeting
        case 1: expected = ["250"] // EHLO
        case 2, 3: expected = ["334"] // AUTH LOGIN username/password prompts
        case 4: expected = ["235"] // auth OK
        case 5: expected = ["250"] // MAIL FROM
        case 6: expected = ["250"] // RCPT TO
        case 7: expected = ["354"] // DATA ready
        case 8: expected = ["250"] // message accepted
        case 9: expected = ["221"] // QUIT
        default: expected = ["250"]
        }
        guard expected.contains(code) else {
            throw SMTPError.sendFailed("unexpected server reply code \(code), expected \(expected.sorted())")
        }
    }

    // MARK: - Send (on queue)

    /// Sends raw bytes with a completion that resolves before the next send.
    /// Uses a per-call continuation so large payloads (email body with inline
    /// chart) never interleave with the following command in the buffer.
    private func sendRaw(_ data: Data, then: (() -> Void)? = nil) {
        connection?.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.queue.async { then?() }
        })
    }

    private func sendLine(_ line: String) {
        sendRaw(Data((line + "\r\n").utf8))
    }

    private func sendBytes(_ data: Data, then: (() -> Void)? = nil) {
        sendRaw(data, then: then)
    }

    private func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    // MARK: - Completion

    private func succeed() {
        overallTimeoutWork?.cancel()
        let cont = completion
        completion = nil
        connection?.cancel()
        connection = nil
        cont?.resume()
    }

    private func fail(_ error: Error) {
        overallTimeoutWork?.cancel()
        let cont = completion
        completion = nil
        connection?.cancel()
        connection = nil
        cont?.resume(throwing: error)
    }
}
