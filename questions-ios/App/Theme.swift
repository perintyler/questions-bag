import SwiftUI

enum Theme {
    /// How long is left, in words. Questions expire (4h by default), and a
    /// reader deciding whether to answer now needs to know that.
    static func remaining(until date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "expired" }
        if seconds < 60 { return "\(Int(seconds))s left" }
        if seconds < 3600 { return "\(Int(seconds / 60))m left" }
        if seconds < 86_400 { return "\(Int(seconds / 3600))h left" }
        return "\(Int(seconds / 86_400))d left"
    }

    static func urgencyColor(until date: Date, now: Date = Date()) -> Color {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return .secondary }
        if seconds < 900 { return .red }
        if seconds < 3600 { return .orange }
        return .secondary
    }

    static func tint(for state: Question.State) -> Color {
        switch state {
        case .pending: return .blue
        case .answered: return .green
        case .expired: return .secondary
        case .dismissed: return .orange
        }
    }
}
