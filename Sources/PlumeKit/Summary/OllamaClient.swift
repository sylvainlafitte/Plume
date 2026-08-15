import Foundation

/// Minimal client for a local Ollama daemon.
///
/// Uses the **native `/api/chat`**, not the OpenAI-compatible `/v1`. `/v1` has
/// no `options` passthrough, so `num_ctx` cannot be set there and the context
/// silently falls back to the VRAM-tier default (4096 on a 16 GB Mac) — which
/// would quietly summarize only the tail of a long meeting.
///
/// Every request sends `truncate: false` and `shift: false`, so an over-long
/// prompt returns a 400 naming the token counts instead of being trimmed from
/// the front. Verified 2026-08-15 against Ollama 0.32.9.
struct OllamaClient: Sendable {
    var baseURL: URL
    var model: String

    /// Cold-starting a local model routinely takes far longer than
    /// `URLRequest`'s 60s default, and the first summary after launch always
    /// pays that cost.
    static let timeout: TimeInterval = 300

    init(
        baseURL: URL = URL(string: "http://127.0.0.1:11434")!,
        model: String = Config.summaryModel()
    ) {
        self.baseURL = baseURL
        self.model = model
    }

    // MARK: - Errors

    enum ClientError: Error, CustomStringConvertible, Equatable {
        /// The daemon isn't answering. Not necessarily broken — Ollama.app
        /// starts it lazily, so this is a normal first-run state.
        case unreachable
        case modelMissing(String)
        /// Prompt exceeded the context window. Carries the counts so the caller
        /// can decide to chunk rather than guess at a budget.
        case contextExceeded(promptTokens: Int, contextTokens: Int)
        case http(status: Int, message: String)
        case malformedResponse

        var description: String {
            switch self {
            case .unreachable:
                return "Ollama isn't running — start it, or run `ollama list` to wake it"
            case .modelMissing(let model):
                return "model \"\(model)\" is not installed — run `ollama pull \(model)`"
            case .contextExceeded(let prompt, let context):
                return "prompt is \(prompt) tokens but the context holds \(context)"
            case .http(let status, let message):
                return "Ollama returned \(status): \(message)"
            case .malformedResponse:
                return "could not parse Ollama's response"
            }
        }
    }

    // MARK: - Requests

    struct Options: Sendable {
        var numCtx: Int = Config.summaryContextTokens()
        var temperature: Double?
    }

    private func body(
        system: String?, user: String, options: Options, format: Data?, stream: Bool,
        keepAlive: String
    ) throws -> Data {
        var messages: [[String: String]] = []
        if let system, !system.isEmpty {
            messages.append(["role": "system", "content": system])
        }
        messages.append(["role": "user", "content": user])

        var payload: [String: Any] = [
            "model": model,
            "messages": messages,
            "stream": stream,
            "keep_alive": keepAlive,
            // The whole point: fail loudly instead of summarizing only the tail.
            "truncate": false,
            "shift": false,
            "options": {
                var options_: [String: Any] = ["num_ctx": options.numCtx]
                if let temperature = options.temperature {
                    options_["temperature"] = temperature
                }
                return options_
            }(),
        ]
        if let format,
            let schema = try? JSONSerialization.jsonObject(with: format)
        {
            payload["format"] = schema
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func request(path: String, body: Data?) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = Self.timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    // MARK: - Chat

    /// One-shot completion. Use for structured output and short prompts; the
    /// summary path streams instead so the user sees progress.
    func chat(
        system: String? = nil, user: String, options: Options = Options(),
        format: Data? = nil, keepAlive: String = "5m"
    ) async throws -> String {
        let payload = try body(
            system: system, user: user, options: options, format: format,
            stream: false, keepAlive: keepAlive)
        let (data, response) = try await send(request(path: "api/chat", body: payload))
        try check(response, data: data)

        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let message = json["message"] as? [String: Any],
            let content = message["content"] as? String
        else { throw ClientError.malformedResponse }
        return content
    }

    /// Streaming completion, yielding content deltas. Native `/api/chat` streams
    /// newline-delimited JSON objects, not SSE.
    func stream(
        system: String? = nil, user: String, options: Options = Options(),
        keepAlive: String = "5m"
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let payload = try body(
                        system: system, user: user, options: options, format: nil,
                        stream: true, keepAlive: keepAlive)
                    let (bytes, response) = try await URLSession.shared.bytes(
                        for: request(path: "api/chat", body: payload))
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var collected = Data()
                        for try await byte in bytes { collected.append(byte) }
                        try check(response, data: collected)
                    }
                    for try await line in bytes.lines {
                        guard !line.isEmpty,
                            let data = line.data(using: .utf8),
                            let json = try? JSONSerialization.jsonObject(with: data)
                                as? [String: Any]
                        else { continue }
                        if let error = json["error"] {
                            throw Self.decodeError(error, fallback: "\(error)")
                        }
                        if let message = json["message"] as? [String: Any],
                            let content = message["content"] as? String, !content.isEmpty
                        {
                            continuation.yield(content)
                        }
                        if json["done"] as? Bool == true { break }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: Self.mapTransport(error))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - Daemon

    /// Installed model names. Also the reachability check.
    func tags() async throws -> [String] {
        var request = request(path: "api/tags", body: nil)
        // Short timeout: this is a liveness probe, not a generation.
        request.timeoutInterval = 5
        let (data, response) = try await send(request)
        try check(response, data: data)
        guard
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = json["models"] as? [[String: Any]]
        else { throw ClientError.malformedResponse }
        return models.compactMap { $0["name"] as? String }.sorted()
    }

    /// Unload **our** model. An empty `messages` array makes this a pure
    /// load/unload operation.
    ///
    /// Only ever our own: Ollama is a shared daemon and another application may
    /// be using a resident model. Evicting it to free memory would be antisocial.
    func unload() async throws {
        let payload = try JSONSerialization.data(withJSONObject: [
            "model": model, "messages": [], "keep_alive": 0,
        ])
        _ = try? await send(request(path: "api/chat", body: payload))
    }

    // MARK: - Plumbing

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await URLSession.shared.data(for: request)
        } catch {
            throw Self.mapTransport(error)
        }
    }

    private static func mapTransport(_ error: Error) -> Error {
        if let error = error as? ClientError { return error }
        let code = (error as NSError).code
        if code == NSURLErrorCannotConnectToHost || code == NSURLErrorNetworkConnectionLost
            || code == NSURLErrorCannotFindHost
        {
            return ClientError.unreachable
        }
        return error
    }

    private func check(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse, http.statusCode != 200 else { return }
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let error = json?["error"] {
            throw Self.decodeError(error, fallback: String(decoding: data, as: UTF8.self))
        }
        throw ClientError.http(
            status: http.statusCode, message: String(decoding: data, as: UTF8.self))
    }

    /// Ollama reports context overflow as a structured error carrying the token
    /// counts; surfacing it as a distinct case is what lets the summarizer fall
    /// back to chunking rather than guessing at a budget.
    static func decodeError(_ error: Any, fallback: String) -> ClientError {
        guard let dict = error as? [String: Any] else {
            let text = (error as? String) ?? fallback
            return text.contains("not found")
                ? .modelMissing(text) : .http(status: 500, message: text)
        }
        let inner = (dict["error"] as? [String: Any]) ?? dict
        let type = inner["type"] as? String
        if type == "exceed_context_size_error" {
            return .contextExceeded(
                promptTokens: inner["n_prompt_tokens"] as? Int ?? 0,
                contextTokens: inner["n_ctx"] as? Int ?? 0)
        }
        let message = inner["message"] as? String ?? fallback
        if message.localizedCaseInsensitiveContains("not found") {
            return .modelMissing(message)
        }
        return .http(status: inner["code"] as? Int ?? 500, message: message)
    }
}
