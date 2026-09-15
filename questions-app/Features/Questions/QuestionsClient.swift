import Foundation

/// Talks to the questions service.
///
/// The app cannot open the bag's SQLite file, so every read and write goes
/// through the loopback service. The secret comes from `/config`, which the
/// service serves only to loopback callers — the same credential the web page
/// collects, so there is one authentication path rather than a special case
/// that could rot unnoticed.
public actor QuestionsClient {
    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    private let baseURL: URL
    private let session: URLSession
    private var secret: String?

    public init(port: Int = 3869, session: URLSession = .shared) {
        let configured = ProcessInfo.processInfo.environment["BARRY_QUESTIONS_PORT"]
        let resolved = configured.flatMap(Int.init) ?? port
        self.baseURL = URL(string: "http://127.0.0.1:\(resolved)")!
        self.session = session
    }

    private func credential() async throws -> String {
        if let secret { return secret }
        let (data, _) = try await session.data(from: baseURL.appending(path: "config"))
        let config = try JSONDecoder().decode([String: String].self, from: data)
        let value = config["secret"] ?? ""
        secret = value
        return value
    }

    private func request(_ path: String, method: String = "GET", body: Data? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        let secret = try await credential()
        if !secret.isEmpty {
            request.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization")
        }
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw Failure(message: "No response from the questions service.")
        }
        // 409 means someone else settled it first. That is an outcome, not a
        // transport failure, so it comes back as data for the caller to read.
        guard (200..<300).contains(http.statusCode) || http.statusCode == 409 else {
            throw Failure(message: "Questions service returned HTTP \(http.statusCode).")
        }
        return data
    }

    public func list() async throws -> [Question] {
        try JSONDecoder().decode([Question].self, from: try await request("questions"))
    }

    public func get(id: String) async throws -> Question {
        try JSONDecoder().decode(Question.self, from: try await request("questions/\(id)"))
    }

    public func answer(id: String, answers: [QuestionAnswer], surface: String = "app") async throws {
        struct Body: Encodable {
            let answers: [QuestionAnswer]
            let answered_by: String
        }
        _ = try await request(
            "questions/\(id)/answer",
            method: "POST",
            body: try JSONEncoder().encode(Body(answers: answers, answered_by: surface))
        )
    }

    public func dismiss(id: String, surface: String = "app") async throws {
        struct Body: Encodable { let dismissed_by: String }
        _ = try await request(
            "questions/\(id)/dismiss",
            method: "POST",
            body: try JSONEncoder().encode(Body(dismissed_by: surface))
        )
    }

    /// Tell the service whether this question was actually put in front of anyone.
    ///
    /// Reporting the *failures* is the point. `UNUserNotificationCenter.add`
    /// succeeds silently when notifications are denied, so an app that only
    /// reported successes would let a question nobody can see look exactly
    /// like a question nobody has answered yet — and the asking agent would
    /// wait out its whole deadline before saying anything.
    public func reportDelivery(id: String, surface: String, delivered: Bool, detail: String? = nil) async {
        struct Body: Encodable {
            let surface: String
            let delivered: Bool
            let detail: String?
        }
        do {
            _ = try await request(
                "questions/\(id)/delivery",
                method: "POST",
                body: try JSONEncoder().encode(Body(surface: surface, delivered: delivered, detail: detail))
            )
        } catch {
            // Best effort: a failed delivery report must not take down the UI
            // that is, right now, successfully showing the question.
        }
    }
}
