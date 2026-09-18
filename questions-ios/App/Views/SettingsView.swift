import SwiftUI

struct SettingsView: View {
    /// Held as a constant: inlining this as a concatenated literal made the
    /// type-checker give up on the whole `Form` body.
    private static let serverFooter = """
    On a phone the app reaches the Mac over the tailnet at a stable DNS name, \
    which serves a real certificate and proxies straight to the questions \
    service. There is no address to keep up to date.

    Nothing injects a secret on this path — the questions service checks every \
    route itself, so the secret is required on a device.
    """

    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss

    @State private var baseURL: String = ""
    @State private var secret: String = ""
    @State private var outcome: ProbeOutcome?
    @State private var isProbing = false

    var body: some View {
        Form {
            Section {
                TextField(ServerConfig.defaultDeviceURL, text: $baseURL)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("serverURLField")
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
                .disabled(isProbing)
                .accessibilityIdentifier("testConnectionButton")

                if let outcome {
                    Label {
                        Text(outcome.message)
                    } icon: {
                        Image(systemName: icon(for: outcome))
                    }
                    .foregroundStyle(tint(for: outcome))
                    .font(.footnote)
                    .accessibilityIdentifier("probeResult")
                }
            } footer: {
                Text("Makes a real request. It tells apart a server that is not "
                     + "reachable from one that is reachable but refused the secret.")
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    store.updateConfig(ServerConfig(baseURL: baseURL, secret: secret))
                    dismiss()
                }
            }
        }
        .onAppear {
            baseURL = store.config.baseURL
            secret = store.config.secret
        }
    }

    /// Three states, not two: a refused credential proved the network path
    /// works, so it must not wear the same red X as a host that never answered.
    private func icon(for outcome: ProbeOutcome) -> String {
        if outcome.isFullyWorking { return "checkmark.circle" }
        return outcome.isReachable ? "exclamationmark.triangle" : "xmark.circle"
    }

    private func tint(for outcome: ProbeOutcome) -> Color {
        if outcome.isFullyWorking { return .green }
        return outcome.isReachable ? .orange : .red
    }

    private func probe() async {
        isProbing = true
        defer { isProbing = false }
        let candidate = ServerConfig(baseURL: baseURL, secret: secret)
        outcome = await ConnectionProbe(config: candidate).run()
    }
}
