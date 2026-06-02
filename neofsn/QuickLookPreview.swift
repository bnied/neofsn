import AppKit
import Quartz

/// Shared bridge to the system Quick Look panel for previewing a single file URL.
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookPreview()
    private var url: URL?

    /// Show (or update) the shared Quick Look panel previewing `url`.
    func preview(url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.delegate = self
        panel.reloadData()
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// QLPreviewPanelDataSource: one item when a URL is set, else none.
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }

    /// QLPreviewPanelDataSource: the URL being previewed (URL conforms to QLPreviewItem).
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        url as QLPreviewItem?
    }
}
