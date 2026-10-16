import Foundation

/// A label for DEV and debug-only tools. These are English-only and must stay
/// out of the string catalog: Xcode adds every `LocalizedStringKey` literal it
/// compiles to `Localizable.xcstrings`, and a Prod build — which leaves
/// `#if DEV` / `#if DEBUG` code out — then deletes them again, so the catalog
/// churned with every build of the other configuration. A plain `String`
/// is never extracted.
///
/// In DEV and debug-only code: `Text(verbatim:)` for text, `devLabel(_:)`
/// for the titles of `Button`, `Toggle`, `Section`, `Picker`, `.alert` and
/// the like. User-facing strings still go through `String(localized:)`.
func devLabel(_ text: String) -> String { text }
