import SwiftUI
import SwiftData

struct SettingsView: View {
    @Query private var settingsArray: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("videoResolution") private var videoResolution: String = "1080p"
    @AppStorage("videoFPS") private var videoFPS: Int = 30
    @AppStorage("dimDuringRecording") private var dimDuringRecording: Bool = true

    private var settings: AppSettings {
        if let existing = settingsArray.first { return existing }
        let new = AppSettings()
        modelContext.insert(new)
        return new
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Resolution", selection: $videoResolution) {
                        Text("1080p").tag("1080p")
                        Text("4K").tag("4k")
                    }

                    Picker("Frame Rate", selection: $videoFPS) {
                        Text("24 fps").tag(24)
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                } header: {
                    Text("Video Quality")
                } footer: {
                    Text("Higher quality uses more storage")
                }

                Section("Recording") {
                    Picker("Countdown", selection: Binding(
                        get: { settings.countdownDuration },
                        set: { settings.countdownDuration = $0 }
                    )) {
                        Text("Off").tag(0)
                        Text("3 sec").tag(3)
                        Text("5 sec").tag(5)
                        Text("10 sec").tag(10)
                    }

                    Toggle("Dim Screen While Recording", isOn: $dimDuringRecording)
                }

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Settings")
        }
        .preferredColorScheme(.dark)
    }
}
