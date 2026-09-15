import Foundation

/// A question an agent is blocked on, as the service reports it.
///
/// Mirrors `src/types.ts`. The two definitions are kept in step by
/// `QuestionDecodingTests`, which decodes a payload copied from a real service
/// response — a drifting field here shows up as an app that silently renders
/// nothing rather than as a compile error.
public struct Question: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let sessionId: String?
    public let requester: String
    public let context: String?
    public let questions: [AskedQuestion]
    public let answers: [QuestionAnswer]?
    public let state: State
    public let answeredBy: String?
    public let answeredAt: String?
    public let expiresAt: String
    public let createdAt: String

    public enum State: String, Codable, Sendable {
        case pending
        case answered
        case expired
        case dismissed
    }

    /// `snake_case` on the wire, because the store is SQLite and the service
    /// hands its rows back unmodified.
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

    public var isPending: Bool { state == .pending }

    public init(
        id: String,
        sessionId: String?,
        requester: String,
        context: String?,
        questions: [AskedQuestion],
        answers: [QuestionAnswer]?,
        state: State,
        answeredBy: String?,
        answeredAt: String?,
        expiresAt: String,
        createdAt: String
    ) {
        self.id = id
        self.sessionId = sessionId
        self.requester = requester
        self.context = context
        self.questions = questions
        self.answers = answers
        self.state = state
        self.answeredBy = answeredBy
        self.answeredAt = answeredAt
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }
}

public struct AskedQuestion: Identifiable, Codable, Sendable, Equatable {
    public let id: String
    public let question: String
    public let header: String?
    public let kind: Kind
    public let options: [QuestionOption]?
    public let multiSelect: Bool
    /// Pre-selects in the UI. Never sent on the reader's behalf — a question
    /// nobody answers expires, and the agent is told so.
    public let `default`: String?

    public enum Kind: String, Codable, Sendable {
        case choice
        case text
        case confirm
    }

    public var isFreeText: Bool { options?.isEmpty ?? true }

    public init(
        id: String,
        question: String,
        header: String?,
        kind: Kind,
        options: [QuestionOption]?,
        multiSelect: Bool,
        default defaultLabel: String?
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

public struct QuestionOption: Codable, Sendable, Equatable, Hashable {
    public let label: String
    public let description: String?
    /// Shown beside the option — a snippet, a diff, a mockup. The reason this
    /// app beats a terminal popover for anything visual.
    public let preview: String?

    public init(label: String, description: String? = nil, preview: String? = nil) {
        self.label = label
        self.description = description
        self.preview = preview
    }
}

public struct QuestionAnswer: Codable, Sendable, Equatable {
    public let questionId: String
    public let selected: [String]
    public let text: String?

    public init(questionId: String, selected: [String], text: String? = nil) {
        self.questionId = questionId
        self.selected = selected
        self.text = text
    }
}
