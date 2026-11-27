import CryptoKit
import Foundation
import JavaScriptCore

enum EdgeSpeechVoice: String, CaseIterable, Identifiable {
    case xiaoxiao = "zh-CN-XiaoxiaoNeural"
    case yunxi = "zh-CN-YunxiNeural"

    var id: String { rawValue }
    var name: String { self == .xiaoxiao ? "晓晓（普通话女声）" : "云希（普通话男声）" }
}

actor EdgeSpeechSynthesizer {
    static let shared = EdgeSpeechSynthesizer()
    static let engineTag = "builtin:edge"
    static let engineName = "微软 Edge 语音（在线）"

    private static let endpoint = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1"
    private static let clientVersion = "143.0.3650.75"
    private static let clientID = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    private static let format = "audio-24khz-48kbitrate-mono-mp3"
    private let moduleURL: URL?
    private let session: URLSession
    private var ticket: (bucket: Int64, value: String)?

    init(moduleURL: URL? = Bundle.main.url(forResource: "MsEdgeTTS-SecMsGec", withExtension: "js")) {
        self.moduleURL = moduleURL
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 12
        session = URLSession(configuration: configuration)
    }

    func audio(text: String, voice: EdgeSpeechVoice, rate: Int, followsSystemRate: Bool) async throws -> Data {
        let percentage = followsSystemRate ? 0 : min(max((rate - 5) * 10, -50), 150)
        var audio = Data()
        for part in Self.parts(of: Self.escape(text)) {
            try Task.checkCancellation()
            do {
                audio.append(try await synthesize(part, voice: voice, rate: percentage))
            } catch let error as URLError where error.code == .networkConnectionLost || error.code == .timedOut {
                try Task.checkCancellation()
                audio.append(try await synthesize(part, voice: voice, rate: percentage))
            } catch Failure.emptyAudio {
                try Task.checkCancellation()
                audio.append(try await synthesize(part, voice: voice, rate: percentage))
            }
        }
        guard !audio.isEmpty else { throw Failure.emptyAudio }
        return audio
    }

    private func synthesize(_ escapedText: String, voice: EdgeSpeechVoice, rate: Int) async throws -> Data {
        let connectionID = Self.identifier()
        var components = URLComponents(string: Self.endpoint)!
        components.queryItems = [
            .init(name: "TrustedClientToken", value: Self.clientID),
            .init(name: "ConnectionId", value: connectionID),
            .init(name: "Sec-MS-GEC", value: try connectionTicket()),
            .init(name: "Sec-MS-GEC-Version", value: "2-\(Self.clientVersion)")
        ]
        guard let url = components.url else { throw Failure.connection }
        var request = URLRequest(url: url)
        request.setValue("chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold", forHTTPHeaderField: "Origin")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("no-cache", forHTTPHeaderField: "Pragma")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("muid=\(Self.identifier().uppercased());", forHTTPHeaderField: "Cookie")
        request.setValue(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0",
            forHTTPHeaderField: "User-Agent"
        )
        let socket = session.webSocketTask(with: request)
        socket.resume()
        let timeout = Task {
            try await Task.sleep(nanoseconds: 20_000_000_000)
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            timeout.cancel()
            socket.cancel(with: .normalClosure, reason: nil)
        }

        do {
            return try await withTaskCancellationHandler {
                let timestamp = Self.timestamp()
                let configuration = """
                    {"context":{"synthesis":{"audio":{"metadataoptions":{"sentenceBoundaryEnabled":"false","wordBoundaryEnabled":"false"},"outputFormat":"\(Self.format)"}}}}
                    """
                try await socket.send(.string("X-Timestamp:\(timestamp)\r\nContent-Type:application/json; charset=utf-8\r\nPath:speech.config\r\n\r\n\(configuration)\r\n"))
                let speed = rate >= 0 ? "+\(rate)%" : "\(rate)%"
                let ssml = """
                    <speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='zh-CN'><voice name='\(voice.rawValue)'><prosody pitch='+0Hz' rate='\(speed)' volume='+0%'>\(escapedText)</prosody></voice></speak>
                    """
                try await socket.send(.string("X-RequestId:\(Self.identifier())\r\nContent-Type:application/ssml+xml\r\nX-Timestamp:\(timestamp)Z\r\nPath:ssml\r\n\r\n\(ssml)"))

                var audio = Data()
                while true {
                    try Task.checkCancellation()
                    switch try await socket.receive() {
                    case .data(let message):
                        if let payload = Self.audioPayload(message) { audio.append(payload) }
                    case .string(let message):
                        let header = message.components(separatedBy: "\r\n\r\n").first ?? ""
                        if Self.path(in: header) == "turn.end" {
                            guard !audio.isEmpty else { throw Failure.emptyAudio }
                            return audio
                        }
                    @unknown default:
                        break
                    }
                }
            } onCancel: {
                socket.cancel(with: .goingAway, reason: nil)
            }
        } catch {
            try Task.checkCancellation()
            if let response = socket.response as? HTTPURLResponse, response.statusCode >= 400 {
                throw Failure.rejected(response.statusCode)
            }
            if let urlError = error as? URLError, urlError.code == .cancelled {
                throw URLError(.timedOut)
            }
            throw error
        }
    }

    private func connectionTicket() throws -> String {
        let unix = Int64(Date().timeIntervalSince1970)
        let bucket = (unix + 11_644_473_600) / 300 * 300
        if let ticket, ticket.bucket == bucket { return ticket.value }
        guard let moduleURL, let context = JSContext() else { throw Failure.connection }
        let encode: @convention(block) (String) -> NSArray = { text in
            text.utf8.map { NSNumber(value: $0) } as NSArray
        }
        let sha256: @convention(block) (JSValue) -> NSArray = { input in
            let bytes = (input.toArray() as? [NSNumber] ?? []).map(\.uint8Value)
            return SHA256.hash(data: bytes).map { NSNumber(value: $0) } as NSArray
        }
        context.setObject(encode, forKeyedSubscript: "encodeUTF8" as NSString)
        context.setObject(sha256, forKeyedSubscript: "digestSHA256" as NSString)
        context.setObject("\(bucket * 10_000_000)\(Self.clientID)", forKeyedSubscript: "ticketInput" as NSString)
        // JsCore supplies the language runtime while CryptoKit supplies the Web Crypto primitive used by MsEdgeTTS.
        context.evaluateScript("""
            var exports = {};
            class TextEncoder { encode(text) { return Uint8Array.from(encodeUTF8(text)); } }
            const crypto = { subtle: { digest: (_, input) => Uint8Array.from(digestSHA256(Array.from(input))).buffer } };
            """)
        context.evaluateScript(try String(contentsOf: moduleURL, encoding: .utf8), withSourceURL: moduleURL)
        context.evaluateScript("var ticketValue; exports.hashSecMsGecV2(ticketInput).then(value => { ticketValue = value; });")
        guard let result = context.objectForKeyedSubscript("ticketValue"), result.isString,
              let value = result.toString(), !value.isEmpty else { throw Failure.connection }
        ticket = (bucket, value)
        return value
    }

    private static func escape(_ text: String) -> String {
        let valid = text.unicodeScalars.filter { $0.value >= 0x20 || [9, 10, 13].contains($0.value) }
        return String(String.UnicodeScalarView(valid))
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func parts(of text: String) -> [String] {
        // Leave space for SSML and message headers within the service's 4 KiB request budget.
        let limit = 3_200
        let bytes = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        var parts: [String] = []
        var start = 0
        while start < bytes.count {
            var end = min(start + limit, bytes.count)
            if end < bytes.count {
                while bytes[end] & 0xC0 == 0x80 { end -= 1 }
                let slice = String(decoding: bytes[start..<end], as: UTF8.self)
                if let stop = slice.lastIndex(where: { "。！？；!?\n".contains($0) }) {
                    end = start + slice[...stop].utf8.count
                } else if let entity = slice.lastIndex(of: "&"), !slice[entity...].contains(";") {
                    end = start + slice[..<entity].utf8.count
                }
            }
            parts.append(String(decoding: bytes[start..<end], as: UTF8.self))
            start = end
        }
        return parts
    }

    private static func audioPayload(_ data: Data) -> Data.SubSequence? {
        guard data.count >= 2 else { return nil }
        let start = data.startIndex
        let headerLength = Int(data[start]) * 256 + Int(data[start + 1])
        let end = start + 2 + headerLength
        guard end <= data.endIndex else { return nil }
        let header = String(decoding: data[(start + 2)..<end], as: UTF8.self)
        return path(in: header) == "audio" ? data[end...] : nil
    }

    private static func path(in header: String) -> String? {
        header.split(whereSeparator: \.isNewline).lazy.compactMap { line -> String? in
            let fields = line.split(separator: ":", maxSplits: 1)
            guard fields.count == 2, fields[0].lowercased() == "path" else { return nil }
            return fields[1].trimmingCharacters(in: .whitespaces).lowercased()
        }.first
    }

    private static func identifier() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return formatter.string(from: Date())
    }

    private enum Failure: LocalizedError {
        case connection, emptyAudio, rejected(Int)

        var errorDescription: String? {
            switch self {
            case .connection: "无法建立微软 Edge 语音连接。"
            case .emptyAudio: "微软 Edge 未返回音频，请稍后重试。"
            case .rejected(let status): "微软 Edge 语音服务返回 HTTP \(status)。"
            }
        }
    }
}
