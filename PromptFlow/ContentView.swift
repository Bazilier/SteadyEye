import SwiftUI

struct ContentView: View {
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
    }
}
