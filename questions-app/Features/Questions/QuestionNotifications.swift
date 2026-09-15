import Foundation
import UserNotifications

/// Notification identifiers and payloads for questions.
///
/// These strings are a contract between `setNotificationCategories` and the
/// `didReceive response:` handler in main.swift. A typo in one silently
/// produces a banner with no buttons, or a tap that does nothing — so they
/// live here rather than being written out at each site.
public enum QuestionNotification {
    public static let category = "barry.question"
    public static let openAction = "barry.question.open"
    public static let dismissAction = "barry.question.dismiss"
    /// Prefix for the inline answer buttons. The chosen label is appended, so
    /// the handler can recover it without a lookup table that could drift.
    public static let choicePrefix = "barry.question.choice."

    public static func choiceAction(for label: String) -> String {
        choicePrefix + label
    }

    public static func label(fromAction identifier: String) -> String? {
        guard identifier.hasPrefix(choicePrefix) else { return nil }
        return String(identifier.dropFirst(choicePrefix.count))
    }

    /// macOS renders at most a handful of actions before collapsing them, and
    /// a banner is the wrong place to read a long option list anyway. Past
    /// this, the banner just opens the app.
    public static let maxInlineOptions = 3

    /// A question is answerable straight from the banner only when it asks one
    /// thing, with a short list of options, and no free text to type.
    public static func inlineOptions(for question: Question) -> [String] {
        guard question.questions.count == 1,
              let single = question.questions.first,
              !single.isFreeText,
              !single.multiSelect,
              let options = single.options,
              options.count <= maxInlineOptions
        else { return [] }
        return options.map(\.label)
    }

    /// Categories must be registered before any banner is posted, otherwise
    /// macOS shows it with no buttons and the reader's only route is opening
    /// the app.
    ///
    /// Actions are fixed at registration time, but the options differ per
    /// question — so one category is registered per distinct option set, keyed
    /// by the labels it carries.
    public static func makeCategory(labels: [String]) -> UNNotificationCategory {
        var actions = labels.map {
            UNNotificationAction(identifier: choiceAction(for: $0), title: $0, options: [])
        }
        actions.append(
            UNNotificationAction(identifier: openAction, title: "Open", options: [.foreground])
        )
        return UNNotificationCategory(
            identifier: categoryIdentifier(for: labels),
            actions: actions,
            intentIdentifiers: [],
            options: []
        )
    }

    public static func categoryIdentifier(for labels: [String]) -> String {
        labels.isEmpty ? category : "\(category).\(labels.joined(separator: "|"))"
    }

    public static func content(for question: Question) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Question"
        content.subtitle = question.requester
        content.body = question.questions.first?.question ?? "An agent is waiting on an answer."
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier(for: inlineOptions(for: question))
        content.userInfo = ["action": "question", "questionId": question.id]
        return content
    }

    /// Post the banner, reporting whether the system actually accepted it.
    ///
    /// `add` succeeds silently when notifications are denied, so a caller that
    /// ignores this can believe it asked the user something nobody will ever
    /// see. A question blocks an agent, so undelivered has to be visible — the
    /// whole point of the primitive is that a broken delivery path cannot
    /// masquerade as "no answer yet".
    public static func submit(
        _ question: Question,
        onResult: @escaping @Sendable (Bool, String?) -> Void
    ) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized
                    || settings.authorizationStatus == .provisional else {
                onResult(false, "Notifications are not permitted for Questions, so banners will not appear. Answer in the app, or allow notifications in System Settings.")
                return
            }
            guard settings.alertSetting == .enabled else {
                onResult(false, "Notification banners are turned off for Questions, so questions will only appear in the app. Enable alerts in System Settings to get them as banners.")
                return
            }

            let labels = inlineOptions(for: question)
            // Register this question's category before posting it. Doing it
            // here rather than once at launch is what lets the banner carry
            // the actual option labels as buttons.
            center.getNotificationCategories { existing in
                var categories = existing
                categories.insert(makeCategory(labels: labels))
                center.setNotificationCategories(categories)

                center.add(
                    UNNotificationRequest(
                        identifier: question.id,
                        content: content(for: question),
                        trigger: nil
                    )
                ) { error in
                    if let error {
                        onResult(false, "The system refused the notification: \(error.localizedDescription)")
                    } else {
                        onResult(true, nil)
                    }
                }
            }
        }
    }

    /// Pull a banner once the question is settled, so a stale one cannot be
    /// answered a second time from Notification Center.
    public static func withdraw(questionId: String) {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [questionId])
        center.removePendingNotificationRequests(withIdentifiers: [questionId])
    }
}
