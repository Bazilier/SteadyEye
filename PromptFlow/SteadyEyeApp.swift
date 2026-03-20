import SwiftUI
import SwiftData

@main
struct SteadyEyeApp: App {
    @State private var container: ModelContainer?

    init() {
        cleanUpTempRecordings()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if let container {
                    ContentView()
                        .modelContainer(container)
                        .transition(.opacity)
                } else {
                    SplashView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: container != nil)
            .task {
                let schema = Schema([Script.self, AppSettings.self])
                let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
                do {
                    container = try ModelContainer(for: schema, configurations: [config])
                } catch {
                    fatalError("Could not create ModelContainer: \(error)")
                }
            }
        }
    }

    /// Remove leftover .mov files from tmp directory (e.g. force-quit during preview)
    private func cleanUpTempRecordings() {
        let tmpDir = FileManager.default.temporaryDirectory
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: tmpDir, includingPropertiesForKeys: nil
        ) else { return }
        for file in files where file.pathExtension == "mov" {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
