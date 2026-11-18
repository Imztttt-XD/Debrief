import Foundation

struct AIError: LocalizedError {
    let message: String
    /// Rate limits (429), server errors (5xx) and network failures are worth retrying;
    /// a bad key or model name is not.
    var retryable = false
    var status = 0
    /// The server's Retry-After, in seconds, when it sent one.
    var retryAfter: TimeInterval?
    var errorDescription: String? { message }
    var isRateLimit: Bool { status == 429 }

    static func http(_ status: Int, _ detail: String, retryAfter: TimeInterval? = nil) -> AIError {
        AIError(message: L10n.tr("error.ai.http", [String(status), detail]),
                retryable: status == 429 || status >= 500, status: status, retryAfter: retryAfter)
    }

    /// Retry-After in seconds (the HTTP-date form is rare for APIs and ignored).
    static func retryAfter(_ response: URLResponse) -> TimeInterval? {
        (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
    }
}

/// Speaks the OpenAI-compatible chat API, which DeepSeek, Alibaba Cloud Model Studio (including
/// Qwen-ASR), OpenAI and Ollama all accept. Claude will get its own client when it's added.
struct OpenAICompatibleClient {
    let baseURL: URL
    let apiKey: String
    /// Longest silence allowed on the connection (not the total time). With streaming, a model
    /// that's still working keeps sending data, so this only fires when it has really stalled.
    var timeout: TimeInterval = 180
    /// Told the token usage of each successful request (UsageLedger). Set by AISettings.client(for:).
    var onUsage: (@Sendable (TokenUsage) -> Void)?

    /// Long generations (reasoning models writing a multi-question critique) can take many
    /// minutes in total; only the per-request idle timeout above should cut them off.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 30 * 60
        return URLSession(configuration: config)
    }()

    /// Text completion, streamed. Streaming matters here: without it the server sends nothing
    /// until the whole answer is ready, so any generation longer than the idle timeout failed
    /// with "request timed out" even though the model was still working.
    /// `messages` are (role, content) pairs; role is system/user/assistant.
    /// `maxTokens`: leave nil for real work. On reasoning models (e.g. deepseek-v4-pro) the
    /// thinking counts against it, so a cap that looks generous for the answer can be used up
    /// before the answer starts; provider defaults leave room for both.
    /// `allowTruncated`: return whatever arrived instead of throwing when the cap is hit.
    func chat(model: String, messages: [(role: String, content: String)], maxTokens: Int? = nil,
              jsonOutput: Bool = false, allowTruncated: Bool = false) async throws -> String {
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role, "content": $0.content] },
            "stream": true,
            // Ask for token usage in the last chunk (OpenAI-compatible; DeepSeek and DashScope support it).
            "stream_options": ["include_usage": true],
        ]
        if let maxTokens { body["max_tokens"] = maxTokens }
        if jsonOutput { body["response_format"] = ["type": "json_object"] }

        let (bytes, response) = try await send(body)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            var data = Data()
            for try await byte in bytes { data.append(byte); if data.count > 4096 { break } }
            let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            throw AIError.http(status, Self.errorDetail(json: json, data: data), retryAfter: AIError.retryAfter(response))
        }

        // Server-sent events: "data: {json}" lines, ending with "data: [DONE]". Lines starting
        // with ":" are keep-alive comments. Reasoning models first stream `reasoning_content`
        // (ignored here), then `content`.
        var content = ""
        var finishReason: String?
        var usage: TokenUsage?
        do {
            for try await line in bytes.lines {
                guard line.hasPrefix("data:") else { continue }
                let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                if payload == "[DONE]" { break }
                guard let json = (try? JSONSerialization.jsonObject(with: Data(payload.utf8))) as? [String: Any] else { continue }
                if let u = TokenUsage.parse(json["usage"]) { usage = u }
                if let error = json["error"] as? [String: Any] {
                    throw AIError(message: L10n.tr("error.ai.http", [String(status), (error["message"] as? String) ?? payload]))
                }
                guard let choice = (json["choices"] as? [[String: Any]])?.first else { continue }
                if let delta = choice["delta"] as? [String: Any], let piece = delta["content"] as? String {
                    content += piece
                }
                if let reason = choice["finish_reason"] as? String { finishReason = reason }
            }
        } catch let error as AIError {
            throw error
        } catch {
            throw Self.networkError(error)
        }
        if let usage { onUsage?(usage) }
        if finishReason == "length" && !allowTruncated {
            throw AIError(message: L10n.tr("error.ai.truncated"))
        }
        return content
    }

    /// Qwen-ASR (qwen3-asr-flash) through the OpenAI-compatible endpoint.
    /// Limits from Alibaba's docs: ≤ 5 minutes and ≤ 10 MB per request *after* Base64 encoding,
    /// no timestamps returned. The caller splits recordings into short WAV segments, which also
    /// gives each utterance its own start time.
    /// `context` (background text / term list, e.g. from the resume and JD) goes in a system
    /// message, which Qwen-ASR uses to bias recognition toward those terms.
    func transcribe(wav: Data, model: String, context: String? = nil) async throws -> String {
        var messages: [[String: Any]] = []
        if let context, !context.isEmpty {
            messages.append(["role": "system", "content": [["text": context]]])
        }
        messages.append(["role": "user", "content": [[
            "type": "input_audio",
            "input_audio": ["data": "data:audio/wav;base64," + wav.base64EncodedString()],
        ]]])
        // No `language`: the docs say to leave it unset for mixed-language audio (中英混说).
        let body: [String: Any] = ["model": model, "messages": messages, "stream": false,
                                   "asr_options": ["enable_itn": true]]
        return try await completionText(body)
    }

    // MARK: Transport

    private func completionText(_ body: [String: Any]) async throws -> String {
        let json = try await post("chat/completions", body: body)
        if let usage = TokenUsage.parse(json["usage"]) { onUsage?(usage) }
        guard let choices = json["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any] else {
            throw AIError(message: L10n.tr("error.ai.badResponse"))
        }
        // content is usually a string; some providers return [{type:text,text:...}].
        if let text = message["content"] as? String { return text }
        if let parts = message["content"] as? [[String: Any]] {
            return parts.compactMap { $0["text"] as? String }.joined()
        }
        return ""
    }

    private func post(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: baseURL.appendingPathComponent(path), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data, response: URLResponse
        do {
            (data, response) = try await Self.session.data(for: request)
        } catch {
            throw Self.networkError(error)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(status) else {
            throw AIError.http(status, Self.errorDetail(json: json, data: data), retryAfter: AIError.retryAfter(response))
        }
        guard let json else { throw AIError(message: L10n.tr("error.ai.badResponse")) }
        return json
    }

    private func send(_ body: [String: Any]) async throws -> (URLSession.AsyncBytes, URLResponse) {
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"), timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        do {
            return try await Self.session.bytes(for: request)
        } catch {
            throw Self.networkError(error)
        }
    }

    private static func networkError(_ error: Error) -> AIError {
        if (error as? URLError)?.code == .timedOut {
            return AIError(message: L10n.tr("error.ai.timeout"), retryable: true)
        }
        return AIError(message: L10n.tr("error.ai.network", [error.localizedDescription]), retryable: true)
    }

    /// OpenAI style {"error":{"message":…}}, DashScope native {"message":…,"code":…}, or raw text.
    private static func errorDetail(json: [String: Any]?, data: Data) -> String {
        if let error = json?["error"] as? [String: Any], let m = error["message"] as? String { return m }
        if let m = json?["message"] as? String { return m }
        return String(decoding: data.prefix(300), as: UTF8.self)
    }
}

extension AISettings {
    /// Client + model for a function, or a user-facing error saying what's missing.
    func client(for function: AIFunction) throws -> (client: OpenAICompatibleClient, model: String) {
        let assignment = assignment(for: function)
        guard let account = account(assignment.accountID) else {
            throw AIError(message: L10n.tr("ai.notConfigured"))
        }
        let model = assignment.model.trimmingCharacters(in: .whitespaces)
        guard !model.isEmpty else { throw AIError(message: L10n.tr("ai.noModel")) }
        guard let url = account.resolvedBaseURL else { throw AIError(message: L10n.tr("error.ai.invalidURL")) }
        guard let key = Keychain.get(account.id), !key.isEmpty else {
            throw AIError(message: L10n.tr("ai.noKey", [account.name]))
        }
        var client = OpenAICompatibleClient(baseURL: url, apiKey: key)
        let provider = account.name
        client.onUsage = { usage in
            Task { @MainActor in UsageLedger.shared.record(usage, function: function, provider: provider, model: model) }
        }
        return (client, model)
    }
}

/// "Test" button: makes the smallest real call for a function, so a wrong key, model name,
/// region or URL shows up here instead of in the middle of a review.
enum ConnectionCheck {
    static func run(_ function: AIFunction, settings: AISettings) async throws -> String {
        if function.isTranscription, settings.usesLocalTranscription, #available(macOS 26, *) {
            // Nothing to call: make sure the language is supported and its model is downloaded.
            let locale = try await LocalTranscriber.prepare()
            return L10n.tr("local.ready", [locale.identifier])
        }
        let (client, model) = try settings.client(for: function)
        if function.isTranscription {
            _ = try await client.transcribe(wav: testTone(), model: model)
            return L10n.tr("ai.test.ok")
        }
        // A tiny cap keeps the test cheap. A reasoning model may spend it all thinking and
        // return nothing, which still proves the key, URL and model name work.
        let reply = try await client.chat(model: model, messages: [("user", "Reply with the single word: OK")],
                                          maxTokens: 16, allowTruncated: true)
        let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? L10n.tr("ai.test.ok") : L10n.tr("ai.test.okReply", [String(trimmed.prefix(40))])
    }

    /// 1 s, 16 kHz, mono, 16-bit PCM WAV of a quiet 440 Hz tone.
    static func testTone() -> Data {
        let rate = 16_000
        var samples = Data(capacity: rate * 2)
        for i in 0..<rate {
            var s = Int16(3000 * sin(2 * Double.pi * 440 * Double(i) / Double(rate))).littleEndian
            withUnsafeBytes(of: &s) { samples.append(contentsOf: $0) }
        }
        return WAV.encode(pcm16Mono: samples, sampleRate: rate)
    }
}

enum WAV {
    /// Wraps little-endian 16-bit mono PCM in a RIFF/WAVE header.
    static func encode(pcm16Mono pcm: Data, sampleRate: Int) -> Data {
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count))
        d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 2)); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
        d.append(pcm)
        return d
    }
}
