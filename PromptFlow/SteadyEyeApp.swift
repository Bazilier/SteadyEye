import SwiftUI
import SwiftData

@main
struct SteadyEyeApp: App {
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

    @State private var isReady = false

    init() {
        cleanUpTempRecordings()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                if isReady {
                    ContentView()
                        .transition(.opacity)
                } else {
                    SplashView()
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: isReady)
            .task {
                // Model container is already initialized above;
                // mark ready once the main view can appear.
                isReady = true
            }
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
