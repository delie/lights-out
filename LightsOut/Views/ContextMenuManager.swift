import AppKit

class ContextMenuManager {
    private let updateService: AppUpdateService
    private weak var statusItem: NSStatusItem?

    init(updateService: AppUpdateService, statusItem: NSStatusItem) {
        self.updateService = updateService
        self.statusItem = statusItem
    }

    func showContextMenu() {
        guard let statusItem = statusItem else { return }
        
        let menu = NSMenu()

        let checkForUpdatesItem = NSMenuItem(
            title: "Check for New Version",
            action: #selector(checkForNewVersion),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        if let releasesPageURL = updateService.releasesPageURL {
            let openReleasesItem = NSMenuItem(
                title: "Open Releases Page",
                action: #selector(openReleasesPage),
                keyEquivalent: ""
            )
            openReleasesItem.target = self
            openReleasesItem.representedObject = releasesPageURL
            menu.addItem(openReleasesItem)
        }

        menu.addItem(NSMenuItem.separator())

        menu.addItem(NSMenuItem(
            title: "Quit LightsOut",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        ))

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func checkForNewVersion() {
        Task { @MainActor in
            await updateService.refresh()
            presentUpdateStatus()
        }
    }

    @objc private func openReleasesPage(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        NSWorkspace.shared.open(url)
    }

    private func presentUpdateStatus() {
        let alert = NSAlert()
        alert.alertStyle = .informational

        switch updateService.status {
        case .idle, .checking:
            return
        case let .upToDate(currentVersion):
            alert.messageText = "LightsOut is up to date"
            alert.informativeText = "Version \(currentVersion) is the newest release currently published."
            alert.addButton(withTitle: "OK")
        case let .updateAvailable(currentVersion, latestVersion, releaseURL):
            alert.messageText = "A newer version is available"
            alert.informativeText = "You have \(currentVersion). GitHub currently shows \(latestVersion)."
            alert.addButton(withTitle: "Open Release Page")
            alert.addButton(withTitle: "Cancel")

            if alert.runModal() == .alertFirstButtonReturn {
                NSWorkspace.shared.open(releaseURL)
            }

            return
        case let .unavailable(message):
            alert.messageText = "Could not check for a newer version"
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
        }

        alert.runModal()
    }
}
