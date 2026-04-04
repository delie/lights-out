import AppKit

class ContextMenuManager {
    private weak var statusItem: NSStatusItem?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
    }

    func showContextMenu() {
        let menu = NSMenu()
        menu.addItem(NSMenuItem(
            title: "Quit LightsOut",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))
        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func openReleasesPage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }
}
