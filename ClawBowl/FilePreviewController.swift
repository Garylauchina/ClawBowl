import QuickLook
import SwiftUI
import UIKit

// MARK: - QLPreview (SwiftUI wrapper)

/// SwiftUI wrapper for QLPreviewController — previews any file type iOS supports
struct FilePreviewSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UINavigationController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        let nav = UINavigationController(rootViewController: controller)
        return nav
    }

    func updateUIViewController(_ uiViewController: UINavigationController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(url: url)
    }

    class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL

        init(url: URL) {
            self.url = url
        }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem {
            url as QLPreviewItem
        }
    }
}

// MARK: - Share Sheet (UIActivityViewController wrapper)

/// SwiftUI wrapper for UIActivityViewController — share/save files
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
