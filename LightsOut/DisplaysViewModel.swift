import CoreGraphics
import SwiftUI

@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ cid: CGDisplayConfigRef, _ display: UInt32, _ enabled: Bool) -> Int

class DisplaysViewModel: ObservableObject {
    private enum PersistenceKeys {
        static let disconnectedDisplayIDs = "DisconnectedDisplayIDs"
    }

    @Published var displays: [DisplayInfo] = []
    private var gammaService = GammaUpdateService()
    private var arrangementCache = DisplayArrangementCacheService()
    private let defaults: UserDefaults
    
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fetchDisplays()
    }

    func recoverDisplaysAfterLaunch() {
        fetchDisplays()
        applyPersistedDisconnectedDisplaysIfPossible()
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
        let persistedDisconnectedDisplayIDs = loadDisconnectedDisplayIDs()

        newDisplays = Set(onlineDisplays.prefix(Int(onlineDisplayCount)).compactMap { displayID in
            var displayName = "Display \(displayID)"
            if let screen = NSScreen.screens.first(where: { $0.displayID == displayID }) {
                displayName = screen.localizedName
            }

            let state: DisplayState = activeDisplaySet.contains(displayID) ? .active : .disconnected

            return DisplayInfo(
                id: displayID,
                name: displayName,
                state: state,
                isPrimary: displayID == primaryDisplayID
            )
        })

        for displayID in persistedDisconnectedDisplayIDs where !newDisplays.contains(where: { $0.id == displayID }) {
            newDisplays.insert(
                DisplayInfo(
                    id: displayID,
                    name: "Display \(displayID)",
                    state: .disconnected,
                    isPrimary: false
                )
            )
        }
        
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
        
        try? arrangementCache.cache()
    }
    
    func disconnectDisplay(display: DisplayInfo) throws(DisplayError) {
        guard canDisable(display: display) else {
            throw DisplayError(msg: "At least one display must remain enabled.")
        }

        display.state = .pending
        var cid: CGDisplayConfigRef?
        let beginStatus = CGBeginDisplayConfiguration(&cid)
        
        guard beginStatus == .success, let config = cid else {
            throw DisplayError(msg: "Failed to begin configuring '\(display.name)'.")
        }
        
        let status = CGSConfigureDisplayEnabled(config, display.id, false)
        guard status == 0 else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError(msg: "Failed to disconnect '\(display.name)'.")
        }
        
        let completeStatus = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard completeStatus == .success else {
            throw DisplayError(msg: "Failed to finish configuring '\(display.name)'.")
        }
        
        display.state = .disconnected
        persistDisconnected(displayID: display.id)
        unRegisterMirrors(display: display)
    }

    
    func disableDisplay(display: DisplayInfo) throws(DisplayError) {
        guard canDisable(display: display) else {
            throw DisplayError(msg: "At least one display must remain enabled.")
        }

        display.state = .pending
        
        
        do {
            try mirrorDisplay(display)
            gammaService.setZeroGamma(for: display)
        } catch {
            throw DisplayError(msg: "Failed to apply a mirror-based disable to '\(display.name)'.")
        }
        unRegisterMirrors(display: display)
    }
    
    func turnOnDisplay(display: DisplayInfo) throws(DisplayError) {
        switch display.state {
        case .disconnected:
            try reconnectDisplay(display: display)
        case .mirrored:
            try enableDisplay(display: display)
        default:
            break
        }
    }
    
    func resetAllDisplays(clearPersistedState: Bool = true) {
        let persistedDisconnectedDisplayIDs = loadDisconnectedDisplayIDs()

        for display in displays {
            try? turnOnDisplay(display: display)
        }
        CGDisplayRestoreColorSyncSettings()
        CGRestorePermanentDisplayConfiguration()

        if clearPersistedState {
            defaults.removeObject(forKey: PersistenceKeys.disconnectedDisplayIDs)
        } else {
            defaults.set(persistedDisconnectedDisplayIDs.map(Int.init), forKey: PersistenceKeys.disconnectedDisplayIDs)
        }

        fetchDisplays()
    }
    
    func unRegisterMirrors(display: DisplayInfo) {
        for mirror in display.mirroredTo {
            mirror.state = .active
        }
    }
    
}

// MARK: - TurnOn logic

extension DisplaysViewModel {
    fileprivate func reconnectDisplay(display: DisplayInfo) throws(DisplayError) {
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
                msg: "Failed to reconnect '\(display.name)'."
            )
        }
        
        let completeStatus = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard completeStatus == .success else {
            throw DisplayError(
                msg: "Failed to complete configuration for '\(display.name)'.")
        }
        
        display.state = .active
        removePersistedDisconnected(displayID: display.id)
        fetchDisplays()
    }
    
    fileprivate func enableDisplay(display: DisplayInfo) throws(DisplayError) {
        gammaService.restoreGamma(for: display)
        
        do {
            try unmirrorDisplay(display)
            try arrangementCache.restore()
        } catch {
            throw DisplayError(
                msg: "Failed to enable '\(display.name)'."
            )
        }
        
        display.state = .active
    }
}

// MARK: - Mirroring Extension

extension DisplaysViewModel {
    fileprivate func mirrorDisplay(_ display: DisplayInfo) throws {
        let targetDisplayID = display.id
        
        guard let alternateDisplay = selectAlternateDisplay(excluding: targetDisplayID) else {
            throw DisplayError(msg: "No suitable alternate display found for mirroring.")
        }
        
        var configRef: CGDisplayConfigRef?
        let beginConfigError = CGBeginDisplayConfiguration(&configRef)
        guard beginConfigError == .success, let config = configRef else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(beginConfigError.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "Failed to begin display configuration."
            ])
        }
        
        let mirrorError = CGConfigureDisplayMirrorOfDisplay(config, targetDisplayID, alternateDisplay.id)
        guard mirrorError == .success else {
            CGCancelDisplayConfiguration(config)
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(mirrorError.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "Failed to mirror display \(alternateDisplay.name) to display \(display.name)."
            ])
        }
        
        let completeConfigError = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard completeConfigError == .success else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(completeConfigError.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "Failed to complete display configuration."
            ])
        }
        
        alternateDisplay.mirroredTo.append(display)
    }
    
    fileprivate func unmirrorDisplay(_ display: DisplayInfo) throws {
        var configRef: CGDisplayConfigRef?
        let beginConfigError = CGBeginDisplayConfiguration(&configRef)
        guard beginConfigError == .success, let config = configRef else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(beginConfigError.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Failed to begin display configuration."]
            )
        }

        let unmirrorError = CGConfigureDisplayMirrorOfDisplay(config, display.id, kCGNullDirectDisplay)
        guard unmirrorError == .success else {
            CGCancelDisplayConfiguration(config)
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(unmirrorError.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Failed to unmirror display \(display.name)."]
            )
        }

        let completeConfigError = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard completeConfigError == .success else {
            throw NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(completeConfigError.rawValue),
                userInfo: [NSLocalizedDescriptionKey: "Failed to complete display configuration."]
            )
        }

        if let source = display.mirrorSource,
           let index = source.mirroredTo.firstIndex(of: display) {
            source.mirroredTo.remove(at: index)
        }
    }
    
    private func selectAlternateDisplay(excluding currentDisplayID: CGDirectDisplayID) -> DisplayInfo? {
        return displays.first { $0.id != currentDisplayID && $0.state == .active}
    }

    private func canDisable(display: DisplayInfo) -> Bool {
        guard display.state == .active else {
            return false
        }

        let activeCount = displays.filter { $0.state == .active }.count
        return activeCount > 1
    }

    private func loadDisconnectedDisplayIDs() -> Set<CGDirectDisplayID> {
        let rawValues = defaults.array(forKey: PersistenceKeys.disconnectedDisplayIDs) as? [Int] ?? []
        return Set(rawValues.map(CGDirectDisplayID.init))
    }

    private func persistDisconnected(displayID: CGDirectDisplayID) {
        var disconnectedDisplayIDs = loadDisconnectedDisplayIDs()
        disconnectedDisplayIDs.insert(displayID)
        defaults.set(disconnectedDisplayIDs.map(Int.init), forKey: PersistenceKeys.disconnectedDisplayIDs)
    }

    private func removePersistedDisconnected(displayID: CGDirectDisplayID) {
        var disconnectedDisplayIDs = loadDisconnectedDisplayIDs()
        disconnectedDisplayIDs.remove(displayID)
        defaults.set(disconnectedDisplayIDs.map(Int.init), forKey: PersistenceKeys.disconnectedDisplayIDs)
    }

    private func applyPersistedDisconnectedDisplaysIfPossible() {
        let persistedDisconnectedDisplayIDs = loadDisconnectedDisplayIDs()
        guard !persistedDisconnectedDisplayIDs.isEmpty else {
            return
        }

        let eligibleDisplays = displays.filter {
            $0.state == .active && persistedDisconnectedDisplayIDs.contains($0.id)
        }

        let activeCount = displays.filter { $0.state == .active }.count

        guard activeCount - eligibleDisplays.count >= 1 else {
            resetAllDisplays()
            return
        }

        for display in eligibleDisplays {
            do {
                try disconnectDisplay(display: display)
            } catch {
                resetAllDisplays()
                return
            }
        }
    }
}

// MARK: - NSScreen Extension

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? CGDirectDisplayID) ?? 0
    }
}
