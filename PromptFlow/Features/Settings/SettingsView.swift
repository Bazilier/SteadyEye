import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @Query private var settingsArray: [AppSettings]
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var subscriptionManager = SubscriptionManager.shared
    @AppStorage("videoResolution") private var videoResolution: String = "1080p"
    @AppStorage("videoFPS") private var videoFPS: Int = 30
    @AppStorage("dimDuringRecording") private var dimDuringRecording: Bool = true

    @AppStorage("stabilizationEnabled") private var stabilizationEnabled: Bool = true
    @AppStorage("autoStartPrompting") private var autoStartPrompting: Bool = true
    @AppStorage("useBluetoothMic") private var useBluetoothMic: Bool = false
    @AppStorage("orpAlignmentEnabled") private var orpAlignmentEnabled: Bool = true
    @AppStorage("orpHighlightAnchor") private var orpHighlightAnchor: Bool = true
    @State private var showPaywall = false
    @State private var paywallSource: String = "settings_preview"
    @State private var showUpgradePaywall = false
    @State private var isRestoring = false
    @State private var restoreSucceeded = false
    @State private var showRestoreAlert = false

    private var restoreResultTitle: String {
        restoreSucceeded
            ? String(
                localized: "settings.restore.success.title",
                defaultValue: "Subscription restored",
                comment: "Title of the alert shown when Restore Purchases finds an active subscription on the user's Apple ID."
            )
            : String(
                localized: "settings.restore.empty.title",
                defaultValue: "No purchases found",
                comment: "Title of the alert shown when Restore Purchases finds no active subscription on the user's Apple ID."
            )
    }

    private var restoreResultMessage: String {
        restoreSucceeded
            ? String(
                localized: "settings.restore.success.message",
                defaultValue: "Welcome back! Your subscription has been restored.",
                comment: "Body of the alert shown when Restore Purchases succeeds."
            )
            : String(
                localized: "settings.restore.empty.message",
                defaultValue: "Couldn't find an active subscription on your Apple ID.",
                comment: "Body of the alert shown when Restore Purchases finds no entitlement."
            )
    }

    private func restoreTapped() {
        Task {
            isRestoring = true
            let restored = await SubscriptionManager.shared.restorePurchases()
            isRestoring = false
            restoreSucceeded = restored
            showRestoreAlert = true
        }
    }

    private var settings: AppSettings {
        if let existing = settingsArray.first { return existing }
        let new = AppSettings()
        modelContext.insert(new)
        return new
    }

    var body: some View {
        NavigationStack {
            Form {
                // First section: Upgrade-to-Pro entry point. Hidden for Pro
                // users so Settings starts directly from the videoQuality
                // section in that case.
                if !subscriptionManager.isSubscribed {
                    Section {
                        Button(action: {
                            showUpgradePaywall = true
                        }) {
                            HStack {
                                Image(systemName: "crown.fill")
                                    .foregroundColor(.orange)
                                    .font(.system(size: 22))
                                    .frame(width: 30, alignment: .center)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(
                                        localized: "settings.upgrade.title",
                                        defaultValue: "Upgrade to Pro",
                                        comment: "Title of the Settings → Upgrade row that opens the paywall. Hidden for Pro users."
                                    ))
                                        .font(.body.weight(.semibold))
                                        .foregroundColor(.primary)
                                    Text(String(
                                        localized: "settings.upgrade.subtitle",
                                        defaultValue: "Unlock all features",
                                        comment: "Subtitle of the Settings → Upgrade row, one notch under the title."
                                    ))
                                        .font(.subheadline)
                                        .foregroundColor(.secondary)
                                }

                                Spacer()

                                Image(systemName: "chevron.right")
                                    .foregroundColor(.secondary.opacity(0.6))
                                    .font(.system(size: 14, weight: .semibold))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

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
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(isOn: $useBluetoothMic) {
                            Text("settings.allowBluetoothMics", comment: "Toggle: allow Bluetooth microphones (AirPods etc.) as audio input. Off by default because BT forces 16kHz HFP audio.")
                        }
                        Text("settings.allowBluetoothMics.footer", comment: "Helper text below the Bluetooth mic toggle, explaining why it's off by default and that wired mics are unaffected.")
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
                    Picker("Subscription Override", selection: $subscriptionManager.devSubscriptionOverride) {
                        Text("Off (use RC)").tag("off")
                        Text("Force Free").tag("free")
                        Text("Force Subscribed").tag("subscribed")
                    }
                    Text("DEV only. Forces isSubscribed state for testing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Preview Paywall") {
                        paywallSource = "settings_preview"
                        showPaywall = true
                    }
                    Button("Reset Tips") {
                        UserDefaults.standard.set(false, forKey: "hasSeenEditorTip")
                    }
                    Button("Reset Rate Limits") {
                        UserDefaults.standard.removeObject(forKey: "apiCallsToday")
                        UserDefaults.standard.removeObject(forKey: "bulkImportsToday")
                        UserDefaults.standard.removeObject(forKey: "rateLimitDate")
                    }
                    Button("Reset AI Optimize Day Limit") {
                        UserDefaults.standard.removeObject(forKey: "lastAIOptimizeDate")
                        SubscriptionManager.shared.lastAIOptimizeDateInterval = 0
                    }
                    Button("Reset Pro AI counter") {
                        UserDefaults.standard.removeObject(forKey: "proOptimizationsCount")
                        UserDefaults.standard.removeObject(forKey: "proOptimizationsResetDate")
                        SubscriptionManager.shared.proOptimizationsCount = 0
                    }
                    HStack {
                        Text("AI optimize used today")
                        Spacer()
                        Text(SubscriptionManager.shared.canOptimizeToday ? "no" : "yes")
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
                    Button(action: { restoreTapped() }) {
                        HStack {
                            Text(String(
                                localized: "settings.restore.button",
                                defaultValue: "Restore Purchases",
                                comment: "Settings button that triggers RevenueCat restorePurchases against the active Apple ID. Required by App Store review and used by users installing on a new device."
                            ))
                                .foregroundColor(.primary)
                            Spacer()
                            if isRestoring {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isRestoring)
                } header: {
                    Text(String(
                        localized: "settings.section.subscription",
                        defaultValue: "Subscription",
                        comment: "Settings section header for subscription-related actions (restore purchases, etc.)."
                    ))
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
            .fullScreenCover(isPresented: $showPaywall) {
                PaywallView(source: paywallSource)
            }
            .fullScreenCover(isPresented: $showUpgradePaywall) {
                PaywallView(source: "settings_upgrade_row")
            }
            .alert(restoreResultTitle, isPresented: $showRestoreAlert) {
                Button("common.ok", role: .cancel) {}
            } message: {
                Text(restoreResultMessage)
            }
            .onChange(of: videoResolution) { _, newValue in
                if newValue == "4k" && !subscriptionManager.canRecord4K {
                    videoResolution = "1080p"
                    paywallSource = "resolution_4k"
                    showPaywall = true
                }
            }
            .onChange(of: stabilizationEnabled) { _, newValue in
                if newValue && !subscriptionManager.canUseStabilization {
                    stabilizationEnabled = false
                    paywallSource = "stabilization"
                    showPaywall = true
                }
            }
            .onAppear {
                // Safeguard: if a previously-Pro user dropped to free with the
                // toggle stuck on, force it back to off so CameraManager doesn't
                // apply stabilization the next time they record.
                if !subscriptionManager.canUseStabilization && stabilizationEnabled {
                    stabilizationEnabled = false
                }
                // Same safeguard for 4K — without this, the Settings picker
                // shows "4K" selected and the recording HUD label shows
                // "4K · 30fps" even though CameraManager silently downgrades
                // captures to 1080p for free users.
                if !subscriptionManager.canRecord4K && videoResolution == "4k" {
                    videoResolution = "1080p"
                }
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
            UIApplication.shared.open(url, options: [:], completionHandler: nil)
        }
    }
}
