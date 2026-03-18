import SwiftUI
import SwiftData

@main
struct PromptFlowApp: App {
    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Script.self,
            AppSettings.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)
        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    init() {
        cleanUpTempRecordings()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
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
