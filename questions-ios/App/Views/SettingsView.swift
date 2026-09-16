import SwiftUI

struct SettingsView: View {
    /// Held as a constant: inlining this as a concatenated literal made the
    /// type-checker give up on the whole `Form` body.
    private static let serverFooter = """
    The Mac's Tailscale address. It CHANGES — find the current one with \
    `tailscale ip -4`. The host header routes the request through Caddy; the \
    raw service port is not reachable from a phone.

    Unlike the events feed, nothing injects a secret on this path — the \
    questions service checks every route itself, so the secret is required \
    on a device.
    """

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: String = ""
    @State private var hostHeader: String = ""
    @State private var secret: String = ""
    @State private var probeResult: String?
    @State private var probeOK = false
    @State private var isProbing = false

    var body: some View {
        Form {
            Section {
                TextField("http://100.x.x.x", text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverURLField")
                TextField("Host header (e.g. barry.lan)", text: $hostHeader)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("hostHeaderField")
                SecureField("BARRY_SECRET (required)", text: $secret)
                    .accessibilityIdentifier("secretField")
            } header: {
                Text("Server")
            } footer: {
                Text(Self.serverFooter)
            }

            Section {
                Button {
                    Task { await probe() }
                } label: {
                    HStack {
                        Text("Test connection")
                        if isProbing {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .accessibilityIdentifier("testConnectionButton")

                if let probeResult {
                    Label(probeResult, systemImage: probeOK ? "checkmark.circle" : "xmark.circle")
                        .foregroundStyle(probeOK ? .green : .red)
                        .font(.footnote)
                        .accessibilityIdentifier("probeResult")
                }
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    store.updateConfig(
                        ServerConfig(baseURL: baseURL, hostHeader: hostHeader, secret: secret)
                    )
                    dismiss()
                }
            }
        }
        .onAppear {
            baseURL = store.config.baseURL
            hostHeader = store.config.hostHeader
            secret = store.config.secret
        }
    }

    private func probe() async {
        isProbing = true
        defer { isProbing = false }
        let candidate = ServerConfig(baseURL: baseURL, hostHeader: hostHeader, secret: secret)
        do {
            // /health needs no auth, so it separates "server down" from
            // "wrong secret" — then one authenticated call checks the secret.
            guard try await QuestionsClient(config: candidate).health() else {
                probeOK = false
                probeResult = "Reached the server, but it reports unhealthy."
                return
            }
            _ = try await QuestionsClient(config: candidate).questions()
            probeOK = true
            probeResult = "Connected."
        } catch {
            probeOK = false
            probeResult = error.localizedDescription
        }
    }
}
