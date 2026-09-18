import XCTest
@testable import Questions

/// What "Test connection" tells the user.
///
/// The classification is the whole point of the feature: the user moves between
/// tailnets, so the failure modes that need DIFFERENT fixes must not arrive
/// wearing the same message. These drive the mapping directly — no network
/// needed, because a `URLError` is just a value.
final class ConnectionProbeTests: XCTestCase {

    // MARK: - Transport failures stay distinguishable

    func testWrongTailnetAndDownServiceAreDifferentOutcomes() {
        let unresolvable = ConnectionProbe.classify(transportError: URLError(.cannotFindHost))
        let refused = ConnectionProbe.classify(transportError: URLError(.cannotConnectToHost))

        XCTAssertEqual(unresolvable, .cannotResolveHost)
        XCTAssertEqual(refused, .cannotConnect)
        XCTAssertNotEqual(unresolvable.message, refused.message,
                          "a wrong tailnet and a dead service must not read identically")
    }

    func testDNSFailureIsReportedAsAnUnresolvableHost() {
        XCTAssertEqual(ConnectionProbe.classify(transportError: URLError(.dnsLookupFailed)),
                       .cannotResolveHost)
    }

    func testTLSFailuresAreTheirOwnCategory() {
        for code in [URLError.Code.secureConnectionFailed,
                     .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot,
                     .serverCertificateHasBadDate] {
            let outcome = ConnectionProbe.classify(transportError: URLError(code))
            guard case .tlsFailure = outcome else {
                return XCTFail("\(code) should classify as a TLS failure, got \(outcome)")
            }
            XCTAssertFalse(outcome.isReachable)
        }
    }

    /// Removing `NSAllowsArbitraryLoads` means a plain-HTTP call to a non-local
    /// host now fails at the ATS layer. That must say "TLS", not "host is down"
    /// — the fix is a URL scheme, not a network.
    func testBlockedCleartextReadsAsATLSProblem() {
        let outcome = ConnectionProbe.classify(
            transportError: URLError(.appTransportSecurityRequiresSecureConnection)
        )
        guard case .tlsFailure = outcome else {
            return XCTFail("ATS-blocked cleartext should classify as a TLS failure, got \(outcome)")
        }
    }

    func testTimeoutIsNotConflatedWithAConnectionRefusal() {
        let timedOut = ConnectionProbe.classify(transportError: URLError(.timedOut))
        XCTAssertEqual(timedOut, .timedOut)
        XCTAssertNotEqual(timedOut.message, ProbeOutcome.cannotConnect.message)
    }

    // MARK: - A refused credential is a reachability SUCCESS

    /// The case that makes this probe honest. A refused credential is the
    /// service answering, which PROVES the tailnet path works — reporting it
    /// as a flat failure would send someone debugging a network the probe
    /// just verified.
    ///
    /// Both spellings are checked: 401 and 403 differ in HTTP theory but not
    /// in what the user has to go fix.
    func testRefusedCredentialIsReachableAndSaysTheSecretIsTheProblem() {
        for status in [401, 403] {
            let outcome = ConnectionProbe.classify(apiError: .http(status, "Forbidden"))

            XCTAssertEqual(outcome, .reachableButUnauthorized, "status \(status)")
            XCTAssertTrue(outcome.isReachable,
                          "a \(status) came from the server, so the server is reachable")
            XCTAssertFalse(outcome.isFullyWorking, "but the app still cannot load questions")

            let message = outcome.message.lowercased()
            XCTAssertTrue(message.contains("secret"),
                          "must name the secret as the thing to fix: \(outcome.message)")
            XCTAssertTrue(message.contains("reached"),
                          "must say the server was reached: \(outcome.message)")
        }
    }

    func testOtherHTTPErrorsAreReachableButNotBlamedOnTheSecret() {
        let outcome = ConnectionProbe.classify(apiError: .http(502, "Bad Gateway"))

        guard case .serverError(let status, _) = outcome else {
            return XCTFail("expected a server error, got \(outcome)")
        }
        XCTAssertEqual(status, 502)
        XCTAssertTrue(outcome.isReachable)
        XCTAssertFalse(outcome.message.lowercased().contains("secret"),
                       "a 502 is not a credential problem")
    }

    // MARK: - Success reports what it actually saw

    func testSuccessReportsTheQuestionCount() {
        XCTAssertTrue(ProbeOutcome.working(questionCount: 7).message.contains("7"),
                      "a success that names no number proves nothing about the data")
        XCTAssertTrue(ProbeOutcome.working(questionCount: 7).isFullyWorking)
    }

    /// A probe that cannot distinguish its own states is the failure mode
    /// AGENTS.md warns about: if this were completely broken, every outcome
    /// would read the same and the user would learn nothing.
    func testEveryOutcomeProducesADistinctMessage() {
        let outcomes: [ProbeOutcome] = [
            .working(questionCount: 1),
            .reachableButUnauthorized,
            .cannotResolveHost,
            .cannotConnect,
            .tlsFailure("certificate expired"),
            .timedOut,
            .serverError(status: 502, detail: "Bad Gateway"),
            .badURL,
            .badResponse("garbage"),
        ]
        let messages = Set(outcomes.map(\.message))
        XCTAssertEqual(messages.count, outcomes.count,
                       "two outcomes share a message — the user cannot tell them apart")
    }

    // MARK: - The two requests must stay tellable apart

    /// Pointing at something that answers HTTP but is NOT a healthy questions
    /// service must not come back blaming the secret.
    ///
    /// The health route answers 502 while the data route answers 403. Those
    /// MUST differ: a stub returning one status for everything would leave
    /// this green even with the health check deleted, because the data call
    /// would then produce the same outcome on its own.
    func testAnUnhealthyServerIsNotBlamedOnTheSecret() async {
        let outcome = await ConnectionProbe(
            config: ServerConfig(baseURL: "http://stub.invalid", secret: "shhh"),
            urlSession: StubURLProtocol.session(health: 502, data: 403)
        ).run()

        guard case .serverError(let status, _) = outcome else {
            return XCTFail("a 502 from the health route should outrank the data route's 403, got \(outcome)")
        }
        XCTAssertEqual(status, 502)
        XCTAssertFalse(outcome.message.lowercased().contains("secret"),
                       "a broken health route is not a credential problem")
    }

    /// The mirror image, and the reason the health call happens at all: a
    /// HEALTHY service that refuses the secret must report that refusal.
    func testAHealthyServiceThatRefusesTheSecretReportsUnauthorized() async {
        let outcome = await ConnectionProbe(
            config: ServerConfig(baseURL: "http://stub.invalid", secret: "wrong"),
            urlSession: StubURLProtocol.session(health: 200, data: 403)
        ).run()

        XCTAssertEqual(outcome, .reachableButUnauthorized)
    }

    // MARK: - End to end against the real service

    /// The real service with no secret. This is exactly what a phone sees
    /// before the secret is entered, and it must come back as "reachable, fix
    /// the secret" rather than as a network failure.
    ///
    /// Skips only when the service is genuinely absent — never when it answers,
    /// because an answer is the thing under test.
    func testRealServiceWithNoSecretReportsUnauthorized() async throws {
        let config = ServerConfig(baseURL: ServerConfig.simulatorURL, secret: "")
        guard await serviceIsUp(config) else {
            throw XCTSkip("questions service not listening on 127.0.0.1:3869")
        }

        let outcome = await ConnectionProbe(config: config).run()
        XCTAssertEqual(outcome, .reachableButUnauthorized,
                       "the service authenticates every route itself, even on loopback")
    }

    private func serviceIsUp(_ config: ServerConfig) async -> Bool {
        guard let request = config.request(path: ServerConfig.healthPath) else { return false }
        return (try? await URLSession.shared.data(for: request)) != nil
    }
}

/// Answers the health route and the data route with SEPARATE canned statuses,
/// so a test can tell which of the probe's two requests produced the outcome.
private final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var healthStatus = 200
    nonisolated(unsafe) static var dataStatus = 200

    static func session(health: Int, data: Int) -> URLSession {
        healthStatus = health
        dataStatus = data
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let isHealth = request.url?.path == ServerConfig.healthPath
        let status = isHealth ? Self.healthStatus : Self.dataStatus
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("[]".utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
