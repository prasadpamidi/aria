import Foundation
import SwiftUI
import UIKit

// MARK: - SessionShareItem

/// Identifiable wrapper around a session-bundle URL so SwiftUI's
/// `.sheet(item:content:)` can present `ShareSheet` programmatically.
struct SessionShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

// MARK: - ShareSheet

/// Thin SwiftUI wrapper around `UIActivityViewController`. Used to
/// present the iOS share sheet for arbitrary items (file URLs, text,
/// etc.). SwiftUI's `ShareLink` is suited for static content; for
/// dynamically-generated bundles a programmatic share controller
/// composes more naturally with `.sheet(item:)`.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context _: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: self.items, applicationActivities: nil)
    }

    func updateUIViewController(_: UIActivityViewController, context _: Context) { }
}
