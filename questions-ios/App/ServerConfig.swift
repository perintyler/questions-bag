import Foundation

/// Where the app talks to the questions service, and how it authenticates.
///
///  - Simulator: straight to the service's loopback port, `127.0.0.1:3869`.
///  - Device: HTTPS over the personal tailnet to a userspace `tailscaled`
///    sidecar, which terminates TLS and proxies to that same loopback port.
///
/// The device host is a real tailnet DNS name with a real Let's Encrypt
/// certificate, so there is no certificate prompt and no pinning to do. It
/// replaces a hardcoded Tailscale IP plus a `Host: questions.barry.lan` header
/// selecting a Caddy site block. The IP was the part that kept breaking — it
/// was documented here as a value to re-check with `tailscale ip -4`, and it
/// went stale anyway when the node it named went offline. A stable name removes
/// the maintenance rather than rescheduling it. The sidecar endpoint proxies to
/// this service alone, so there is no vhost left to select.
///
/// The secret is REQUIRED on this path: the questions service authenticates
/// every route itself against BARRY_SECRET, and nothing upstream fills it in.
///
/// The app deliberately does NOT use the service's `/config` route to fetch it.
/// That route is loopback-only (and, since this app existed, refuses proxied
/// callers too), because a client that bootstraps its credential from an
/// unauthenticated endpoint does not really have a credential.
struct ServerConfig: Equatable {
    var baseURL: String
    var secret: String

    static let defaultsKeyBase = "server.baseURL"

    /// This app's OWN keychain item, never shared with the other Barry apps.
    /// Two apps sharing one item would mean signing out of either silently
    /// signs out the other, and the secret is cheap to enter twice.
    static let keychainSecretKey = "rocks.barry.questions.secret"

    static let defaultDeviceURL = "https://barry-mac.tail5cb2f2.ts.net:8446"
    static let simulatorURL = "http://127.0.0.1:3869"

    /// The one route the service answers without a secret. The probe uses it
    /// to tell "the service is not there" apart from "the secret is wrong".
    static let healthPath = "/health"

    static var platformDefault: ServerConfig {
        #if targetEnvironment(simulator)
        ServerConfig(baseURL: simulatorURL, secret: "")
        #else
        ServerConfig(baseURL: defaultDeviceURL, secret: "")
        #endif
    }

    static func load() -> ServerConfig {
        // UI/integration-test hook: `-questionsBaseURL <url>` overrides everything
        // else and skips the keychain, so a test can point the app at an
        // unreachable server (to exercise the error state) without touching
        // real persisted settings. Never wired to anything but launch arguments.
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: "-questionsBaseURL"), args.count > i + 1 {
            var secret = ""
            if let s = args.firstIndex(of: "-questionsSecret"), args.count > s + 1 {
                secret = args[s + 1]
            }
            return ServerConfig(baseURL: args[i + 1], secret: secret)
        }

        let d = UserDefaults.standard
        var c = platformDefault
        if let base = d.string(forKey: defaultsKeyBase), !base.isEmpty { c.baseURL = base }
        c.secret = Keychain.read(key: keychainSecretKey) ?? ""
        return c
    }

    func save() {
        UserDefaults.standard.set(baseURL, forKey: Self.defaultsKeyBase)
        if secret.isEmpty {
            Keychain.delete(key: Self.keychainSecretKey)
        } else {
            Keychain.write(key: Self.keychainSecretKey, value: secret)
        }
    }

    /// Build a request for an API path, applying auth.
    func request(path: String, query: [URLQueryItem] = []) -> URLRequest? {
        guard var components = URLComponents(string: baseURL) else { return nil }
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else { return nil }
        var req = URLRequest(url: url)
        apply(to: &req)
        return req
    }

    /// The service accepts either `Authorization: Bearer <secret>` or
    /// `x-barry-secret: <secret>`. Bearer is used here, the more standard
    /// spelling for a bearer token.
    func apply(to req: inout URLRequest) {
        if !secret.isEmpty { req.setValue("Bearer \(secret)", forHTTPHeaderField: "authorization") }
    }
}

/// Minimal keychain wrapper for the one secret the app stores.
///
/// No `kSecAttrAccessGroup`: that exists to share an item with a widget
/// extension, and this app has none. Requesting a group without the matching
/// entitlement fails with errSecMissingEntitlement.
enum Keychain {
    static func read(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(key: String, value: String) {
        delete(key: key)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
            kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
        ]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
