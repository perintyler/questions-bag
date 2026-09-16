import SwiftUI

struct RootView: View {
    @EnvironmentObject private var store: AppStore
    @State private var showingSettings = false

    var body: some View {
        NavigationStack {
            QuestionListView()
                .navigationTitle("Questions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { showingSettings = true } label: { Image(systemName: "gearshape") }
                            .accessibilityIdentifier("settingsButton")
                    }
                }
                .sheet(isPresented: $showingSettings) {
                    NavigationStack { SettingsView() }
                }
        }
        .task { store.start() }
        .onDisappear { store.stop() }
    }
}
