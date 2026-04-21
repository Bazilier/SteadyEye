import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @AppStorage("demoScriptCreated") private var demoScriptCreated = false

    var body: some View {
        TabView {
            ScriptListView()
                .tabItem {
                    Label {
                        Text("scripts.title", comment: "Scripts tab label / nav title")
                    } icon: {
                        Image(systemName: "doc.text.fill")
                    }
                }

            SettingsView()
                .tabItem {
                    Label {
                        Text("settings.title", comment: "Settings tab label / nav title")
                    } icon: {
                        Image(systemName: "gearshape.fill")
                    }
                }
        }
        .preferredColorScheme(.dark)
        .tint(.orange)
        .onAppear { createDemoScriptIfNeeded() }
    }

    private func createDemoScriptIfNeeded() {
        guard !demoScriptCreated else { return }
        // The original English demo title is intentionally hardcoded in the
        // existence-check predicate so users who already had the seeded English
        // demo on their device do not get a second copy after upgrading.
        let descriptor = FetchDescriptor<Script>(
            predicate: #Predicate { $0.title == "Demo Script" }
        )
        let existing = (try? modelContext.fetch(descriptor)) ?? []
        guard existing.isEmpty else { demoScriptCreated = true; return }

        let demoTitle = String(
            localized: "demo.script.title",
            defaultValue: "Demo Script",
            comment: "Title of the seeded demo script created on first launch."
        )
        let demoContent = String(
            localized: "demo.script.content",
            defaultValue: "Your landing page has 5 parts — and most people get the proportions WRONG!! Here's the formula: Headline (5% of page). Pain points — 15%. Benefits = 20%. Product — 40%. CTA — 20%. Most founders spend 80% on product & skip pain + benefits... That's why nobody converts!!!",
            comment: "Body of the seeded demo script created on first launch."
        )
        let demo = Script(
            title: demoTitle,
            content: demoContent
        )
        demo.isDemo = true
        modelContext.insert(demo)
        try? modelContext.save()
        demoScriptCreated = true
    }
}
