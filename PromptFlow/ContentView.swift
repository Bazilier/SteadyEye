import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var coachManager = CoachMarkManager.shared

    var body: some View {
        TabView {
            ScriptListView()
                .tabItem {
                    Label("Scripts", systemImage: "doc.text.fill")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gearshape.fill")
                }
        }
        .preferredColorScheme(.dark)
        .tint(.orange)
        .environmentObject(coachManager)
        .onAppear {
            createDemoScriptIfNeeded()
            coachManager.startIfNeeded()
        }
    }

    private func createDemoScriptIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: "hasSeenOnboarding") else { return }
        let descriptor = FetchDescriptor<Script>(
            predicate: #Predicate { $0.title == "Demo Script" }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        guard existing.isEmpty else { return }

        let demo = Script(
            title: "Demo Script",
            content: "Your landing page has 5 parts — and most people get the proportions WRONG!! Here's the formula: Headline (5% of page). Pain points — 15%. Benefits = 20%. Product — 40%. CTA — 20%. Most founders spend 80% on product & skip pain + benefits... That's why nobody converts!!!"
        )
        modelContext.insert(demo)
        try? modelContext.save()
    }
}
