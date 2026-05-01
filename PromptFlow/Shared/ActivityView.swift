import SwiftUI
import UIKit

/// Lightweight wrapper around UIActivityViewController for SwiftUI sheets.
/// Used by the Recordings tab's Share context-menu action.
struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
