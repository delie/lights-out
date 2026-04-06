import SwiftUI
import AppKit

private final class MenuPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@main
struct LightsOutApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    private var menuPanel: MenuPanel?
    var eventMonitor: Any?
    var screenParametersObserver: Any?
    let displaysViewModel = DisplaysViewModel()
    var contextMenuManager: ContextMenuManager!
    private var preservedPopoverState: PreservedPopoverState?

    private struct PreservedPopoverState {
        let displayID: CGDirectDisplayID
        let originOffset: NSPoint
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Set up the status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: "LightsOut")
            button.action = #selector(handleClick(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        contextMenuManager = ContextMenuManager(statusItem: statusItem)

        eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            if self?.menuPanel?.isVisible == true {
                self?.closeMenuPanel()
            }
        }

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.restorePopoverPositionIfNeeded()
        }

        displaysViewModel.willChangeDisplays = { [weak self] disablingDisplayIDs in
            self?.preparePopoverForDisplayChange(disablingDisplayIDs: disablingDisplayIDs)
        }

        displaysViewModel.didChangeDisplays = { [weak self] in
            self?.restorePopoverPositionIfNeeded()
            DispatchQueue.main.async { [weak self] in
                self?.restorePopoverPositionIfNeeded()
            }
        }

        displaysViewModel.recoverDisabledDisplaysFromPreviousSessionIfNeeded()
    }

    func applicationWillTerminate(_ notification: Notification) {
        displaysViewModel.resetAllDisplays()
    }

    @objc func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            contextMenuManager.showContextMenu()
        } else {
            toggleMenuPanel(sender)
        }
    }

    func toggleMenuPanel(_ sender: NSStatusBarButton) {
        if menuPanel?.isVisible == true {
            closeMenuPanel()
        } else {
            showMenuPanel(anchoredTo: sender)
        }
    }

    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    private func preparePopoverForDisplayChange(disablingDisplayIDs: Set<CGDirectDisplayID>) {
        guard let menuPanel,
              menuPanel.isVisible,
              let screen = menuPanel.screen else {
            preservedPopoverState = nil
            return
        }

        let displayID = screen.displayID
        if disablingDisplayIDs.contains(displayID) {
            closeMenuPanel()
            preservedPopoverState = nil
            return
        }

        preservedPopoverState = PreservedPopoverState(
            displayID: displayID,
            originOffset: NSPoint(
                x: menuPanel.frame.origin.x - screen.frame.origin.x,
                y: menuPanel.frame.origin.y - screen.frame.origin.y
            )
        )
    }

    private func restorePopoverPositionIfNeeded() {
        guard let menuPanel,
              menuPanel.isVisible,
              let preservedPopoverState,
              let screen = NSScreen.screens.first(where: { $0.displayID == preservedPopoverState.displayID }) else {
            self.preservedPopoverState = nil
            return
        }

        let desiredOrigin = NSPoint(
            x: screen.frame.origin.x + preservedPopoverState.originOffset.x,
            y: screen.frame.origin.y + preservedPopoverState.originOffset.y
        )

        guard menuPanel.frame.origin != desiredOrigin else { return }

        var frame = menuPanel.frame
        frame.origin = desiredOrigin
        menuPanel.setFrame(frame, display: false)
        menuPanel.orderFrontRegardless()
    }

    private func showMenuPanel(anchoredTo button: NSStatusBarButton) {
        let contentView = MenuBarView()
            .environmentObject(displaysViewModel)
            .withErrorHandling()

        let hostingController = NSHostingController(rootView: contentView)
        hostingController.loadView()
        hostingController.view.layoutSubtreeIfNeeded()
        hostingController.view.wantsLayer = true
        hostingController.view.layer?.backgroundColor = NSColor.clear.cgColor

        let fittingSize = hostingController.view.fittingSize
        let panelSize = NSSize(
            width: max(372, fittingSize.width),
            height: max(240, fittingSize.height)
        )

        let panel = MenuPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.contentViewController = hostingController
        panel.contentView?.wantsLayer = true
        panel.contentView?.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView?.layer?.cornerRadius = 24
        panel.contentView?.layer?.cornerCurve = .continuous
        panel.contentView?.layer?.masksToBounds = true
        panel.invalidateShadow()
        panel.setFrameOrigin(panelOrigin(for: button, panelSize: panelSize))

        menuPanel = panel

        NSApp.activate(ignoringOtherApps: true)
        panel.orderFrontRegardless()
        panel.makeKey()
        preservedPopoverState = nil
    }

    private func closeMenuPanel() {
        menuPanel?.orderOut(nil)
        menuPanel?.close()
        menuPanel = nil
        preservedPopoverState = nil
    }

    private func panelOrigin(for button: NSStatusBarButton, panelSize: NSSize) -> NSPoint {
        let mouseLocation = NSEvent.mouseLocation
        let fallbackScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) })
            ?? button.window?.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first

        let buttonRectOnScreen: NSRect
        if let window = button.window {
            let rectInWindow = button.convert(button.bounds, to: nil)
            buttonRectOnScreen = window.convertToScreen(rectInWindow)
        } else if let screen = fallbackScreen {
            let visibleFrame = screen.visibleFrame
            buttonRectOnScreen = NSRect(
                x: visibleFrame.midX - 10,
                y: visibleFrame.maxY - 4,
                width: 20,
                height: 4
            )
        } else {
            buttonRectOnScreen = NSRect(x: 0, y: 0, width: 20, height: 4)
        }

        let screen = fallbackScreen ?? NSScreen.screens.first
        let visibleFrame = screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
        let preferredOrigin = NSPoint(
            x: buttonRectOnScreen.midX - (panelSize.width / 2),
            y: buttonRectOnScreen.minY - panelSize.height - 6
        )

        return NSPoint(
            x: min(max(preferredOrigin.x, visibleFrame.minX), visibleFrame.maxX - panelSize.width),
            y: min(max(preferredOrigin.y, visibleFrame.minY), visibleFrame.maxY - panelSize.height)
        )
    }
}

#Preview {
    MenuBarView()
        .environmentObject(DisplaysViewModel())
}
