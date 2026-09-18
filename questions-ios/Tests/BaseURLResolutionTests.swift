import XCTest
@testable import Questions

/// Which base URL wins when a saved value and a shipped default disagree.
///
/// `UserDefaults` survives an app reinstall, so a value saved once can outlive
/// the default that produced it. Before this rule existed, every app on the
/// phone kept dialling a Tailscale IP that had been dead for weeks while the
/// new address sat compiled into the binary, unused — and the symptom was a
/// connection timeout, which reads as "the server is down" rather than "this
/// app is pointed at the wrong place".
final class BaseURLResolutionTests: XCTestCase {
    private let current = "https://barry-mac.tail5cb2f2.ts.net:8446"
    private let fossil = "http://100.97.236.110"

    func testNothingSavedUsesTheDefault() {
        XCTAssertEqual(
            ServerConfig.resolveBaseURL(saved: nil, savedUnderDefault: nil, currentDefault: current),
            current
        )
    }

    func testAnEmptySavedValueUsesTheDefault() {
        XCTAssertEqual(
            ServerConfig.resolveBaseURL(saved: "", savedUnderDefault: fossil, currentDefault: current),
            current
        )
    }

    /// The case that broke every app: a value saved by a build that predates
    /// this bookkeeping, so there is no origin recorded next to it.
    func testAnUnstampedSavedValueIsDiscarded() {
        XCTAssertEqual(
            ServerConfig.resolveBaseURL(saved: fossil, savedUnderDefault: nil, currentDefault: current),
            current,
            "a saved URL with no recorded origin is a fossil of an older build, not a choice"
        )
    }

    /// Saved because it was simply what shipped — never chosen.
    func testAnInheritedDefaultIsSupersededByANewerOne() {
        XCTAssertEqual(
            ServerConfig.resolveBaseURL(saved: fossil, savedUnderDefault: fossil, currentDefault: current),
            current,
            "a value equal to the default it was saved under was inherited, not chosen"
        )
    }

    /// The case the rule must NOT break: a deliberate override.
    func testAUserChosenURLSurvivesANewDefault() {
        let chosen = "http://192.168.1.50:3869"
        XCTAssertEqual(
            ServerConfig.resolveBaseURL(saved: chosen, savedUnderDefault: fossil, currentDefault: current),
            chosen,
            "a value that differed from the default in force was typed by the user and must be kept"
        )
    }

    /// A chosen URL keeps winning across repeated launches, not just the first.
    func testAUserChosenURLIsStableAcrossLaunches() {
        let chosen = "http://192.168.1.50:3869"
        let once = ServerConfig.resolveBaseURL(
            saved: chosen, savedUnderDefault: fossil, currentDefault: current
        )
        XCTAssertEqual(
            ServerConfig.resolveBaseURL(saved: once, savedUnderDefault: fossil, currentDefault: current),
            chosen
        )
    }

    /// The shipped default itself differs per platform, and the rule must send
    /// a simulator build to the simulator address rather than the device one.
    func testTheSimulatorDefaultIsUsedWhenNothingWasSaved() {
        XCTAssertEqual(
            ServerConfig.resolveBaseURL(
                saved: nil, savedUnderDefault: nil, currentDefault: ServerConfig.simulatorURL
            ),
            ServerConfig.simulatorURL
        )
    }
}
