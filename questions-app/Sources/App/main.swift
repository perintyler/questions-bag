import SwiftUI
import AppKit
import UserNotifications
import QuestionsFeature

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    let state = QuestionsState()

    func setup() {
        UNUserNotificationCenter.current().delegate = self
        // Ask once, at launch. A question that cannot be delivered is still
        // recorded as undelivered, so a refusal here degrades the app to
        // "answer in the window" rather than breaking it.
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }

        let hosting = NSHostingController(rootView: QuestionsView(state: state))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Questions"
        window.minSize = NSSize(width: 560, height: 420)
        window.contentViewController = hosting
        // Setting contentViewController re-sizes the window to the hosted
        // view's fitting size, discarding the contentRect above. Restore the
        // intended size after the assignment.
        window.setContentSize(NSSize(width: 820, height: 680))
        window.center()
        // The default `true` over-releases a window ARC owns, and the process
        // dies on close.
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Show the banner even when this app is frontmost. Someone with the
    /// window open still wants to know a new question arrived — and without
    /// this, macOS silently drops it.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        guard let questionId = info["questionId"] as? String else { return }

        if let label = QuestionNotification.label(fromAction: response.actionIdentifier) {
            // Answered straight from the banner, without opening anything.
            await state.answerFromNotification(questionId: questionId, label: label)
            return
        }

        // Any other tap — the Open button, or the banner body — brings the
        // window forward so the question can be read in full.
        showWindow()
        await state.refresh()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // barry-question://question/<id> — from the web page or a link.
        for url in urls where url.scheme == "barry-question" {
            showWindow()
            Task { await state.refresh() }
            break
        }
    }

    private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Opened on demand, quits with its window. The notification is the
        // entry point, so a resident process would be cost with no return —
        // the `login-item: false` reasoning in bag.yaml.
        true
    }
}

// Strong global reference (NSApp.delegate is weak).
nonisolated(unsafe) var appDelegateRef: AppDelegate!

// Top-level code runs on the main thread, but main.swift executables do not
// get static MainActor isolation — assert it so MainActor types are reachable.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    appDelegateRef = delegate
    app.delegate = delegate
    app.setActivationPolicy(.regular)
    delegate.setup()
    app.run()
}
