import Combine
import CoreGraphics
import SwiftUI

@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ cid: CGDisplayConfigRef, _ display: UInt32, _ enabled: Bool) -> Int

class DisplaysViewModel: ObservableObject {
    private enum PersistenceKeys {
        static let disabledDisplayIDsForRecovery = "DisabledDisplayIDsForRecovery"
    }

    @Published var displays: [DisplayInfo] = []
    @Published var busyDisplayIDs: Set<CGDirectDisplayID> = []
    private let defaults: UserDefaults
    private var displayCancellables: Set<AnyCancellable> = []

    /// Called before display configuration changes. Pass the set of display IDs being hidden (empty for show operations).
    var willChangeDisplays: ((_ disablingDisplayIDs: Set<CGDirectDisplayID>) -> Void)?
    /// Called after display configuration changes complete.
    var didChangeDisplays: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fetchDisplays()
    }
    
    func fetchDisplays() {
        var activeDisplayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &activeDisplayCount)
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(activeDisplayCount))
        CGGetActiveDisplayList(activeDisplayCount, &activeDisplays, &activeDisplayCount)

        var onlineDisplayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineDisplayCount)
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(onlineDisplayCount))
        CGGetOnlineDisplayList(onlineDisplayCount, &onlineDisplays, &onlineDisplayCount)
        
        var newDisplays: Set<DisplayInfo> = []
        let primaryDisplayID = CGMainDisplayID()
        let activeDisplaySet = Set(activeDisplays.prefix(Int(activeDisplayCount)))
        let existingByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })

        newDisplays = Set(onlineDisplays.prefix(Int(onlineDisplayCount)).compactMap { displayID in
            var displayName = "Display \(displayID)"
            if let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
                displayName = screen.localizedName
            }
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0

            let state: DisplayState = activeDisplaySet.contains(displayID) ? .active : .disconnected

            // Reuse existing object if possible to preserve @ObservedObject references
            if let existing = existingByID[displayID] {
                existing.state = state
                existing.isPrimary = displayID == primaryDisplayID
                return existing
            }

            return DisplayInfo(
                id: displayID,
                name: displayName,
                state: state,
                isPrimary: displayID == primaryDisplayID,
                isBuiltIn: isBuiltIn
            )
        })

        // Ensuring the off/pending displays are not "deleted" - manually adding them to the new list.
        for display in displays {
            if display.state.isOff() || display.state == .pending {
                display.isPrimary = false
                newDisplays.insert(display)
            }
        }
        
        displays = Array(newDisplays)
        
        displays.sort {
            if $0.isPrimary {
                return true
            }
            if $1.isPrimary {
                return false
            }
            return $0.id < $1.id
        }
        
        subscribeToDisplayChanges()
    }
    
    func disconnectDisplay(display: DisplayInfo) throws(DisplayError) {
        guard canDisable(display: display) else {
            throw DisplayError(msg: "At least one display must remain visible.")
        }

        display.state = .pending
        willChangeDisplays?([display.id])

        var cid: CGDisplayConfigRef?
        let beginStatus = CGBeginDisplayConfiguration(&cid)

        guard beginStatus == .success, let config = cid else {
            throw DisplayError(msg: "Failed to begin configuring '\(display.name)'.")
        }

        let status = CGSConfigureDisplayEnabled(config, display.id, false)
        guard status == 0 else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError(msg: "Failed to hide '\(display.name)'.")
        }

        let completeStatus = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard completeStatus == .success else {
            throw DisplayError(msg: "Failed to finish configuring '\(display.name)'.")
        }

        display.state = .disconnected
        persistDisabledDisplayIDForRecovery(display.id)
        didChangeDisplays?()
    }
    
    func turnOnDisplay(display: DisplayInfo) throws(DisplayError) {
        if display.state == .disconnected {
            try reconnectDisplay(display: display)
        }
    }
    
    func resetAllDisplays() {
        for display in displays {
            try? turnOnDisplay(display: display)
        }
        CGDisplayRestoreColorSyncSettings()
        CGRestorePermanentDisplayConfiguration()
        clearDisabledDisplayIDsForRecovery()

        fetchDisplays()
    }

    func recoverDisabledDisplaysFromPreviousSessionIfNeeded() {
        let disabledDisplayIDs = loadDisabledDisplayIDsForRecovery()
        guard !disabledDisplayIDs.isEmpty else { return }

        for displayID in disabledDisplayIDs {
            try? reconnectDisplay(displayID: displayID)
        }

        clearDisabledDisplayIDsForRecovery()
        fetchDisplays()
    }
    
    func notifyChange() {
        displays = displays
    }

    func markDisplaysBusy(_ displayIDs: Set<CGDirectDisplayID>) {
        busyDisplayIDs.formUnion(displayIDs)
    }

    func clearDisplaysBusy(_ displayIDs: Set<CGDirectDisplayID>) {
        busyDisplayIDs.subtract(displayIDs)
    }

    private func subscribeToDisplayChanges() {
        displayCancellables.removeAll()
        for display in displays {
            display.objectWillChange
                .sink { [weak self] _ in
                    DispatchQueue.main.async {
                        self?.objectWillChange.send()
                    }
                }
                .store(in: &displayCancellables)
        }
    }
}

extension DisplaysViewModel {
    fileprivate func reconnectDisplay(display: DisplayInfo) throws(DisplayError) {
        willChangeDisplays?([])

        var cid: CGDisplayConfigRef?
        let beginStatus = CGBeginDisplayConfiguration(&cid)
        guard beginStatus == .success, let config = cid else {
            throw DisplayError(
                msg: "Failed to begin configuration for '\(display.name)'."
            )
        }

        let status = CGSConfigureDisplayEnabled(config, display.id, true)
        guard status == 0 else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError(
                msg: "Failed to show '\(display.name)'."
            )
        }

        let completeStatus = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard completeStatus == .success else {
            throw DisplayError(
                msg: "Failed to complete configuration for '\(display.name)'.")
        }

        display.state = .active
        removeDisabledDisplayIDForRecovery(display.id)
        didChangeDisplays?()
        fetchDisplays()
    }

    fileprivate func reconnectDisplay(displayID: CGDirectDisplayID) throws {
        willChangeDisplays?([])

        var cid: CGDisplayConfigRef?
        let beginStatus = CGBeginDisplayConfiguration(&cid)
        guard beginStatus == .success, let config = cid else {
            throw DisplayError(msg: "Failed to begin configuration for display \(displayID).")
        }

        let status = CGSConfigureDisplayEnabled(config, displayID, true)
        guard status == 0 else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError(msg: "Failed to show display \(displayID).")
        }

        let completeStatus = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard completeStatus == .success else {
            throw DisplayError(msg: "Failed to complete configuration for display \(displayID).")
        }

        removeDisabledDisplayIDForRecovery(displayID)
        didChangeDisplays?()
    }

    private func canDisable(display: DisplayInfo) -> Bool {
        guard display.state == .active else {
            return false
        }

        let activeCount = displays.filter { $0.state == .active }.count
        return activeCount > 1
    }

    private func loadDisabledDisplayIDsForRecovery() -> Set<CGDirectDisplayID> {
        let rawValues = defaults.array(forKey: PersistenceKeys.disabledDisplayIDsForRecovery) as? [Int] ?? []
        return Set(rawValues.map(CGDirectDisplayID.init))
    }

    private func persistDisabledDisplayIDForRecovery(_ displayID: CGDirectDisplayID) {
        var disabledDisplayIDs = loadDisabledDisplayIDsForRecovery()
        disabledDisplayIDs.insert(displayID)
        defaults.set(disabledDisplayIDs.map(Int.init), forKey: PersistenceKeys.disabledDisplayIDsForRecovery)
    }

    private func removeDisabledDisplayIDForRecovery(_ displayID: CGDirectDisplayID) {
        var disabledDisplayIDs = loadDisabledDisplayIDsForRecovery()
        disabledDisplayIDs.remove(displayID)
        defaults.set(disabledDisplayIDs.map(Int.init), forKey: PersistenceKeys.disabledDisplayIDsForRecovery)
    }

    private func clearDisabledDisplayIDsForRecovery() {
        defaults.removeObject(forKey: PersistenceKeys.disabledDisplayIDsForRecovery)
    }

}

// MARK: - NSScreen Extension

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? CGDirectDisplayID) ?? 0
    }
}
