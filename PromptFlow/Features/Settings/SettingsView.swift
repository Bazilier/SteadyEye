import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @Query private var settingsArray: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @AppStorage("videoResolution") private var videoResolution: String = "1080p"
    @AppStorage("videoFPS") private var videoFPS: Int = 30
    @AppStorage("dimDuringRecording") private var dimDuringRecording: Bool = true
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

                #if DEV
                Section("Debug") {
                    Button("Preview Paywall") { showPaywall = true }
                    Button("Reset Onboarding") {
                        UserDefaults.standard.set(false, forKey: "hasSeenOnboarding")
                    }
                    Button("Reset Rate Limits") {
                        UserDefaults.standard.removeObject(forKey: "apiCallsToday")
                        UserDefaults.standard.removeObject(forKey: "bulkImportsToday")
                        UserDefaults.standard.removeObject(forKey: "rateLimitDate")
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

                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Support & Legal") {
                    Button("Send Feedback") {
                        sendFeedback()
                    }
                    Link("Privacy Policy", destination: URL(string: "https://bazilier.github.io/steadyeye-legal/privacy.html")!)
                    Link("Terms of Use", destination: URL(string: "https://bazilier.github.io/steadyeye-legal/terms.html")!)
                }
            }
            .navigationTitle("Settings")
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
        let subject = "SteadyEye Feedback"
        let to = "heybazilier@gmail.com"

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body

        if let url = URL(string: "mailto:\(to)?subject=\(encodedSubject)&body=\(encodedBody)") {
            UIApplication.shared.open(url)
        }
    }
}
