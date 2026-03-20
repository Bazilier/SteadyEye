import SwiftUI
import SwiftData

struct SettingsView: View {
    @Query private var settingsArray: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("textWidthPreset") private var textWidthRaw: String = TextWidthPreset.medium.rawValue
    @AppStorage("textContainerOffsetX") private var savedOffsetX: Double = 20
    @AppStorage("videoResolution") private var videoResolution: String = "1080p"
    @AppStorage("videoFPS") private var videoFPS: Int = 30

    private var settings: AppSettings {
        if let existing = settingsArray.first { return existing }
        let new = AppSettings()
        modelContext.insert(new)
        return new
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Teleprompter") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Default Speed")
                            Spacer()
                            Text("\(Int(settings.scrollSpeed)) WPM")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { settings.scrollSpeed },
                            set: { settings.scrollSpeed = $0 }
                        ), in: 60...300, step: 10)
                        .accentColor(.orange)
                    }

                    // DISABLED: font size is hardcoded in RecordingView for now
                    // VStack(alignment: .leading, spacing: 4) {
                    //     HStack {
                    //         Text("Default Font Size")
                    //         Spacer()
                    //         Text("\(Int(settings.fontSize)) pt")
                    //             .foregroundStyle(.secondary)
                    //     }
                    //     Slider(value: Binding(
                    //         get: { settings.fontSize },
                    //         set: { settings.fontSize = $0 }
                    //     ), in: 18...52, step: 2)
                    //     .accentColor(.orange)
                    // }
                }

                Section("Text Container") {
                    Picker("Text Width", selection: $textWidthRaw) {
                        ForEach(TextWidthPreset.allCases) { preset in
                            Text(preset.rawValue).tag(preset.rawValue)
                        }
                    }

                    Button("Reset Position to Default") {
                        savedOffsetX = 20
                    }
                    .foregroundStyle(.orange)
                }

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

                    // DISABLED: front camera only for now
                    // Picker("Default Camera", selection: Binding(
                    //     get: { settings.cameraPosition },
                    //     set: { settings.cameraPosition = $0 }
                    // )) {
                    //     Text("Front").tag(CameraPositionPreference.front)
                    //     Text("Back").tag(CameraPositionPreference.back)
                    // }
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
