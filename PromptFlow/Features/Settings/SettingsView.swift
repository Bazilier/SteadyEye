import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @Query private var settingsArray: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("videoResolution") private var videoResolution: String = "1080p"
    @AppStorage("videoFPS") private var videoFPS: Int = 30
    @AppStorage("dimDuringRecording") private var dimDuringRecording: Bool = true

    @AppStorage("stabilizationEnabled") private var stabilizationEnabled: Bool = true
    @AppStorage("autoStartPrompting") private var autoStartPrompting: Bool = true
    @AppStorage("orpAlignmentEnabled") private var orpAlignmentEnabled: Bool = false
    @AppStorage("orpHighlightAnchor") private var orpHighlightAnchor: Bool = false
    @State private var showPaywall = false

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
                    Picker(selection: $videoResolution) {
                        // 1080p / 4K are technical resolution labels — intentionally not localized.
                        Text(verbatim: "1080p").tag("1080p")
                        Text(verbatim: "4K").tag("4k")
                    } label: {
                        Text("settings.video.resolution", comment: "Picker label for video resolution")
                    }

                    Picker(selection: $videoFPS) {
                        // Frame rate labels are universal technical strings — intentionally not localized.
                        Text(verbatim: "24 fps").tag(24)
                        Text(verbatim: "30 fps").tag(30)
                        Text(verbatim: "60 fps").tag(60)
                    } label: {
                        Text("settings.video.frameRate", comment: "Picker label for video frame rate")
                    }
                } header: {
                    Text("settings.section.videoQuality", comment: "Settings section header")
                } footer: {
                    Text("settings.video.qualityFooter", comment: "Footer below the video quality picker")
                }

                Section {
                    Picker(selection: Binding(
                        get: { settings.countdownDuration },
                        set: { settings.countdownDuration = $0 }
                    )) {
                        Text("settings.countdown.off", comment: "Picker option disabling the countdown").tag(0)
                        Text(String(
                            localized: "settings.countdown.seconds",
                            defaultValue: "\(3) sec",
                            comment: "Countdown duration picker option (3 seconds)"
                        )).tag(3)
                        Text(String(
                            localized: "settings.countdown.seconds",
                            defaultValue: "\(5) sec",
                            comment: "Countdown duration picker option (5 seconds)"
                        )).tag(5)
                        Text(String(
                            localized: "settings.countdown.seconds",
                            defaultValue: "\(10) sec",
                            comment: "Countdown duration picker option (10 seconds)"
                        )).tag(10)
                    } label: {
                        Text("settings.recording.countdown", comment: "Picker label for the pre-recording countdown")
                    }

                    Toggle(isOn: $dimDuringRecording) {
                        Text("settings.recording.dimScreen", comment: "Toggle: dim screen while recording")
                    }

                    Toggle(isOn: $stabilizationEnabled) {
                        Text("settings.recording.stabilization", comment: "Toggle: video stabilization")
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $autoStartPrompting) {
                            Text("settings.recording.autoStart", comment: "Toggle: auto-start the prompter when recording begins")
                        }
                        Text("settings.recording.autoStartFooter", comment: "Helper text below the auto-start toggle")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("settings.section.recording", comment: "Settings section header")
                }

                Section {
                    Toggle(isOn: $orpAlignmentEnabled) {
                        Text("settings.anchor.align", comment: "Toggle: align words by anchor letter")
                    }
                    Toggle(isOn: $orpHighlightAnchor) {
                        Text("settings.anchor.highlight", comment: "Toggle: highlight anchor letter")
                    }
                    .disabled(!orpAlignmentEnabled)
                } header: {
                    Text("settings.section.anchorAlignment", comment: "Settings section header for ORP toggles")
                }

                #if DEV
                Section("Debug") {
                    Button("Preview Paywall") { showPaywall = true }
                    Button("Reset Tips") {
                        UserDefaults.standard.set(false, forKey: "hasSeenEditorTip")
                        UserDefaults.standard.set(false, forKey: "hasSeenRecordingTip")
                    }
                    Button("Reset Rate Limits") {
                        UserDefaults.standard.removeObject(forKey: "apiCallsToday")
                        UserDefaults.standard.removeObject(forKey: "bulkImportsToday")
                        UserDefaults.standard.removeObject(forKey: "rateLimitDate")
                    }
                    Button("Reset Free Optimizations") {
                        UserDefaults.standard.set(0, forKey: "freeOptimizationsUsed")
                        SubscriptionManager.shared.freeOptimizationsUsed = 0
                    }
                    HStack {
                        Text("Free optimizations used")
                        Spacer()
                        Text("\(SubscriptionManager.shared.freeOptimizationsUsed) / \(SubscriptionManager.freeOptimizationLimit)")
                            .foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("API calls today")
                        Spacer()
                        Text("\(UserDefaults.standard.integer(forKey: "apiCallsToday")) / 20")
                            .foregroundStyle(.secondary)
                    }
                    Text("Build: DEV")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                #endif

                Section {
                    HStack {
                        Text("settings.about.version", comment: "Settings: app version row label")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("settings.section.about", comment: "Settings section header for app metadata")
                }

                Section {
                    Button {
                        sendFeedback()
                    } label: {
                        Text("settings.support.feedback", comment: "Button: send feedback via mail")
                    }
                    Link(destination: URL(string: "https://bazilier.github.io/steadyeye-legal/privacy.html")!) {
                        Text("common.privacyPolicy", comment: "Privacy policy link in Settings")
                    }
                    Link(destination: URL(string: "https://bazilier.github.io/steadyeye-legal/terms.html")!) {
                        Text("common.termsOfUse", comment: "Terms of use link in Settings")
                    }
                } header: {
                    Text("settings.section.support", comment: "Settings section header for support and legal")
                }
            }
            .navigationTitle(Text("settings.title", comment: "Settings nav title"))
            #if DEV
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Text("DEV")
                        .font(.caption2.bold())
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.orange.opacity(0.2), in: Capsule())
                }
            }
            #endif
            .sheet(isPresented: $showPaywall) {
                PaywallView()
            }
        }
        .preferredColorScheme(.dark)
    }

    private func sendFeedback() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let iosVersion = UIDevice.current.systemVersion
        let device = DeviceDetectionService.shared.modelIdentifier
        let lang = Locale.current.language.languageCode?.identifier ?? "?"

        let body = "\n\n\n---\nApp version: \(appVersion)\niOS version: \(iosVersion)\nDevice: \(device)\nLanguage: \(lang)"
        let subject = String(
            localized: "settings.feedback.mailSubject",
            defaultValue: "SteadyEye Feedback",
            comment: "Mail subject for the Send Feedback button. 'SteadyEye' is the brand name and must not be translated."
        )
        let to = "heybazilier@gmail.com"

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body

        if let url = URL(string: "mailto:\(to)?subject=\(encodedSubject)&body=\(encodedBody)") {
            UIApplication.shared.open(url)
        }
    }
}
