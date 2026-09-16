import Foundation

/// A question an agent is blocked on, as the service reports it.
///
/// Mirrors `src/types.ts`, but decodes far more defensively than the macOS
/// app's model does, because the store does NOT normalise what it holds.
///
/// `src/store.ts` persists the `questions` payload verbatim: only the MCP `ask`
/// tool mints per-question ids and infers `kind`, so a record created straight
/// over HTTP keeps whatever shape its caller sent. Checked against the live
/// store, real rows carry `kind: null`, `multiSelect: null` and even
/// `id: null`. The macOS model declares all three non-optional and would fail
/// to decode those records outright — the whole list, not just the odd row.
struct Question: Identifiable, Codable, Equatable {
    let id: String
    let sessionId: String?
    let requester: String
    let context: String?
    let questions: [AskedQuestion]
    let answers: [QuestionAnswer]?
    let state: State
    let answeredBy: String?
    let answeredAt: String?
    let expiresAt: String
    let createdAt: String

    enum State: String, Codable, Equatable {
        case pending, answered, expired, dismissed
    }

    /// `snake_case` on the wire — the store is SQLite and the service hands its
    /// rows back unmodified. (The events API is camelCase; they differ.)
    enum CodingKeys: String, CodingKey {
        case id
        case sessionId = "session_id"
        case requester
        case context
        case questions
        case answers
        case state
        case answeredBy = "answered_by"
        case answeredAt = "answered_at"
        case expiresAt = "expires_at"
        case createdAt = "created_at"
    }

    var isPending: Bool { state == .pending }

    /// Dates arrive as SQLite `datetime('now')` output — `YYYY-MM-DD HH:MM:SS`
    /// in UTC, not ISO8601. Parsed here rather than by a decoder strategy
    /// because only two fields use it and the rest are plain strings.
    var expiresAtDate: Date? { Self.parseStoreDate(expiresAt) }
    var createdAtDate: Date? { Self.parseStoreDate(createdAt) }

    static func parseStoreDate(_ raw: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f.date(from: raw)
    }
}

/// One question inside a record.
///
/// `id` is synthesised when the payload lacks one, because the answer POST is
/// keyed by it: without a stable id the answer cannot be attributed to the
/// question it belongs to. The index is used, which matches how a caller that
/// omitted ids would have ordered them.
struct AskedQuestion: Identifiable, Codable, Equatable {
    let id: String
    let question: String
    let header: String?
    let kind: Kind
    let options: [QuestionOption]?
    let multiSelect: Bool
    /// Pre-selects in the UI. NEVER sent on the reader's behalf — a question
    /// nobody answers expires, and the agent is told so rather than handed a
    /// default dressed up as a decision.
    let `default`: String?

    enum Kind: String, Codable, Equatable {
        case choice, text, confirm
    }

    var isFreeText: Bool { options?.isEmpty ?? true }

    enum CodingKeys: String, CodingKey {
        case id, question, header, kind, options, multiSelect, `default`
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        question = try c.decode(String.self, forKey: .question)
        header = try c.decodeIfPresent(String.self, forKey: .header)
        options = try c.decodeIfPresent([QuestionOption].self, forKey: .options)
        multiSelect = try c.decodeIfPresent(Bool.self, forKey: .multiSelect) ?? false
        `default` = try c.decodeIfPresent(String.self, forKey: .default)

        // Mirrors `inferKind` in src/tools.ts: options means a choice,
        // otherwise free text. Applied here too, so a record written straight
        // over HTTP renders the same as one the ask tool created.
        if let declared = try c.decodeIfPresent(Kind.self, forKey: .kind) {
            kind = declared
        } else {
            kind = (options?.isEmpty ?? true) ? .text : .choice
        }

        if let declared = try c.decodeIfPresent(String.self, forKey: .id), !declared.isEmpty {
            id = declared
        } else {
            id = Self.synthesisedId(for: decoder)
        }
    }

    /// Positional fallback id, derived from the decoding path.
    private static func synthesisedId(for decoder: Decoder) -> String {
        if let last = decoder.codingPath.last, let index = last.intValue {
            return "q\(index)"
        }
        return "q0"
    }

    init(
        id: String, question: String, header: String? = nil, kind: Kind,
        options: [QuestionOption]? = nil, multiSelect: Bool = false,
        default defaultLabel: String? = nil
    ) {
        self.id = id
        self.question = question
        self.header = header
        self.kind = kind
        self.options = options
        self.multiSelect = multiSelect
        self.default = defaultLabel
    }
}

struct QuestionOption: Codable, Equatable, Hashable {
    let label: String
    let description: String?
    /// Shown beside the option — a snippet, a diff, a mockup. The reason a
    /// real UI beats a terminal popover for anything visual.
    let preview: String?

    init(label: String, description: String? = nil, preview: String? = nil) {
        self.label = label
        self.description = description
        self.preview = preview
    }
}

struct QuestionAnswer: Codable, Equatable {
    let questionId: String
    let selected: [String]
    let text: String?

    init(questionId: String, selected: [String], text: String? = nil) {
        self.questionId = questionId
        self.selected = selected
        self.text = text
    }
}
