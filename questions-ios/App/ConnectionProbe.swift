import Foundation

/// What a "Test connection" attempt actually proved.
///
/// The cases exist to keep failures that need DIFFERENT fixes from looking
/// alike. The user moves between tailnets, so "this phone cannot see that
/// tailnet" and "the service is down" arrive as the same spinner-then-nothing
/// unless the probe names them apart.
///
/// `reachableButUnauthorized` is deliberately a SUCCESS for reachability: a
/// rejected credential is the service answering, which proves the whole network
/// path works and narrows the problem to the secret. Reporting it as a flat
/// failure would send someone hunting a network fault the probe just disproved.
enum ProbeOutcome: Equatable {
    case working(questionCount: Int)
    case reachableButUnauthorized
    case cannotResolveHost
    case cannotConnect
    case tlsFailure(String)
    case timedOut
    case serverError(status: Int, detail: String)
    case badURL
    case badResponse(String)

    /// Whether the service was proved to be there. A rejected credential
    /// counts — it is the service talking.
    var isReachable: Bool {
        switch self {
        case .working, .reachableButUnauthorized, .serverError:
            return true
        case .cannotResolveHost, .cannotConnect, .tlsFailure, .timedOut, .badURL, .badResponse:
            return false
        }
    }

    /// Whether the app can actually load questions with this configuration.
    var isFullyWorking: Bool {
        if case .working = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .working(let count):
            return "Connected and authorized — the service returned \(count) question\(count == 1 ? "" : "s")."
        case .reachableButUnauthorized:
            return "Server reached, but the secret is missing or wrong. "
                 + "The network path works — fix the secret below."
        case .cannotResolveHost:
            return "Cannot resolve that host name. This phone is probably on a "
                 + "different tailnet, or the Mac's Tailscale sidecar is not running."
        case .cannotConnect:
            return "Resolved the host but could not connect. The Mac is on the "
                 + "tailnet but the sidecar is not serving that port."
        case .tlsFailure(let detail):
            return "Reached the server but TLS failed: \(detail)"
        case .timedOut:
            return "Timed out with no reply. Check the tailnet is up on both ends."
        case .serverError(let status, let detail):
            return detail.isEmpty
                ? "Server reached, but it answered \(status)."
                : "Server reached, but it answered \(status): \(detail)"
        case .badURL:
            return "That is not a valid server URL."
        case .badResponse(let detail):
            return "Reached the server but could not read its reply: \(detail)"
        }
    }
}

/// Makes a REAL request and reports what it found.
///
/// Two requests, because one cannot answer both questions. `/health` takes no
/// auth, so it separates "the service is there" from "the secret is wrong"; the
/// questions route then proves the credential actually works and says how much
/// data came back. A probe that only called the authenticated route would
/// report an identical failure for a down service and a bad secret.
struct ConnectionProbe {
    var config: ServerConfig
    var urlSession: URLSession = .shared

    func run() async -> ProbeOutcome {
        guard let healthRequest = config.request(path: ServerConfig.healthPath) else {
            return .badURL
        }
        // The health check answers the reachability question. Any transport
        // error here is the real diagnosis, so return it rather than pressing on.
        do {
            let (_, response) = try await urlSession.data(for: healthRequest)
            // A non-2xx from the ONE unauthenticated route means whatever
            // answered is not a healthy questions service. Say that here rather
            // than letting the authenticated call below blame the secret for it.
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return .serverError(status: http.statusCode,
                                    detail: "unexpected reply from \(ServerConfig.healthPath)")
            }
        } catch {
            return Self.classify(transportError: error)
        }

        do {
            let questions = try await QuestionsClient(config: config, urlSession: urlSession).questions()
            return .working(questionCount: questions.count)
        } catch let error as QuestionsError {
            return Self.classify(apiError: error)
        } catch {
            return Self.classify(transportError: error)
        }
    }

    /// `URLError` code → what the user should go fix.
    static func classify(transportError error: Error) -> ProbeOutcome {
        guard let urlError = error as? URLError else {
            return .badResponse(error.localizedDescription)
        }
        switch urlError.code {
        case .cannotFindHost, .dnsLookupFailed:
            return .cannotResolveHost
        case .cannotConnectToHost, .networkConnectionLost, .notConnectedToInternet:
            return .cannotConnect
        case .secureConnectionFailed, .serverCertificateUntrusted,
             .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired, .appTransportSecurityRequiresSecureConnection:
            return .tlsFailure(urlError.localizedDescription)
        case .timedOut:
            return .timedOut
        case .badURL, .unsupportedURL:
            return .badURL
        default:
            return .badResponse(urlError.localizedDescription)
        }
    }

    /// The questions service answers an unauthenticated caller with 401; 403 is
    /// accepted too, so a proxy that prefers the other spelling still reads as
    /// a credential problem rather than a mystery server error.
    static func classify(apiError error: QuestionsError) -> ProbeOutcome {
        switch error {
        case .badURL:
            return .badURL
        case .decoding(let detail):
            return .badResponse(detail)
        case .http(let status, let detail):
            return (status == 401 || status == 403)
                ? .reachableButUnauthorized
                : .serverError(status: status, detail: detail)
        }
    }
}
