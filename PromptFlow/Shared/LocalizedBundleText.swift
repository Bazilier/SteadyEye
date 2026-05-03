import Foundation

/// Loader for long-form localized text bundled as `.txt` resources.
/// Used for multi-paragraph content that doesn't belong in the String
/// Catalog (which is best for short UI labels).
///
/// Source layout: `Resources/<SubdirName>/<name>.<lang>.txt` — flat
/// directory, locale-suffixed filenames (e.g.
/// `DemoPrefillText.en.txt`, `DemoEditorBefore.es-419.txt`). Each file
/// gets a unique base name, so Xcode 16's file-system synchronized
/// root group bundles them without collisions and the resource-copy
/// phase flattens them into the .app root: `<App>.app/<name>.<lang>.txt`.
///
/// We deliberately do NOT use `.lproj` subdirectories here. Xcode 16's
/// IDE incremental builds drop `.lproj` files added on disk if the
/// editor session was open at the time the files were created — only
/// CLI `xcodebuild` reliably picks them up. The flat naming pattern
/// matches `SplitPrompt.txt` / `FormatPrompt.txt`, which load
/// reliably across both build paths.
///
/// The `subdirectory` parameter on `load(_:subdirectory:)` is supplied
/// for organizational clarity at the call site (and for future-proofing
/// against any Xcode behavior change that DOES preserve subdirectories
/// in the bundle). At runtime, `Bundle.main.url(...)` is queried both
/// with and without the subdirectory hint; if the file is at the
/// bundle root (the current observed behavior), the flat lookup
/// succeeds and the subdirectory hint becomes a documentation-only
/// label.
enum DemoContent {
    /// Returns the contents of `<name>.<preferred-lang>.txt`.
    /// Tries `subdirectory` if provided, then falls back to the bundle
    /// root. Falls through to the English copy when the user's preferred
    /// locale isn't supported. Returns `""` and logs a warning if all
    /// lookups fail — the demo flow degrades to an empty TextEditor /
    /// blank Script content rather than crashing the app.
    static func load(_ name: String, subdirectory: String? = nil) -> String {
        let lang = preferredLanguage()
        let suffixed = "\(name).\(lang)"
        if let text = lookup(resource: suffixed, subdirectory: subdirectory) {
            return text
        }
        if lang != "en", let text = lookup(resource: "\(name).en", subdirectory: subdirectory) {
            return text
        }
        print("⚠️ DemoContent: missing resource \(name).<lang>.txt (subdirectory: \(subdirectory ?? "nil"), preferred lang: \(lang), preferredLocalizations: \(Bundle.main.preferredLocalizations))")
        return ""
    }

    /// Tries `subdirectory` first, then bundle-root flat lookup. nil
    /// when neither path resolves OR the file exists but can't be read
    /// as UTF-8.
    private static func lookup(resource: String, subdirectory: String?) -> String? {
        if let subdirectory,
           let url = Bundle.main.url(
            forResource: resource,
            withExtension: "txt",
            subdirectory: subdirectory
           ),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        if let url = Bundle.main.url(forResource: resource, withExtension: "txt"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return nil
    }

    /// Maps the device's preferred locale chain to one of our four
    /// supported languages, with a coarse prefix-based fallback for
    /// unsupported locales (e.g. `es-MX` → `es-419`, `pt-PT` → `pt-BR`,
    /// `fr-FR` → `en`).
    private static func preferredLanguage() -> String {
        let supported: Set<String> = ["en", "es-419", "pt-BR", "ru"]
        let preferred = Bundle.main.preferredLocalizations
        for lang in preferred where supported.contains(lang) {
            return lang
        }
        for lang in preferred {
            if lang.hasPrefix("es") { return "es-419" }
            if lang.hasPrefix("pt") { return "pt-BR" }
            if lang.hasPrefix("ru") { return "ru" }
        }
        return "en"
    }
}
