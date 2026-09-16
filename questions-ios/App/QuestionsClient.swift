import Foundation

enum QuestionsError: LocalizedError, Equatable {
    case badURL
    case http(Int, String)
    case decoding(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "The server URL is not valid."
        case .http(let code, let detail):
            if code == 401 {
                return "Not authorized — set the secret in Settings."
            }
            return detail.isEmpty ? "Server error \(code)." : "Server error \(code): \(detail)"
        case .decoding(let detail):
            return "Could not read the server's response: \(detail)"
        }
    }
}

/// The outcome of trying to settle a question.
///
/// A 409 is NOT an error: two people can answer at once, and the question can
/// expire while a reply is in flight. The service hands back the record that
/// actually stands, and the caller is expected to show it rather than report a
/// failure. The macOS client lets the 409 through but every call site discards
/// the body, so "someone got there first" is invisible there — this type exists
/// so it cannot be dropped silently here.
enum SettleOutcome: Equatable {
    /// This reply won; the record is the settled question.
    case settled(Question)
    /// Someone (or the deadline) got there first; the record is what stands.
    case alreadySettled(Question)
}

/// Talks to the questions service.
struct QuestionsClient {
    let config: ServerConfig
    var urlSession: URLSession = .shared

    /// Every question the store holds, newest first, optionally by state.
    func questions(state: Question.State? = nil) async throws -> [Question] {
        var query: [URLQueryItem] = []
        if let state { query.append(URLQueryItem(name: "state", value: state.rawValue)) }
        return try await get([Question].self, path: "/questions", query: query)
    }

    /// `/health` takes no auth, deliberately: a probe that needs a secret
    /// cannot tell "server down" from "wrong secret".
    func health() async throws -> Bool {
        guard let req = config.request(path: "/health") else { throw QuestionsError.badURL }
        let (_, response) = try await urlSession.data(for: req)
        return (response as? HTTPURLResponse)?.statusCode == 200
    }

    func answer(id: String, answers: [QuestionAnswer]) async throws -> SettleOutcome {
        try await settle(path: "/questions/\(id)/answer",
                         body: ["answers": answers.map(\.wire), "answered_by": "ios"])
    }

    func dismiss(id: String) async throws -> SettleOutcome {
        try await settle(path: "/questions/\(id)/dismiss", body: ["dismissed_by": "ios"])
    }

    /// Tell the service a human actually saw this.
    ///
    /// Delivery is recorded separately from answering, including failures —
    /// `ask` warns the agent after 30s when nothing reports having shown the
    /// question, which is how a broken delivery path stays visible instead of
    /// looking like a slow human.
    func recordDelivery(id: String, delivered: Bool = true, detail: String? = nil) async {
        var body: [String: Any] = ["surface": "ios", "delivered": delivered]
        if let detail { body["detail"] = detail }
        _ = try? await postRaw(path: "/questions/\(id)/delivery", body: body)
    }

    // MARK: - Transport

    private func settle(path: String, body: [String: Any]) async throws -> SettleOutcome {
        let (data, status) = try await postRaw(path: path, body: body)
        if status == 409 {
            return .alreadySettled(try decode(Question.self, data))
        }
        guard (200..<300).contains(status) else {
            throw QuestionsError.http(status, Self.readableDetail(from: data))
        }
        return .settled(try decode(Question.self, data))
    }

    private func postRaw(path: String, body: [String: Any]) async throws -> (Data, Int) {
        guard var req = config.request(path: path) else { throw QuestionsError.badURL }
        req.httpMethod = "POST"
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw QuestionsError.decoding("no HTTP response")
        }
        return (data, http.statusCode)
    }

    private func get<T: Decodable>(_ type: T.Type, path: String, query: [URLQueryItem] = []) async throws -> T {
        guard let req = config.request(path: path, query: query) else { throw QuestionsError.badURL }
        let (data, response) = try await urlSession.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw QuestionsError.decoding("no HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw QuestionsError.http(http.statusCode, Self.readableDetail(from: data))
        }
        return try decode(type, data)
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw QuestionsError.decoding(String(describing: error)) }
    }

    static func readableDetail(from data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return String(data: data, encoding: .utf8) ?? ""
        }
        if let error = object["error"] as? String { return error }
        return String(data: data, encoding: .utf8) ?? ""
    }
}

private extension QuestionAnswer {
    /// The wire shape the service expects: `questionId`, `selected`, `text`.
    var wire: [String: Any] {
        var out: [String: Any] = ["questionId": questionId, "selected": selected]
        if let text, !text.isEmpty { out["text"] = text }
        return out
    }
}
