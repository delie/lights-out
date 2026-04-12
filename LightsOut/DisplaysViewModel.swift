import Combine
import CoreGraphics
import Darwin
import IOKit
import IOKit.graphics
import IOKit.i2c
import SwiftUI

@_silgen_name("CGSConfigureDisplayEnabled")
func CGSConfigureDisplayEnabled(_ cid: CGDisplayConfigRef, _ display: UInt32, _ enabled: Bool) -> Int

@_silgen_name("CGSServiceForDisplayNumber")
func CGSServiceForDisplayNumber(_ display: CGDirectDisplayID, _ service: UnsafeMutablePointer<io_service_t>?)

class DisplaysViewModel: ObservableObject {
    private typealias CGDisplayIOServicePortFunction = @convention(c) (CGDirectDisplayID) -> io_service_t
    fileprivate typealias IOAVServiceRef = CFTypeRef
    fileprivate typealias IOAVServiceCreateWithServiceFunction = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    fileprivate typealias IOAVServiceCopyEDIDFunction = @convention(c) (CFTypeRef, UnsafeMutablePointer<Unmanaged<CFData>?>) -> kern_return_t
    fileprivate typealias IOAVServiceReadI2CFunction = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> kern_return_t
    fileprivate typealias IOAVServiceWriteI2CFunction = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer?, UInt32) -> kern_return_t

    private enum PersistenceKeys {
        static let disabledDisplayIDsForRecovery = "DisabledDisplayIDsForRecovery"
        static let pendingReactivationDisplayIDs = "PendingReactivationDisplayIDs"
    }

    private enum DDCConstants {
        static let getVCPFeatureReplyOpcode: UInt8 = 0x02
        static let inputSourceControlID: UInt8 = 0x60
        static let hostAddress: UInt8 = 0x51
        static let ddcChipAddress: UInt32 = 0x37
        static let ddcDataAddress: UInt32 = 0x51
        static let displayWriteAddress: UInt8 = 0x6E
        static let displayReadAddress: UInt8 = 0x6F
    }

    private enum ClamshellState {
        case open
        case closed
        case unknown
    }

    @Published var displays: [DisplayInfo] = []
    @Published var busyDisplayIDs: Set<CGDirectDisplayID> = []
    @Published var isRefreshingDisplays: Bool = false
    @Published var hasCompletedInitialRefresh: Bool = false

    private let defaults: UserDefaults
    private let refreshQueue = DispatchQueue(label: "LightsOut.display-refresh", qos: .userInitiated)
    private var displayCancellables: Set<AnyCancellable> = []
    private var preferredDisplayNameByHardwareIdentity: [DisplayHardwareIdentity: String] = [:]
    private var learnedInputSourceByDisplayIdentity: [DisplayIdentity: UInt16] = [:]
    private var ddcMatchCountByDisplayIdentity: [DisplayIdentity: Int] = [:]
    private var ddcMismatchCountByDisplayIdentity: [DisplayIdentity: Int] = [:]
    private var ddcMissingCountByDisplayIdentity: [DisplayIdentity: Int] = [:]
    private var isFetchingDisplays = false
    private var pendingDisplayRefresh = false
#if DEBUG
    private let isVerboseDDCDebugEnabled = ProcessInfo.processInfo.environment["LIGHTSOUT_VERBOSE_DDC_DEBUG"] == "1"
    private var pendingDDCDebugStages: [CGDirectDisplayID: [String]] = [:]
    private var previousDebugRegistryPropertiesByScope: [String: [String: [String: String]]] = [:]
#endif
    private let ioAVServiceFunctions: IOAVServiceFunctions? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/Versions/A/IOKit", RTLD_LAZY) else {
            return nil
        }
        guard let createSymbol = dlsym(handle, "IOAVServiceCreateWithService"),
              let copyEDIDSymbol = dlsym(handle, "IOAVServiceCopyEDID"),
              let readI2CSymbol = dlsym(handle, "IOAVServiceReadI2C"),
              let writeI2CSymbol = dlsym(handle, "IOAVServiceWriteI2C") else {
            return nil
        }
        return IOAVServiceFunctions(
            createWithService: unsafeBitCast(createSymbol, to: IOAVServiceCreateWithServiceFunction.self),
            copyEDID: unsafeBitCast(copyEDIDSymbol, to: IOAVServiceCopyEDIDFunction.self),
            readI2C: unsafeBitCast(readI2CSymbol, to: IOAVServiceReadI2CFunction.self),
            writeI2C: unsafeBitCast(writeI2CSymbol, to: IOAVServiceWriteI2CFunction.self)
        )
    }()
    private let cgDisplayIOServicePort: CGDisplayIOServicePortFunction? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_LAZY) else {
            return nil
        }
        guard let symbol = dlsym(handle, "CGDisplayIOServicePort") else {
            return nil
        }
        return unsafeBitCast(symbol, to: CGDisplayIOServicePortFunction.self)
    }()

    private struct DisplayRefreshProbe {
        let onlineDisplayIDs: [CGDirectDisplayID]
        let hiddenDisplayIDs: [CGDirectDisplayID]
        let pendingReactivationDisplayIDs: [CGDirectDisplayID]
        let clamshellState: ClamshellState
        let activeDisplaySet: Set<CGDirectDisplayID>
        let primaryDisplayID: CGDirectDisplayID
        let transportByDisplayID: [CGDirectDisplayID: DisplayTransportSnapshot]
        let edidUUIDByDisplayID: [CGDirectDisplayID: String]
        let ddcInputSourcesByDisplayID: [CGDirectDisplayID: DDCInputSourceSnapshot]
    }

    /// Called before display configuration changes. Pass the set of display IDs being hidden (empty for show operations).
    var willChangeDisplays: ((_ disablingDisplayIDs: Set<CGDirectDisplayID>) -> Void)?
    /// Called after display configuration changes complete.
    var didChangeDisplays: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fetchDisplays()
    }

    func fetchDisplays() {
        if isFetchingDisplays {
            pendingDisplayRefresh = true
            return
        }

        isFetchingDisplays = true
        isRefreshingDisplays = true
#if DEBUG
        if isVerboseDDCDebugEnabled {
            pendingDDCDebugStages = [:]
        }
#endif
        let displayNamesByID = currentDisplayNamesByID(fallbackDisplays: displays)
        refreshQueue.async { [weak self] in
            guard let self else { return }
            let probe = self.makeDisplayRefreshProbe(displayNamesByID: displayNamesByID)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.applyDisplayRefreshProbe(probe, displayNamesByID: displayNamesByID)
                self.finishDisplayFetch()
            }
        }
    }

    private func finishDisplayFetch() {
        isFetchingDisplays = false
        isRefreshingDisplays = false
        hasCompletedInitialRefresh = true
        if pendingDisplayRefresh {
            pendingDisplayRefresh = false
            DispatchQueue.main.async { [weak self] in
                self?.fetchDisplays()
            }
        }
    }

    private func makeDisplayRefreshProbe(displayNamesByID: [CGDirectDisplayID: String]) -> DisplayRefreshProbe {
        var activeDisplayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &activeDisplayCount)
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(activeDisplayCount))
        CGGetActiveDisplayList(activeDisplayCount, &activeDisplays, &activeDisplayCount)

        var onlineDisplayCount: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &onlineDisplayCount)
        var onlineDisplays = [CGDirectDisplayID](repeating: 0, count: Int(onlineDisplayCount))
        CGGetOnlineDisplayList(onlineDisplayCount, &onlineDisplays, &onlineDisplayCount)

        let onlineDisplayIDs = Array(onlineDisplays.prefix(Int(onlineDisplayCount)))
        let activeDisplaySet = Set(activeDisplays.prefix(Int(activeDisplayCount)))
        let hiddenDisplayIDs = Array(loadDisabledDisplayIDsForRecovery())
        let pendingReactivationDisplayIDs = Array(loadPendingReactivationDisplayIDs())
        let probeDisplayIDs = Array(Set(onlineDisplayIDs).union(hiddenDisplayIDs).union(pendingReactivationDisplayIDs))
        let clamshellState = currentClamshellState()
        let transportSnapshots = currentDisplayTransportSnapshots()
        let transportByDisplayID = matchedTransportSnapshotsByDisplayID(
            displayIDs: onlineDisplayIDs,
            snapshots: transportSnapshots,
            displayNamesByID: displayNamesByID
        )
        let edidUUIDByDisplayID = currentEDIDUUIDsByDisplayID(for: probeDisplayIDs)
        let ddcInputSourcesByDisplayID = currentDDCInputSources(
            for: probeDisplayIDs,
            edidUUIDByDisplayID: edidUUIDByDisplayID,
            displayNamesByID: displayNamesByID
        )

        return DisplayRefreshProbe(
            onlineDisplayIDs: onlineDisplayIDs,
            hiddenDisplayIDs: hiddenDisplayIDs,
            pendingReactivationDisplayIDs: pendingReactivationDisplayIDs,
            clamshellState: clamshellState,
            activeDisplaySet: activeDisplaySet,
            primaryDisplayID: CGMainDisplayID(),
            transportByDisplayID: transportByDisplayID,
            edidUUIDByDisplayID: edidUUIDByDisplayID,
            ddcInputSourcesByDisplayID: ddcInputSourcesByDisplayID
        )
    }

    private func applyDisplayRefreshProbe(
        _ probe: DisplayRefreshProbe,
        displayNamesByID: [CGDirectDisplayID: String]
    ) {
        let onlineDisplaySet = Set(probe.onlineDisplayIDs)
        let originalPersistedDisabledDisplayIDs = loadDisabledDisplayIDsForRecovery()
        let originalPendingReactivationDisplayIDs = loadPendingReactivationDisplayIDs()
        var persistedDisabledDisplayIDs = originalPersistedDisabledDisplayIDs
        var pendingReactivationDisplayIDs = originalPendingReactivationDisplayIDs

        // If macOS already reports a display as active, any persisted hidden/pending state
        // for that display is stale and should not keep it stuck as hidden after relaunch.
        let activeDisplayIDs = probe.activeDisplaySet
        persistedDisabledDisplayIDs.subtract(activeDisplayIDs)
        pendingReactivationDisplayIDs.subtract(activeDisplayIDs)

        let existingByID = Dictionary(uniqueKeysWithValues: displays.map { ($0.id, $0) })
        var expectedInputSourceByDisplayID: [CGDirectDisplayID: UInt16?] = [:]
        var ddcAvailabilityByDisplayID: [CGDirectDisplayID: Bool] = [:]
        var finalAvailabilityByDisplayID: [CGDirectDisplayID: Bool] = [:]
        var resolvedStateByDisplayID: [CGDirectDisplayID: DisplayState] = [:]
        var ddcMatchCountByDisplayID: [CGDirectDisplayID: Int] = [:]
        var ddcMismatchCountByDisplayID: [CGDirectDisplayID: Int] = [:]
        var ddcMissingCountByDisplayID: [CGDirectDisplayID: Int] = [:]
        var autoReconnectDisplayIDs: [CGDirectDisplayID] = []

        var newDisplays = Set(probe.onlineDisplayIDs.compactMap { displayID -> DisplayInfo? in
            let displayName = resolvedDisplayName(for: displayID, displayNamesByID: displayNamesByID)
            let isBuiltIn = CGDisplayIsBuiltin(displayID) != 0
            let isManagedHidden = persistedDisabledDisplayIDs.contains(displayID)
            let displayIdentity = DisplayIdentity(displayID: displayID, displayName: displayName)
            let transportSnapshot = probe.transportByDisplayID[displayID]
            let transportAvailable = transportSnapshot.map(isTransportAvailable(_:)) ?? true
            let ddcSnapshot = probe.ddcInputSourcesByDisplayID[displayID]
            var expectedInputSource = learnedInputSourceByDisplayIdentity[displayIdentity]
            let wasAvailable = existingByID[displayID]?.isAvailable ?? true
            if !isBuiltIn,
               !isManagedHidden,
               probe.activeDisplaySet.contains(displayID),
               expectedInputSource == nil,
               let currentInputSource = ddcSnapshot?.currentValue {
                learnedInputSourceByDisplayIdentity[displayIdentity] = currentInputSource
                expectedInputSource = currentInputSource
            }
            let ddcAvailable = resolveDDCAvailability(
                for: displayIdentity,
                snapshot: ddcSnapshot,
                expectedInputSource: expectedInputSource,
                wasAvailable: wasAvailable
            )
            let isClamshellBlockedBuiltIn = isBuiltIn && isManagedHidden && probe.clamshellState != .open
            let isAvailable = transportAvailable && ddcAvailable && !isClamshellBlockedBuiltIn
            let state: DisplayState = isManagedHidden
                ? .disconnected
                : ((probe.activeDisplaySet.contains(displayID) && isAvailable) ? .active : .disconnected)
            expectedInputSourceByDisplayID[displayID] = expectedInputSource
            ddcAvailabilityByDisplayID[displayID] = ddcAvailable
            finalAvailabilityByDisplayID[displayID] = isAvailable
            resolvedStateByDisplayID[displayID] = state
            ddcMatchCountByDisplayID[displayID] = ddcMatchCountByDisplayIdentity[displayIdentity] ?? 0
            ddcMissingCountByDisplayID[displayID] = ddcMissingCountByDisplayIdentity[displayIdentity] ?? 0
            ddcMismatchCountByDisplayID[displayID] =
                max(
                    ddcMismatchCountByDisplayIdentity[displayIdentity] ?? 0,
                    ddcMissingCountByDisplayIdentity[displayIdentity] ?? 0
                )

            debugLogDisplayResolution(
                displayID: displayID,
                displayName: displayName,
                isBuiltIn: isBuiltIn,
                isManagedHidden: isManagedHidden,
                isActive: probe.activeDisplaySet.contains(displayID),
                snapshot: transportSnapshot,
                hpmSnapshot: nil,
                dcpSnapshot: nil,
                ddcSnapshot: ddcSnapshot,
                expectedInputSource: expectedInputSource,
                state: state,
                isAvailable: isAvailable
            )

            if !isBuiltIn && !isManagedHidden && !isAvailable {
                return nil
            }

            if let existing = existingByID[displayID] {
                existing.state = state
                existing.isPrimary = displayID == probe.primaryDisplayID
                existing.isUserHidden = isManagedHidden
                existing.isAvailable = isAvailable
                return existing
            }

            return DisplayInfo(
                id: displayID,
                name: displayName,
                state: state,
                isPrimary: displayID == probe.primaryDisplayID,
                isBuiltIn: isBuiltIn,
                isUserHidden: isManagedHidden,
                isAvailable: isAvailable
            )
        })

        for display in displays {
            guard !onlineDisplaySet.contains(display.id) else { continue }

            if persistedDisabledDisplayIDs.contains(display.id) {
                let displayName = resolvedDisplayName(
                    for: display.id,
                    displayNamesByID: displayNamesByID,
                    fallbackName: display.name
                )
                let displayIdentity = DisplayIdentity(displayID: display.id, displayName: displayName)
                let ddcSnapshot = probe.ddcInputSourcesByDisplayID[display.id]
                let expectedInputSource = learnedInputSourceByDisplayIdentity[displayIdentity]
                let wasAvailable = existingByID[display.id]?.isAvailable ?? true
                var isAvailable: Bool
                if ddcSnapshot != nil || expectedInputSource != nil {
                    isAvailable = resolveDDCAvailability(
                        for: displayIdentity,
                        snapshot: ddcSnapshot,
                        expectedInputSource: expectedInputSource,
                        wasAvailable: wasAvailable
                    )
                } else {
                    isAvailable = wasAvailable
                }
                if display.isBuiltIn && probe.clamshellState != .open {
                    isAvailable = false
                }
                display.isPrimary = false
                display.isUserHidden = true
                display.state = .disconnected
                display.isAvailable = isAvailable
                expectedInputSourceByDisplayID[display.id] = expectedInputSource
                ddcAvailabilityByDisplayID[display.id] = isAvailable
                finalAvailabilityByDisplayID[display.id] = isAvailable
                resolvedStateByDisplayID[display.id] = .disconnected
                ddcMatchCountByDisplayID[display.id] = ddcMatchCountByDisplayIdentity[displayIdentity] ?? 0
                ddcMissingCountByDisplayID[display.id] = ddcMissingCountByDisplayIdentity[displayIdentity] ?? 0
                ddcMismatchCountByDisplayID[display.id] =
                    max(
                        ddcMismatchCountByDisplayIdentity[displayIdentity] ?? 0,
                        ddcMissingCountByDisplayIdentity[displayIdentity] ?? 0
                    )
                newDisplays.insert(display)
            } else if display.state == .pending {
                display.isPrimary = false
                display.isUserHidden = false
                display.isAvailable = false
                newDisplays.insert(display)
            }
        }

        for displayID in pendingReactivationDisplayIDs where !onlineDisplaySet.contains(displayID) {
            let displayName = resolvedDisplayName(for: displayID, displayNamesByID: displayNamesByID)
            let displayIdentity = DisplayIdentity(displayID: displayID, displayName: displayName)
            let ddcSnapshot = probe.ddcInputSourcesByDisplayID[displayID]
            let expectedInputSource = learnedInputSourceByDisplayIdentity[displayIdentity]
            let wasAvailable = existingByID[displayID]?.isAvailable ?? false
            let ddcAvailable = resolveDDCAvailability(
                for: displayIdentity,
                snapshot: ddcSnapshot,
                expectedInputSource: expectedInputSource,
                wasAvailable: wasAvailable
            )

            expectedInputSourceByDisplayID[displayID] = expectedInputSource
            ddcAvailabilityByDisplayID[displayID] = ddcAvailable
            finalAvailabilityByDisplayID[displayID] = ddcAvailable
            resolvedStateByDisplayID[displayID] = .disconnected
            ddcMatchCountByDisplayID[displayID] = ddcMatchCountByDisplayIdentity[displayIdentity] ?? 0
            ddcMissingCountByDisplayID[displayID] = ddcMissingCountByDisplayIdentity[displayIdentity] ?? 0
            ddcMismatchCountByDisplayID[displayID] =
                max(
                    ddcMismatchCountByDisplayIdentity[displayIdentity] ?? 0,
                    ddcMissingCountByDisplayIdentity[displayIdentity] ?? 0
                )

            if ddcAvailable {
                autoReconnectDisplayIDs.append(displayID)
            }
        }

        displays = Array(newDisplays).sorted {
            if $0.isPrimary { return true }
            if $1.isPrimary { return false }
            return $0.id < $1.id
        }

        debugLogSwiftDDCProbe(
            displayIDs: Array(Set(probe.onlineDisplayIDs).union(probe.hiddenDisplayIDs).union(probe.pendingReactivationDisplayIDs)).sorted(),
            edidUUIDByDisplayID: probe.edidUUIDByDisplayID,
            ddcInputSourcesByDisplayID: probe.ddcInputSourcesByDisplayID,
            expectedInputSourceByDisplayID: expectedInputSourceByDisplayID,
            ddcAvailabilityByDisplayID: ddcAvailabilityByDisplayID,
            finalAvailabilityByDisplayID: finalAvailabilityByDisplayID,
            resolvedStateByDisplayID: resolvedStateByDisplayID,
            ddcMatchCountByDisplayID: ddcMatchCountByDisplayID,
            ddcMismatchCountByDisplayID: ddcMismatchCountByDisplayID,
            ddcMissingCountByDisplayID: ddcMissingCountByDisplayID
        )

        subscribeToDisplayChanges()

        if persistedDisabledDisplayIDs != originalPersistedDisabledDisplayIDs {
            persistDisabledDisplayIDsForRecovery(persistedDisabledDisplayIDs)
        }

        if pendingReactivationDisplayIDs != originalPendingReactivationDisplayIDs {
            persistPendingReactivationDisplayIDs(pendingReactivationDisplayIDs)
        }

        if !autoReconnectDisplayIDs.isEmpty {
            DispatchQueue.main.async { [weak self] in
                self?.attemptPendingDisplayReconnections(autoReconnectDisplayIDs)
            }
        }
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
            if display.isBuiltIn && currentClamshellState() != .open {
                throw DisplayError(msg: "Open the lid before enabling the built-in display.")
            }
            if display.isUserHidden && !display.isAvailable {
                persistPendingReactivationDisplayID(display.id)
                removeDisabledDisplayIDForRecovery(display.id)
                display.isUserHidden = false
                do {
                    try reconnectDisplay(displayID: display.id)
                    removePendingReactivationDisplayID(display.id)
                    fetchDisplays()
                } catch {
                    didChangeDisplays?()
                    fetchDisplays()
                }
            } else {
                try reconnectDisplay(display: display)
            }
        }
    }

    func resetAllDisplays() {
        let persistedDisabledDisplayIDs = loadDisabledDisplayIDsForRecovery()

        for display in displays {
            try? turnOnDisplay(display: display)
        }

        CGDisplayRestoreColorSyncSettings()
        CGRestorePermanentDisplayConfiguration()

        var remainingDisabledDisplayIDs = loadDisabledDisplayIDsForRecovery().union(persistedDisabledDisplayIDs)
        for displayID in persistedDisabledDisplayIDs {
            do {
                try reconnectDisplay(displayID: displayID)
                remainingDisabledDisplayIDs.remove(displayID)
            } catch {
                continue
            }
        }

        persistDisabledDisplayIDsForRecovery(remainingDisabledDisplayIDs)
        fetchDisplays()
    }

    func recoverDisabledDisplaysFromPreviousSessionIfNeeded() {
        let disabledDisplayIDs = loadDisabledDisplayIDsForRecovery()
        guard !disabledDisplayIDs.isEmpty else { return }

        var remainingDisabledDisplayIDs = disabledDisplayIDs
        for displayID in disabledDisplayIDs {
            do {
                try reconnectDisplay(displayID: displayID)
                remainingDisabledDisplayIDs.remove(displayID)
            } catch {
                continue
            }
        }

        persistDisabledDisplayIDsForRecovery(remainingDisabledDisplayIDs)
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

    private func currentDisplayNamesByID(fallbackDisplays: [DisplayInfo]) -> [CGDirectDisplayID: String] {
        var namesByID: [CGDirectDisplayID: String] = [:]

        for screen in NSScreen.screens {
            let name = screen.localizedName
            if !isPlaceholderDisplayName(name) {
                rememberDisplayName(name, for: screen.displayID)
            }
            namesByID[screen.displayID] = preferredDisplayName(for: screen.displayID, fallbackName: name)
        }

        for display in fallbackDisplays {
            if !isPlaceholderDisplayName(display.name) {
                rememberDisplayName(display.name, for: display.id)
            }
            if namesByID[display.id] == nil {
                namesByID[display.id] = preferredDisplayName(for: display.id, fallbackName: display.name)
            }
        }

        return namesByID
    }

    private func resolvedDisplayName(
        for displayID: CGDirectDisplayID,
        displayNamesByID: [CGDirectDisplayID: String],
        fallbackName: String? = nil
    ) -> String {
        let candidateName = displayNamesByID[displayID] ?? fallbackName
        let resolvedName = preferredDisplayName(for: displayID, fallbackName: candidateName)
        if !isPlaceholderDisplayName(resolvedName) {
            rememberDisplayName(resolvedName, for: displayID)
        }
        return resolvedName
    }

    private func preferredDisplayName(for displayID: CGDirectDisplayID, fallbackName: String?) -> String {
        if let fallbackName, !isPlaceholderDisplayName(fallbackName) {
            return fallbackName
        }

        if let hardwareIdentity = hardwareIdentity(for: displayID),
           let cachedName = preferredDisplayNameByHardwareIdentity[hardwareIdentity] {
            return cachedName
        }

        if let fallbackName, !fallbackName.isEmpty {
            return fallbackName
        }

        return "Display \(displayID)"
    }

    private func rememberDisplayName(_ name: String, for displayID: CGDirectDisplayID) {
        guard !isPlaceholderDisplayName(name),
              let hardwareIdentity = hardwareIdentity(for: displayID) else {
            return
        }
        preferredDisplayNameByHardwareIdentity[hardwareIdentity] = name
    }

    private func hardwareIdentity(for displayID: CGDirectDisplayID) -> DisplayHardwareIdentity? {
        let vendorID = CGDisplayVendorNumber(displayID)
        let productID = CGDisplayModelNumber(displayID)
        let serialNumber = CGDisplaySerialNumber(displayID)
        guard productID != 0 else { return nil }
        return DisplayHardwareIdentity(
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber
        )
    }

    private func isPlaceholderDisplayName(_ name: String) -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return true }
        return trimmedName.range(of: #"^Display \d+$"#, options: .regularExpression) != nil
    }

    private func currentClamshellState() -> ClamshellState {
        guard let matchingDictionary = IOServiceMatching("IOPMrootDomain") else { return .unknown }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matchingDictionary)
        guard service != 0 else { return .unknown }
        defer { IOObjectRelease(service) }

        let clamshellState = IORegistryEntryCreateCFProperty(
            service,
            "AppleClamshellState" as CFString,
            kCFAllocatorDefault,
            0
        )?.takeRetainedValue() as? Bool

        guard let clamshellState else { return .unknown }
        return clamshellState ? .closed : .open
    }

    private func currentDisplayTransportSnapshots() -> [DisplayTransportSnapshot] {
        guard let matchingDictionary = IOServiceMatching("IOPortTransportStateDisplayPort") else { return [] }

        var iterator: io_iterator_t = 0
        let matchingStatus = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        guard matchingStatus == KERN_SUCCESS else { return [] }

        defer { IOObjectRelease(iterator) }

        var snapshots: [DisplayTransportSnapshot] = []
        let includeVerboseRegistryDebug = isVerboseRegistryDebugEnabled

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let properties = ioRegistryProperties(for: service) else { continue }
            let metadata = properties["Metadata"] as? [String: Any] ?? [:]
            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)

            snapshots.append(
                DisplayTransportSnapshot(
                    registryID: registryID,
                    productName: stringProperty(named: "ProductName", in: properties, fallback: metadata),
                    productID: uint32Property(named: "ProductID", in: properties, fallback: metadata),
                    serialNumber: uint32Property(named: "SerialNumber", in: properties, fallback: metadata),
                    edidUUID: recursiveStringProperty(named: "EDID UUID", on: service),
                    isActive: (properties["Active"] as? Bool) ?? false,
                    sinkCount: intProperty(named: "SinkCount", in: properties),
                    linkRate: intProperty(named: "LinkRate", in: properties),
                    subtreeHash: includeVerboseRegistryDebug ? debugRegistrySubtreeHash(for: service) : nil,
                    subtreeServices: includeVerboseRegistryDebug ? debugRegistrySubtreeCapture(for: service) : nil
                )
            )
        }

        return snapshots
    }

    private func currentDCPRemotePortSnapshots() -> [DCPRemotePortSnapshot] {
        guard let matchingDictionary = IOServiceMatching("AppleDCPDPTXRemotePortUFP") else { return [] }

        var iterator: io_iterator_t = 0
        let matchingStatus = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        guard matchingStatus == KERN_SUCCESS else { return [] }

        defer { IOObjectRelease(iterator) }

        var snapshots: [DCPRemotePortSnapshot] = []
        let includeVerboseRegistryDebug = isVerboseRegistryDebugEnabled

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let properties = ioRegistryProperties(for: service) else { continue }
            let displayHints = properties["DisplayHints"] as? [String: Any] ?? [:]
            let eventLog = properties["EventLog"] as? [[String: Any]] ?? []

            var registryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(service, &registryID)

            var stateValues: [String: Int] = [:]
            var lastAction: String?
            var lastEventTime: UInt64?
            var lastEventClass: String?
            var lastStateName: String?
            var lastStateValue: Int?

            for event in eventLog {
                if let eventTime = (event["EventTime"] as? NSNumber)?.uint64Value {
                    lastEventTime = eventTime
                }
                if let eventClass = event["EventClass"] as? String {
                    lastEventClass = eventClass
                }

                guard let payload = event["EventPayload"] as? [String: Any] else { continue }

                if let state = payload["State"] as? String,
                   let value = (payload["Value"] as? NSNumber)?.intValue {
                    stateValues[state] = value
                    lastStateName = state
                    lastStateValue = value
                }

                if let action = payload["Action"] as? String,
                   let queueOp = payload["QueueOp"] as? String {
                    lastAction = "\(queueOp):\(action)"
                }
            }

            snapshots.append(
                DCPRemotePortSnapshot(
                    registryID: registryID,
                    productName: displayHints["ProductName"] as? String,
                    edidUUID: displayHints["EDID UUID"] as? String,
                    sinkActive: stateValues["SinkActive"],
                    linkRate: stateValues["LinkRate"],
                    laneCount: stateValues["LaneCount"],
                    activate: stateValues["Activate"],
                    registered: stateValues["Registered"],
                    lastAction: lastAction,
                    eventCount: eventLog.count,
                    lastEventTime: lastEventTime,
                    lastEventClass: lastEventClass,
                    lastStateName: lastStateName,
                    lastStateValue: lastStateValue,
                    subtreeHash: includeVerboseRegistryDebug ? debugRegistrySubtreeHash(for: service) : nil,
                    subtreeServices: includeVerboseRegistryDebug ? debugRegistrySubtreeCapture(for: service) : nil
                )
            )
        }

        return snapshots
    }

    private func currentHPMSnapshots() -> [HPMDisplaySnapshot] {
        guard let matchingDictionary = IOServiceMatching("AppleHPMInterfaceType10") else { return [] }

        var iterator: io_iterator_t = 0
        let matchingStatus = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        guard matchingStatus == KERN_SUCCESS else { return [] }

        defer { IOObjectRelease(iterator) }

        var snapshots: [HPMDisplaySnapshot] = []
        let includeVerboseRegistryDebug = isVerboseRegistryDebugEnabled

        while true {
            let hpmService = IOIteratorNext(iterator)
            guard hpmService != 0 else { break }
            defer { IOObjectRelease(hpmService) }

            guard let hpmProperties = ioRegistryProperties(for: hpmService) else { continue }

            var hpmRegistryID: UInt64 = 0
            IORegistryEntryGetRegistryEntryID(hpmService, &hpmRegistryID)

            let connectionActive = (hpmProperties["ConnectionActive"] as? Bool) ?? false
            let activeCable = (hpmProperties["ActiveCable"] as? Bool) ?? false
            let transportsActive = hpmProperties["TransportsActive"] as? [String] ?? []
            let transportsProvisioned = hpmProperties["TransportsProvisioned"] as? [String] ?? []
            let transportsUnauthorized = hpmProperties["TransportsUnauthorized"] as? [String] ?? []

            var childIterator: io_iterator_t = 0
            let childStatus = IORegistryEntryCreateIterator(
                hpmService,
                kIOServicePlane,
                IOOptionBits(kIORegistryIterateRecursively),
                &childIterator
            )
            guard childStatus == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(childIterator) }

            while true {
                let childService = IOIteratorNext(childIterator)
                guard childService != 0 else { break }
                defer { IOObjectRelease(childService) }

                guard serviceClassName(childService) == "IOPortTransportStateDisplayPort",
                      let properties = ioRegistryProperties(for: childService) else {
                    continue
                }

                let metadata = properties["Metadata"] as? [String: Any] ?? [:]
                var childRegistryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(childService, &childRegistryID)

                snapshots.append(
                    HPMDisplaySnapshot(
                        hpmRegistryID: hpmRegistryID,
                        displayPortRegistryID: childRegistryID,
                        productName: stringProperty(named: "ProductName", in: properties, fallback: metadata),
                        productID: uint32Property(named: "ProductID", in: properties, fallback: metadata),
                        serialNumber: uint32Property(named: "SerialNumber", in: properties, fallback: metadata),
                        edidUUID: recursiveStringProperty(named: "EDID UUID", on: childService),
                        connectionActive: connectionActive,
                        activeCable: activeCable,
                        transportsActive: transportsActive,
                        transportsProvisioned: transportsProvisioned,
                        transportsUnauthorized: transportsUnauthorized,
                        subtreeHash: includeVerboseRegistryDebug ? debugRegistrySubtreeHash(for: hpmService) : nil,
                        subtreeServices: includeVerboseRegistryDebug ? debugRegistrySubtreeCapture(for: hpmService) : nil
                    )
                )
            }
        }

        return snapshots
    }

    private func currentAuxiliaryRegistrySnapshots() -> [AuxiliaryRegistrySnapshot] {
        let classNames = [
            "DCPAVServiceProxy",
            "DCPAVVideoInterfaceProxy",
            "DCPAVAudioDriver",
            "DCPAVAudioInterfaceProxy",
            "DCPDPServiceProxy",
            "DCPAVControllerProxy",
            "DCPDPControllerProxy",
            "DCPAVDeviceProxy",
            "DCPDPDeviceProxy"
        ]

        var snapshots: [AuxiliaryRegistrySnapshot] = []
        let includeVerboseRegistryDebug = isVerboseRegistryDebugEnabled

        for className in classNames {
            guard let matchingDictionary = IOServiceMatching(className) else { continue }

            var iterator: io_iterator_t = 0
            let matchingStatus = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
            guard matchingStatus == KERN_SUCCESS else { continue }

            defer { IOObjectRelease(iterator) }

            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                defer { IOObjectRelease(service) }

                var registryID: UInt64 = 0
                IORegistryEntryGetRegistryEntryID(service, &registryID)

                let identity = recursiveDisplayIdentity(on: service)
                snapshots.append(
                    AuxiliaryRegistrySnapshot(
                        className: className,
                        registryID: registryID,
                        edidUUID: recursiveStringProperty(named: "device UID", on: service)
                            ?? recursiveStringProperty(named: "EDID UUID", on: service),
                        location: recursiveStringProperty(named: "Location", on: service),
                        identity: identity,
                        subtreeHash: includeVerboseRegistryDebug ? debugRegistrySubtreeHash(for: service) : nil,
                        subtreeServices: includeVerboseRegistryDebug ? debugRegistrySubtreeCapture(for: service) : nil
                    )
                )
            }
        }

        return snapshots
    }

    private func matchedTransportSnapshotsByDisplayID(
        displayIDs: [CGDirectDisplayID],
        snapshots: [DisplayTransportSnapshot],
        displayNamesByID: [CGDirectDisplayID: String]
    ) -> [CGDirectDisplayID: DisplayTransportSnapshot] {
        var availableSnapshots = snapshots
        var matches: [CGDirectDisplayID: DisplayTransportSnapshot] = [:]

        for displayID in displayIDs {
            let displayName = displayNamesByID[displayID] ?? "Display \(displayID)"
            let displayModel = CGDisplayModelNumber(displayID)
            let displaySerial = CGDisplaySerialNumber(displayID)

            guard let bestMatch = availableSnapshots.enumerated().max(by: {
                transportMatchScore(snapshot: $0.element, displayName: displayName, displayModel: displayModel, displaySerial: displaySerial)
                    < transportMatchScore(snapshot: $1.element, displayName: displayName, displayModel: displayModel, displaySerial: displaySerial)
            }) else {
                continue
            }

            let score = transportMatchScore(
                snapshot: bestMatch.element,
                displayName: displayName,
                displayModel: displayModel,
                displaySerial: displaySerial
            )
            guard score > 0 else { continue }

            matches[displayID] = bestMatch.element
            availableSnapshots.remove(at: bestMatch.offset)
        }

        return matches
    }

    private func matchedDCPRemotePortSnapshotsByDisplayID(
        displayIDs: [CGDirectDisplayID],
        edidUUIDByDisplayID: [CGDirectDisplayID: String],
        snapshots: [DCPRemotePortSnapshot]
    ) -> [CGDirectDisplayID: DCPRemotePortSnapshot] {
        var snapshotsByUUID: [String: DCPRemotePortSnapshot] = [:]
        for snapshot in snapshots {
            guard let edidUUID = snapshot.edidUUID else { continue }
            snapshotsByUUID[edidUUID] = snapshot
        }

        var matches: [CGDirectDisplayID: DCPRemotePortSnapshot] = [:]
        for displayID in displayIDs {
            guard let edidUUID = edidUUIDByDisplayID[displayID],
                  let snapshot = snapshotsByUUID[edidUUID] else {
                continue
            }
            matches[displayID] = snapshot
        }

        return matches
    }

    private func matchedHPMSnapshotsByDisplayID(
        displayIDs: [CGDirectDisplayID],
        edidUUIDByDisplayID: [CGDirectDisplayID: String],
        snapshots: [HPMDisplaySnapshot]
    ) -> [CGDirectDisplayID: HPMDisplaySnapshot] {
        var availableSnapshots = snapshots
        var matches: [CGDirectDisplayID: HPMDisplaySnapshot] = [:]

        for displayID in displayIDs {
            let displayName = NSScreen.screens.first(where: { $0.displayID == displayID })?.localizedName ?? "Display \(displayID)"
            let displayModel = CGDisplayModelNumber(displayID)
            let displaySerial = CGDisplaySerialNumber(displayID)
            let targetUUID = edidUUIDByDisplayID[displayID]

            guard let bestMatch = availableSnapshots.enumerated().max(by: {
                hpmMatchScore(snapshot: $0.element, targetUUID: targetUUID, displayName: displayName, displayModel: displayModel, displaySerial: displaySerial)
                    < hpmMatchScore(snapshot: $1.element, targetUUID: targetUUID, displayName: displayName, displayModel: displayModel, displaySerial: displaySerial)
            }) else {
                continue
            }

            let score = hpmMatchScore(
                snapshot: bestMatch.element,
                targetUUID: targetUUID,
                displayName: displayName,
                displayModel: displayModel,
                displaySerial: displaySerial
            )
            guard score > 0 else { continue }

            matches[displayID] = bestMatch.element
            availableSnapshots.remove(at: bestMatch.offset)
        }

        return matches
    }

    private func matchedAuxiliaryRegistrySnapshotsByDisplayID(
        displayIDs: [CGDirectDisplayID],
        edidUUIDByDisplayID: [CGDirectDisplayID: String],
        snapshots: [AuxiliaryRegistrySnapshot]
    ) -> [CGDirectDisplayID: [AuxiliaryRegistrySnapshot]] {
        var matches: [CGDirectDisplayID: [AuxiliaryRegistrySnapshot]] = [:]

        for snapshot in snapshots {
            var bestDisplayID: CGDirectDisplayID?
            var bestScore = 0

            for displayID in displayIDs {
                let displayName = NSScreen.screens.first(where: { $0.displayID == displayID })?.localizedName ?? ""
                let score = auxiliaryMatchScore(
                    snapshot: snapshot,
                    targetUUID: edidUUIDByDisplayID[displayID],
                    displayName: displayName,
                    displayModel: CGDisplayModelNumber(displayID),
                    displaySerial: CGDisplaySerialNumber(displayID)
                )

                if score > bestScore {
                    bestScore = score
                    bestDisplayID = displayID
                }
            }

            guard let bestDisplayID, bestScore > 0 else { continue }
            matches[bestDisplayID, default: []].append(snapshot)
        }

        for displayID in matches.keys {
            matches[displayID]?.sort {
                if $0.className != $1.className {
                    return $0.className < $1.className
                }
                return $0.registryID < $1.registryID
            }
        }

        return matches
    }

    private func currentEDIDUUIDsByDisplayID(for displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: String] {
        var remaining = Dictionary(
            uniqueKeysWithValues: displayIDs.map {
                (
                    $0,
                    DisplayIdentity(
                        vendorID: CGDisplayVendorNumber($0),
                        productID: CGDisplayModelNumber($0),
                        serialNumber: CGDisplaySerialNumber($0),
                        displayName: ""
                    )
                )
            }
        )
        var matches: [CGDirectDisplayID: String] = [:]

        var iterator: io_iterator_t = 0
        let status = IORegistryCreateIterator(
            kIOMainPortDefault,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard status == KERN_SUCCESS else { return matches }
        defer { IOObjectRelease(iterator) }

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            guard let edidUUID = recursiveStringProperty(named: "EDID UUID", on: service),
                  let displayAttributes = IORegistryEntrySearchCFProperty(
                    service,
                    kIOServicePlane,
                    "DisplayAttributes" as CFString,
                    kCFAllocatorDefault,
                    IOOptionBits(kIORegistryIterateRecursively)
                  ) as? [String: Any],
                  let productAttributes = displayAttributes["ProductAttributes"] as? [String: Any],
                  let productID = (productAttributes["ProductID"] as? NSNumber)?.uint32Value,
                  let serialNumber = (productAttributes["SerialNumber"] as? NSNumber)?.uint32Value else {
                continue
            }

            let vendorID = (productAttributes["LegacyManufacturerID"] as? NSNumber)?.uint32Value ?? 0
            let identity = DisplayIdentity(
                vendorID: vendorID,
                productID: productID,
                serialNumber: serialNumber,
                displayName: ""
            )

            guard let match = remaining.first(where: { $0.value.matches(identity) }) else { continue }
            matches[match.key] = edidUUID
            remaining.removeValue(forKey: match.key)

            if remaining.isEmpty { break }
        }

        return matches
    }

    private func currentDDCInputSources(
        for displayIDs: [CGDirectDisplayID],
        edidUUIDByDisplayID: [CGDirectDisplayID: String],
        displayNamesByID: [CGDirectDisplayID: String]
    ) -> [CGDirectDisplayID: DDCInputSourceSnapshot] {
        var snapshots: [CGDirectDisplayID: DDCInputSourceSnapshot] = [:]

        for displayID in displayIDs {
            let displayName = displayNamesByID[displayID] ?? "Display \(displayID)"
            guard CGDisplayIsBuiltin(displayID) == 0 else { continue }

            if let avSnapshot = currentDDCInputSourceViaAVService(
                displayID: displayID,
                displayName: displayName,
                targetEDIDUUID: edidUUIDByDisplayID[displayID]
            ) {
                snapshots[displayID] = avSnapshot
                debugLogDDCStage(
                    displayID: displayID,
                    displayName: displayName,
                    message: "avservice current=\(String(format: "0x%02X", avSnapshot.currentValue)) max=\(String(format: "0x%02X", avSnapshot.maximumValue))"
                )
                continue
            }

            guard isLegacyDDCFallbackEnabled else {
                continue
            }

            if let bridgedSnapshot = currentDDCInputSourceViaPrivateBridge(displayID: displayID, displayName: displayName) {
                snapshots[displayID] = bridgedSnapshot
                debugLogDDCStage(
                    displayID: displayID,
                    displayName: displayName,
                    message: "bridge-bus=\(bridgedSnapshot.busIndex) current=\(String(format: "0x%02X", bridgedSnapshot.currentValue)) max=\(String(format: "0x%02X", bridgedSnapshot.maximumValue))"
                )
                continue
            }

            if let cgsFramebufferService = cgsServiceForDisplay(displayID),
               let cgsSnapshot = currentDDCInputSourceViaFramebufferService(
                cgsFramebufferService,
                displayID: displayID,
                displayName: displayName
               ) {
                snapshots[displayID] = cgsSnapshot
                debugLogDDCStage(
                    displayID: displayID,
                    displayName: displayName,
                    message: "cgs-bus=\(cgsSnapshot.busIndex) current=\(String(format: "0x%02X", cgsSnapshot.currentValue)) max=\(String(format: "0x%02X", cgsSnapshot.maximumValue))"
                )
                continue
            }

            guard let framebufferService = framebufferService(for: displayID) else {
                debugLogDDCStage(displayID: displayID, displayName: displayName, message: "no-framebuffer-match")
                continue
            }
            defer { IOObjectRelease(framebufferService) }
            if let matchedSnapshot = currentDDCInputSourceViaFramebufferService(
                framebufferService,
                displayID: displayID,
                displayName: displayName
            ) {
                snapshots[displayID] = matchedSnapshot
                debugLogDDCStage(
                    displayID: displayID,
                    displayName: displayName,
                    message: "bus=\(matchedSnapshot.busIndex) current=\(String(format: "0x%02X", matchedSnapshot.currentValue)) max=\(String(format: "0x%02X", matchedSnapshot.maximumValue))"
                )
            }
        }

        return snapshots
    }

    private func currentDDCInputSourceViaPrivateBridge(
        displayID: CGDirectDisplayID,
        displayName: String
    ) -> DDCInputSourceSnapshot? {
        var currentValue: UInt16 = 0
        var maximumValue: UInt16 = 0
        let status = LOReadInputSourceForDisplay(displayID, &currentValue, &maximumValue)

        switch status {
        case 1:
            return DDCInputSourceSnapshot(
                busIndex: -3,
                currentValue: currentValue,
                maximumValue: maximumValue,
                rawReply: []
            )
        case 2:
            return DDCInputSourceSnapshot(
                busIndex: -4,
                currentValue: currentValue,
                maximumValue: maximumValue,
                rawReply: []
            )
        case 3:
            return DDCInputSourceSnapshot(
                busIndex: -5,
                currentValue: currentValue,
                maximumValue: maximumValue,
                rawReply: []
            )
        case -1:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-no-service")
        case -2:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-av-create-failed")
        case -3:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-av-write-failed")
        case -4:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-av-read-failed")
        case -5:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-i2c-bus-count-failed")
        case -6:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-i2c-no-buses")
        case -7:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-i2c-read-failed")
        case -8:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-global-av-create-failed")
        case -9:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-global-av-write-failed")
        case -10:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-global-av-read-failed")
        case -11:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-cgs-no-service")
        default:
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bridge-status=\(status)")
        }

        return nil
    }

    private func currentDDCInputSourceViaAVService(
        displayID: CGDirectDisplayID,
        displayName: String,
        targetEDIDUUID: String?
    ) -> DDCInputSourceSnapshot? {
        guard let ioAVServiceFunctions else {
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "avservice-symbols-missing")
            return nil
        }

        if let cgsService = cgsServiceForDisplay(displayID) {
            let className = serviceClassName(cgsService) ?? "unknown"
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "avservice-create-class=\(className)")
            if let unmanagedService = ioAVServiceFunctions.createWithService(kCFAllocatorDefault, cgsService) {
                let avService = unmanagedService.takeRetainedValue()
                if let response = readDDCFeature(controlID: DDCConstants.inputSourceControlID, avService: avService) {
                    return DDCInputSourceSnapshot(
                        busIndex: -2,
                        currentValue: response.currentValue,
                        maximumValue: response.maximumValue,
                        rawReply: response.rawReply
                    )
                }
                debugLogDDCStage(displayID: displayID, displayName: displayName, message: "avservice-read-failed-class=\(className)")
            } else {
                debugLogDDCStage(displayID: displayID, displayName: displayName, message: "avservice-create-failed-class=\(className)")
            }
        }

        guard let avService = matchingAVService(
            for: displayID,
            displayName: displayName,
            targetEDIDUUID: targetEDIDUUID,
            ioAVServiceFunctions: ioAVServiceFunctions
        ) else {
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "avservice-no-match")
            return nil
        }

        guard let response = readDDCFeature(controlID: DDCConstants.inputSourceControlID, avService: avService) else {
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "avservice-read-failed")
            return nil
        }

        return DDCInputSourceSnapshot(
            busIndex: -1,
            currentValue: response.currentValue,
            maximumValue: response.maximumValue,
            rawReply: response.rawReply
        )
    }

    private func currentDDCInputSourceViaFramebufferService(
        _ framebufferService: io_service_t,
        displayID: CGDirectDisplayID,
        displayName: String
    ) -> DDCInputSourceSnapshot? {
        var busCount: IOItemCount = 0
        let busCountStatus = IOFBGetI2CInterfaceCount(framebufferService, &busCount)
        guard busCountStatus == KERN_SUCCESS else {
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bus-count-status=\(busCountStatus)")
            return nil
        }
        guard busCount > 0 else {
            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bus-count=0")
            return nil
        }

        for busIndex in 0..<busCount {
            var interface: io_service_t = 0
            let copyStatus = IOFBCopyI2CInterfaceForBus(framebufferService, IOOptionBits(busIndex), &interface)
            guard copyStatus == KERN_SUCCESS else {
                debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bus=\(busIndex) copy-status=\(copyStatus)")
                continue
            }
            defer { IOObjectRelease(interface) }

            var connect: IOI2CConnectRef?
            let openStatus = IOI2CInterfaceOpen(interface, IOOptionBits(), &connect)
            guard openStatus == KERN_SUCCESS,
                  let connect else {
                debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bus=\(busIndex) open-status=\(openStatus)")
                continue
            }
            defer { _ = IOI2CInterfaceClose(connect, IOOptionBits()) }

            guard let response = readDDCFeature(
                controlID: DDCConstants.inputSourceControlID,
                connect: connect
            ) else {
                debugLogDDCStage(displayID: displayID, displayName: displayName, message: "bus=\(busIndex) read-failed")
                continue
            }

            return DDCInputSourceSnapshot(
                busIndex: Int(busIndex),
                currentValue: response.currentValue,
                maximumValue: response.maximumValue,
                rawReply: response.rawReply
            )
        }

        debugLogDDCStage(displayID: displayID, displayName: displayName, message: "all-buses-failed")
        return nil
    }

    private func matchingAVService(
        for displayID: CGDirectDisplayID,
        displayName: String,
        targetEDIDUUID: String?,
        ioAVServiceFunctions: IOAVServiceFunctions
    ) -> IOAVServiceRef? {
        let targetIdentity = DisplayIdentity(displayID: displayID, displayName: "")
        debugLogDDCStage(displayID: displayID, displayName: "target", message: "avservice-target \(debugIdentitySummary(targetIdentity))")
        if let targetEDIDUUID {
            debugLogDDCStage(displayID: displayID, displayName: "target", message: "avservice-target-uuid \(targetEDIDUUID)")
        }

        guard let matchingDictionary = IOServiceMatching("DCPAVServiceProxy") else { return nil }

        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        guard status == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var bestService: IOAVServiceRef?
        var bestScore = 0

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            let location = recursiveStringProperty(named: "Location", on: service)
            if let location, location != "External" {
                continue
            }

            let candidateUUID = recursiveStringProperty(named: "device UID", on: service)
                ?? recursiveStringProperty(named: "EDID UUID", on: service)
            if let candidateUUID {
                debugLogDDCStage(displayID: displayID, displayName: "candidate", message: "DCPAVServiceProxy uuid=\(candidateUUID)")
            }

            debugLogDDCStage(displayID: displayID, displayName: displayName, message: "avservice-create-class=DCPAVServiceProxy")
            guard let unmanagedService = ioAVServiceFunctions.createWithService(kCFAllocatorDefault, service) else {
                debugLogDDCStage(displayID: displayID, displayName: displayName, message: "avservice-create-failed-class=DCPAVServiceProxy")
                continue
            }

            let avService = unmanagedService.takeRetainedValue()
            let metadata = avServiceMetadata(
                avService: avService,
                service: service,
                ioAVServiceFunctions: ioAVServiceFunctions
            )

            if let metadata {
                debugLogDDCStage(
                    displayID: displayID,
                    displayName: "candidate",
                    message: "DCPAVServiceProxy \(debugIdentitySummary(metadata.identity))"
                )
            }

            let score = avServiceMatchScore(
                targetIdentity: targetIdentity,
                targetEDIDUUID: targetEDIDUUID,
                candidateUUID: candidateUUID,
                candidateMetadata: metadata
            )

            if score > bestScore {
                bestService = avService
                bestScore = score
            }
        }

        return bestService
    }

    private func avServiceMetadata(
        avService: IOAVServiceRef,
        service: io_service_t,
        ioAVServiceFunctions: IOAVServiceFunctions
    ) -> AVServiceMetadata? {
        var edidRef: Unmanaged<CFData>?
        let status = ioAVServiceFunctions.copyEDID(avService, &edidRef)
        let edidData = (status == KERN_SUCCESS) ? (edidRef?.takeRetainedValue() as Data?) : nil
        let edidMetadata = edidData.flatMap { parseEDIDMetadata($0) }

        let identityFromRegistry: DisplayIdentity? = {
            guard let displayAttributes = IORegistryEntrySearchCFProperty(
                service,
                kIOServicePlane,
                "DisplayAttributes" as CFString,
                kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively)
            ) as? [String: Any],
            let productAttributes = displayAttributes["ProductAttributes"] as? [String: Any],
            let productID = (productAttributes["ProductID"] as? NSNumber)?.uint32Value,
            let serialNumber = (productAttributes["SerialNumber"] as? NSNumber)?.uint32Value else {
                return nil
            }

            return DisplayIdentity(
                vendorID: (productAttributes["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
                productID: productID,
                serialNumber: serialNumber,
                displayName: (productAttributes["ProductName"] as? String) ?? ""
            )
        }()

        let identity = edidMetadata.map {
            DisplayIdentity(
                vendorID: $0.vendorID,
                productID: $0.productID,
                serialNumber: $0.serialNumber,
                displayName: $0.productName
            )
        } ?? identityFromRegistry

        guard let identity else { return nil }
        return AVServiceMetadata(identity: identity)
    }

    private func avServiceMatchScore(
        targetIdentity: DisplayIdentity,
        targetEDIDUUID: String?,
        candidateUUID: String?,
        candidateMetadata: AVServiceMetadata?
    ) -> Int {
        var score = 0

        if let targetEDIDUUID, let candidateUUID, targetEDIDUUID == candidateUUID {
            score += 100
        }

        guard let candidateMetadata else { return score }

        if candidateMetadata.identity.productID == targetIdentity.productID, targetIdentity.productID != 0 {
            score += 20
        }
        if candidateMetadata.identity.serialNumber == targetIdentity.serialNumber, targetIdentity.serialNumber != 0 {
            score += 20
        }
        if candidateMetadata.identity.vendorID == targetIdentity.vendorID, targetIdentity.vendorID != 0 {
            score += 10
        }
        if !targetIdentity.displayName.isEmpty,
           !candidateMetadata.identity.displayName.isEmpty,
           targetIdentity.displayName == candidateMetadata.identity.displayName {
            score += 5
        }

        return score
    }

    private func framebufferService(for displayID: CGDirectDisplayID) -> io_service_t? {
        let directService = cgDisplayIOServicePort?(displayID) ?? 0
        if directService != 0 {
            return directService
        }

        guard let matchingDictionary = IOServiceMatching("IOFramebuffer") else { return nil }

        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        guard status == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        let targetVendor = CGDisplayVendorNumber(displayID)
        let targetProduct = CGDisplayModelNumber(displayID)
        let targetSerial = CGDisplaySerialNumber(displayID)

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }

            guard let infoDictionary = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayMatchingInfo))?
                .takeRetainedValue() as? [String: Any] else {
                IOObjectRelease(service)
                continue
            }

            let vendorID = (infoDictionary[kDisplayVendorID] as? NSNumber)?.uint32Value ?? 0
            let productID = (infoDictionary[kDisplayProductID] as? NSNumber)?.uint32Value ?? 0
            let serialNumber = (infoDictionary[kDisplaySerialNumber] as? NSNumber)?.uint32Value ?? 0

            let vendorMatches = vendorID == targetVendor
            let productMatches = productID == targetProduct
            let serialMatches = targetSerial == 0 || serialNumber == 0 || serialNumber == targetSerial

            if vendorMatches && productMatches && serialMatches {
                return service
            }

            IOObjectRelease(service)
        }

        return nil
    }

    private func cgsServiceForDisplay(_ displayID: CGDirectDisplayID) -> io_service_t? {
        var service: io_service_t = 0
        CGSServiceForDisplayNumber(displayID, &service)
        return service == 0 ? nil : service
    }

    private func debugCGDisplayServiceProbeSummary(displayID: CGDirectDisplayID) -> String {
#if DEBUG
        guard let cgDisplayIOServicePort else {
            return "cg-service=symbol-missing"
        }
        let service = cgDisplayIOServicePort(displayID)
        guard service != 0 else {
            return "cg-service=none"
        }
        return debugFramebufferI2CProbeSummary(service: service, prefix: "cg-service")
#else
        _ = displayID
        return ""
#endif
    }

    private func debugCGSServiceProbeSummary(displayID: CGDirectDisplayID) -> String {
#if DEBUG
        guard let service = cgsServiceForDisplay(displayID) else {
            return "cgs-service=none"
        }
        return debugFramebufferI2CProbeSummary(service: service, prefix: "cgs-service")
#else
        _ = displayID
        return ""
#endif
    }

    private func debugMatchedFramebufferProbeSummary(
        displayID: CGDirectDisplayID,
        targetIdentity: DisplayIdentity
    ) -> String {
#if DEBUG
        guard let matchingDictionary = IOServiceMatching("IOFramebuffer") else {
            return "framebuffers=matching-dict-missing"
        }

        var iterator: io_iterator_t = 0
        let status = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
        guard status == KERN_SUCCESS else {
            return "framebuffers=matching-status-\(status)"
        }
        defer { IOObjectRelease(iterator) }

        var candidates: [String] = []
        var matched: [String] = []

        while true {
            let service = IOIteratorNext(iterator)
            guard service != 0 else { break }
            defer { IOObjectRelease(service) }

            let descriptor = debugFramebufferDescriptor(service: service)
            let identity = debugFramebufferIdentity(service: service)
            let matches = identity.map(targetIdentity.matches(_:)) ?? false

            if matches {
                matched.append("\(descriptor) \(debugFramebufferI2CProbeSummary(service: service, prefix: "probe"))")
            } else {
                candidates.append(descriptor)
            }
        }

        if matched.isEmpty {
            return candidates.isEmpty
                ? "framebuffers=none"
                : "framebuffers matched=none candidates=[\(candidates.joined(separator: "; "))]"
        }

        return "framebuffers matched=[\(matched.joined(separator: "; "))]"
#else
        _ = displayID
        _ = targetIdentity
        return ""
#endif
    }

    private func debugAVServiceProbeSummary(
        displayID: CGDirectDisplayID,
        targetIdentity: DisplayIdentity,
        targetUUID: String?
    ) -> String {
#if DEBUG
        guard let ioAVServiceFunctions else {
            return "av=swift-symbols-missing"
        }

        let seedClassNames = [
            "DCPAVServiceProxy",
            "DCPAVVideoInterfaceProxy",
            "DCPAVAudioInterfaceProxy",
            "DCPAVAudioDriver",
            "DCPDPServiceProxy",
            "DCPAVControllerProxy",
            "DCPDPControllerProxy",
            "DCPAVDeviceProxy",
            "DCPDPDeviceProxy"
        ]

        var candidatesByRegistryID: [UInt64: DebugAVProbeCandidate] = [:]
        var insertionOrder = 0

        for className in seedClassNames {
            guard let matchingDictionary = IOServiceMatching(className) else { continue }

            var iterator: io_iterator_t = 0
            let status = IOServiceGetMatchingServices(kIOMainPortDefault, matchingDictionary, &iterator)
            guard status == KERN_SUCCESS else { continue }
            defer { IOObjectRelease(iterator) }

            while true {
                let service = IOIteratorNext(iterator)
                guard service != 0 else { break }
                defer { IOObjectRelease(service) }

                let candidateUUID = recursiveStringProperty(named: "device UID", on: service)
                    ?? recursiveStringProperty(named: "EDID UUID", on: service)
                let candidateIdentity = recursiveDisplayIdentity(on: service)
                let location = recursiveStringProperty(named: "Location", on: service) ?? "nil"

                let uuidMatches = targetUUID != nil && candidateUUID == targetUUID
                let identityMatches = candidateIdentity.map(targetIdentity.matches(_:)) ?? false
                guard uuidMatches || identityMatches else { continue }

                debugCollectAVProbeNeighborhood(
                    from: service,
                    seedLabel: "\(className){loc=\(location),uuid=\(candidateUUID ?? "nil")}",
                    candidatesByRegistryID: &candidatesByRegistryID,
                    insertionOrder: &insertionOrder
                )
            }
        }

        guard !candidatesByRegistryID.isEmpty else {
            return "av=matched-candidates-none"
        }

        let summaries = candidatesByRegistryID.values
            .sorted {
                if $0.insertionOrder != $1.insertionOrder {
                    return $0.insertionOrder < $1.insertionOrder
                }
                if $0.className != $1.className {
                    return $0.className < $1.className
                }
                return $0.registryID < $1.registryID
            }
            .map {
                debugAVCandidateAttemptSummary(
                    displayID: displayID,
                    className: $0.className,
                    service: $0.service,
                    candidateUUID: recursiveStringProperty(named: "device UID", on: $0.service)
                        ?? recursiveStringProperty(named: "EDID UUID", on: $0.service),
                    location: recursiveStringProperty(named: "Location", on: $0.service) ?? "nil",
                    candidateIdentity: recursiveDisplayIdentity(on: $0.service),
                    roleSummary: $0.roles.sorted().joined(separator: ","),
                    ioAVServiceFunctions: ioAVServiceFunctions
                )
            }

        for candidate in candidatesByRegistryID.values {
            IOObjectRelease(candidate.service)
        }

        return "av=[\(summaries.joined(separator: "; "))]"
#else
        _ = displayID
        _ = targetIdentity
        _ = targetUUID
        return ""
#endif
    }

    private func debugCollectAVProbeNeighborhood(
        from seedService: io_service_t,
        seedLabel: String,
        candidatesByRegistryID: inout [UInt64: DebugAVProbeCandidate],
        insertionOrder: inout Int
    ) {
#if DEBUG
        debugAddAVProbeCandidate(
            seedService,
            role: "seed:\(seedLabel)",
            candidatesByRegistryID: &candidatesByRegistryID,
            insertionOrder: &insertionOrder
        )

        var ancestors: [io_service_t] = []
        var currentService = seedService
        for _ in 0..<8 {
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(currentService, kIOServicePlane, &parent)
            guard status == KERN_SUCCESS, parent != 0 else { break }
            ancestors.append(parent)
            currentService = parent
        }
        defer {
            for ancestor in ancestors {
                IOObjectRelease(ancestor)
            }
        }

        for (index, ancestor) in ancestors.enumerated() {
            let level = index + 1
            debugAddAVProbeCandidate(
                ancestor,
                role: "ancestor\(level)",
                candidatesByRegistryID: &candidatesByRegistryID,
                insertionOrder: &insertionOrder
            )
            debugCollectAVProbeDescendants(
                from: ancestor,
                rolePrefix: "ancestor\(level)",
                currentDepth: 1,
                maxDepth: 5,
                candidatesByRegistryID: &candidatesByRegistryID,
                insertionOrder: &insertionOrder
            )
        }
#else
        _ = seedService
        _ = seedLabel
        _ = &candidatesByRegistryID
        _ = &insertionOrder
#endif
    }

    private func debugCollectAVProbeDescendants(
        from service: io_service_t,
        rolePrefix: String,
        currentDepth: Int,
        maxDepth: Int,
        candidatesByRegistryID: inout [UInt64: DebugAVProbeCandidate],
        insertionOrder: inout Int
    ) {
#if DEBUG
        guard currentDepth <= maxDepth else { return }

        var iterator: io_iterator_t = 0
        let status = IORegistryEntryGetChildIterator(service, kIOServicePlane, &iterator)
        guard status == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iterator) }

        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }

            debugAddAVProbeCandidate(
                child,
                role: "\(rolePrefix)-child\(currentDepth)",
                candidatesByRegistryID: &candidatesByRegistryID,
                insertionOrder: &insertionOrder
            )
            debugCollectAVProbeDescendants(
                from: child,
                rolePrefix: "\(rolePrefix)-child\(currentDepth)",
                currentDepth: currentDepth + 1,
                maxDepth: maxDepth,
                candidatesByRegistryID: &candidatesByRegistryID,
                insertionOrder: &insertionOrder
            )
        }
#else
        _ = service
        _ = rolePrefix
        _ = currentDepth
        _ = maxDepth
        _ = &candidatesByRegistryID
        _ = &insertionOrder
#endif
    }

    private func debugAddAVProbeCandidate(
        _ service: io_service_t,
        role: String,
        candidatesByRegistryID: inout [UInt64: DebugAVProbeCandidate],
        insertionOrder: inout Int
    ) {
#if DEBUG
        guard let className = serviceClassName(service),
              debugIsAVProbeRelevantClass(className) else {
            return
        }

        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registryID)
        guard registryID != 0 else { return }

        if var existing = candidatesByRegistryID[registryID] {
            if !existing.roles.contains(role) {
                existing.roles.append(role)
                candidatesByRegistryID[registryID] = existing
            }
            return
        }

        guard IOObjectRetain(service) == KERN_SUCCESS else { return }
        candidatesByRegistryID[registryID] = DebugAVProbeCandidate(
            service: service,
            className: className,
            registryID: registryID,
            roles: [role],
            insertionOrder: insertionOrder
        )
        insertionOrder += 1
#else
        _ = service
        _ = role
        _ = &candidatesByRegistryID
        _ = &insertionOrder
#endif
    }

    private func debugIsAVProbeRelevantClass(_ className: String) -> Bool {
        className.hasPrefix("DCPAV")
            || className.hasPrefix("DCPDP")
            || className.hasPrefix("AppleDCP")
    }

    private func debugFramebufferI2CProbeSummary(service: io_service_t, prefix: String) -> String {
#if DEBUG
        let className = serviceClassName(service) ?? "unknown"
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registryID)

        var busCount: IOItemCount = 0
        let busCountStatus = IOFBGetI2CInterfaceCount(service, &busCount)
        guard busCountStatus == KERN_SUCCESS else {
            return "\(prefix)={class=\(className),id=\(registryID),busCountStatus=\(busCountStatus)}"
        }
        guard busCount > 0 else {
            return "\(prefix)={class=\(className),id=\(registryID),busCount=0}"
        }

        var busSummaries: [String] = []

        for busIndex in 0..<busCount {
            var interface: io_service_t = 0
            let copyStatus = IOFBCopyI2CInterfaceForBus(service, IOOptionBits(busIndex), &interface)
            guard copyStatus == KERN_SUCCESS else {
                busSummaries.append("bus\(busIndex):copy=\(copyStatus)")
                continue
            }

            var connect: IOI2CConnectRef?
            let openStatus = IOI2CInterfaceOpen(interface, IOOptionBits(), &connect)
            IOObjectRelease(interface)
            guard openStatus == KERN_SUCCESS, let connect else {
                busSummaries.append("bus\(busIndex):open=\(openStatus)")
                continue
            }

            let response = readDDCFeature(controlID: DDCConstants.inputSourceControlID, connect: connect)
            _ = IOI2CInterfaceClose(connect, IOOptionBits())

            if let response {
                busSummaries.append("bus\(busIndex):ok current=\(String(format: "0x%02X", response.currentValue)) max=\(String(format: "0x%02X", response.maximumValue)) raw=[\(response.rawReply.map { String(format: "%02X", $0) }.joined(separator: " "))]")
            } else {
                busSummaries.append("bus\(busIndex):read-failed")
            }
        }

        return "\(prefix)={class=\(className),id=\(registryID),busCount=\(busCount),\(busSummaries.joined(separator: ","))}"
#else
        _ = service
        _ = prefix
        return ""
#endif
    }

    private func debugFramebufferDescriptor(service: io_service_t) -> String {
#if DEBUG
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registryID)
        let className = serviceClassName(service) ?? "unknown"
        let identity = debugFramebufferIdentity(service: service)
        let identitySummary = identity.map(debugIdentitySummary(_:)) ?? "vendor=0 product=0 serial=0 name="
        return "\(className)@\(registryID){\(identitySummary)}"
#else
        _ = service
        return ""
#endif
    }

    private func debugFramebufferIdentity(service: io_service_t) -> DisplayIdentity? {
        guard let infoDictionary = IODisplayCreateInfoDictionary(service, IOOptionBits(kIODisplayMatchingInfo))?
            .takeRetainedValue() as? [String: Any] else {
            return nil
        }

        let vendorID = (infoDictionary[kDisplayVendorID] as? NSNumber)?.uint32Value ?? 0
        let productID = (infoDictionary[kDisplayProductID] as? NSNumber)?.uint32Value ?? 0
        let serialNumber = (infoDictionary[kDisplaySerialNumber] as? NSNumber)?.uint32Value ?? 0
        let displayName = (infoDictionary[kDisplayProductName] as? [String: String])?.values.first ?? ""

        return DisplayIdentity(
            vendorID: vendorID,
            productID: productID,
            serialNumber: serialNumber,
            displayName: displayName
        )
    }

    private func debugAVCandidateAttemptSummary(
        displayID: CGDirectDisplayID,
        className: String,
        service: io_service_t,
        candidateUUID: String?,
        location: String,
        candidateIdentity: DisplayIdentity?,
        roleSummary: String,
        ioAVServiceFunctions: IOAVServiceFunctions
    ) -> String {
#if DEBUG
        _ = displayID
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registryID)
        let uuid = candidateUUID ?? "nil"
        let identitySummary = candidateIdentity.map(debugIdentitySummary(_:)) ?? "vendor=0 product=0 serial=0 name="
        let userClientClass = (ioRegistryProperties(for: service)?["IOUserClientClass"] as? String) ?? "nil"
        let openSummary = debugIOServiceOpenSummary(service: service)

        guard let unmanagedService = ioAVServiceFunctions.createWithService(kCFAllocatorDefault, service) else {
            return "\(className)@\(registryID){via=\(roleSummary),loc=\(location),uuid=\(uuid),userClient=\(userClientClass),open=\(openSummary),\(identitySummary),create=fail}"
        }

        let avService = unmanagedService.takeRetainedValue()
        var edidRef: Unmanaged<CFData>?
        let copyEDIDStatus = ioAVServiceFunctions.copyEDID(avService, &edidRef)
        if copyEDIDStatus == KERN_SUCCESS {
            _ = edidRef?.takeRetainedValue()
        }

        return "\(className)@\(registryID){via=\(roleSummary),loc=\(location),uuid=\(uuid),userClient=\(userClientClass),open=\(openSummary),\(identitySummary),create=ok,copyEDID=\(copyEDIDStatus),read=skipped}"
#else
        _ = displayID
        _ = className
        _ = service
        _ = candidateUUID
        _ = location
        _ = candidateIdentity
        _ = roleSummary
        _ = ioAVServiceFunctions
        return ""
#endif
    }

    private func debugIOServiceOpenSummary(service: io_service_t) -> String {
#if DEBUG
        let typeCandidates: [UInt32] = [0, 1, 2, 3]
        let statuses = typeCandidates.map { type -> String in
            var connect: io_connect_t = 0
            let status = IOServiceOpen(service, mach_task_self_, type, &connect)
            if status == KERN_SUCCESS, connect != 0 {
                IOServiceClose(connect)
            }
            return "\(type):\(status)"
        }
        return "[\(statuses.joined(separator: ","))]"
#else
        _ = service
        return ""
#endif
    }

    private func debugLogSessionProbe(
        displayIDs: [CGDirectDisplayID],
        edidUUIDByDisplayID: [CGDirectDisplayID: String],
        hpmByDisplayID: [CGDirectDisplayID: HPMDisplaySnapshot],
        dcpRemotePortByDisplayID: [CGDirectDisplayID: DCPRemotePortSnapshot]
    ) {
#if DEBUG
        _ = displayIDs
        _ = edidUUIDByDisplayID
        _ = hpmByDisplayID
        _ = dcpRemotePortByDisplayID
#endif
    }

    private func debugLogComprehensiveDiagnostics(
        displayIDs: [CGDirectDisplayID],
        activeDisplaySet: Set<CGDirectDisplayID>,
        edidUUIDByDisplayID: [CGDirectDisplayID: String],
        transportByDisplayID: [CGDirectDisplayID: DisplayTransportSnapshot],
        hpmByDisplayID: [CGDirectDisplayID: HPMDisplaySnapshot],
        dcpRemotePortByDisplayID: [CGDirectDisplayID: DCPRemotePortSnapshot],
        auxiliaryRegistryByDisplayID: [CGDirectDisplayID: [AuxiliaryRegistrySnapshot]],
        ddcInputSourcesByDisplayID: [CGDirectDisplayID: DDCInputSourceSnapshot]
    ) {
#if DEBUG
        for displayID in displayIDs {
            let displayName = NSScreen.screens.first(where: { $0.displayID == displayID })?.localizedName ?? "Display \(displayID)"
            let cgService = cgDisplayIOServicePort?(displayID) ?? 0
            let cgClass = cgService == 0 ? "none" : (serviceClassName(cgService) ?? "unknown")
            var cgBusCount: IOItemCount = 0
            let cgBusStatus = cgService == 0 ? kern_return_t(-1) : IOFBGetI2CInterfaceCount(cgService, &cgBusCount)

            let cgsService = cgsServiceForDisplay(displayID)
            let cgsClass = cgsService.map { serviceClassName($0) ?? "unknown" } ?? "none"
            var cgsBusCount: IOItemCount = 0
            let cgsBusStatus = cgsService.map { IOFBGetI2CInterfaceCount($0, &cgsBusCount) } ?? kern_return_t(-1)

            let uuid = edidUUIDByDisplayID[displayID] ?? "nil"
            let transportSummary = transportByDisplayID[displayID].map(debugSnapshotSummary(_:)) ?? "transport(none)"
            let hpmSummary = hpmByDisplayID[displayID].map(debugHPMSnapshotSummary(_:)) ?? "hpm=none"
            let dcpSummary = dcpRemotePortByDisplayID[displayID].map(debugDCPRemotePortSummary(_:)) ?? "dcp=none"
            let auxSummary = auxiliaryRegistryByDisplayID[displayID].map(debugAuxiliaryRegistrySummary(_:)) ?? "aux=[]"
            let ddcSummary = ddcInputSourcesByDisplayID[displayID].map(debugDDCSnapshotSummary(_:)) ?? "ddc(none)"
            let ddcStages = pendingDDCDebugStages[displayID, default: []]
            let ddcStageSummary = ddcStages.isEmpty ? "ddcStages=[]" : "ddcStages=[\(ddcStages.joined(separator: " | "))]"

            print("[LightsOut][Diag] \(displayName) [id=\(displayID), active=\(activeDisplaySet.contains(displayID)), uuid=\(uuid), cgServiceClass=\(cgClass), cgBusStatus=\(cgBusStatus), cgBusCount=\(cgBusCount), cgsServiceClass=\(cgsClass), cgsBusStatus=\(cgsBusStatus), cgsBusCount=\(cgsBusCount)] \(transportSummary) \(hpmSummary) \(dcpSummary) \(auxSummary) \(ddcSummary) \(ddcStageSummary)")

            if let transportSnapshot = transportByDisplayID[displayID] {
                debugLogRegistryPropertyDiff(
                    scope: "transport:\(displayID)",
                    services: transportSnapshot.subtreeServices,
                    label: "\(displayName) transport"
                )
            }
            if let hpmSnapshot = hpmByDisplayID[displayID] {
                debugLogRegistryPropertyDiff(
                    scope: "hpm:\(hpmSnapshot.hpmRegistryID)",
                    services: hpmSnapshot.subtreeServices,
                    label: "\(displayName) hpm"
                )
            }
            if let dcpSnapshot = dcpRemotePortByDisplayID[displayID] {
                debugLogRegistryPropertyDiff(
                    scope: "dcp:\(dcpSnapshot.registryID)",
                    services: dcpSnapshot.subtreeServices,
                    label: "\(displayName) dcp"
                )
            }
            if let auxSnapshots = auxiliaryRegistryByDisplayID[displayID] {
                for auxSnapshot in auxSnapshots {
                    debugLogRegistryPropertyDiff(
                        scope: "aux:\(auxSnapshot.className):\(auxSnapshot.registryID)",
                        services: auxSnapshot.subtreeServices,
                        label: "\(displayName) \(auxSnapshot.className)"
                    )
                }
            }
        }
#endif
    }

    private func debugLogSwiftDDCProbe(
        displayIDs: [CGDirectDisplayID],
        edidUUIDByDisplayID: [CGDirectDisplayID: String],
        ddcInputSourcesByDisplayID: [CGDirectDisplayID: DDCInputSourceSnapshot],
        expectedInputSourceByDisplayID: [CGDirectDisplayID: UInt16?],
        ddcAvailabilityByDisplayID: [CGDirectDisplayID: Bool],
        finalAvailabilityByDisplayID: [CGDirectDisplayID: Bool],
        resolvedStateByDisplayID: [CGDirectDisplayID: DisplayState],
        ddcMatchCountByDisplayID: [CGDirectDisplayID: Int],
        ddcMismatchCountByDisplayID: [CGDirectDisplayID: Int],
        ddcMissingCountByDisplayID: [CGDirectDisplayID: Int]
    ) {
#if DEBUG
        for displayID in displayIDs where CGDisplayIsBuiltin(displayID) == 0 {
            let displayName = NSScreen.screens.first(where: { $0.displayID == displayID })?.localizedName ?? "Display \(displayID)"
            let targetIdentity = DisplayIdentity(displayID: displayID, displayName: displayName)
            let targetUUID = edidUUIDByDisplayID[displayID] ?? "nil"
            let ddcSnapshot = ddcInputSourcesByDisplayID[displayID]
            let currentInput = ddcInputSourcesByDisplayID[displayID]?.currentValue
            let expectedInput = expectedInputSourceByDisplayID[displayID] ?? nil
            let ddcAvailable = ddcAvailabilityByDisplayID[displayID] ?? true
            let finalAvailable = finalAvailabilityByDisplayID[displayID] ?? true
            let state = resolvedStateByDisplayID[displayID] ?? .disconnected
            let matchCount = ddcMatchCountByDisplayID[displayID] ?? 0
            let mismatchCount = ddcMismatchCountByDisplayID[displayID] ?? 0
            let missingCount = ddcMissingCountByDisplayID[displayID] ?? 0
            let decisionSummary = "decision={expected=\(debugHexByte(expectedInput)),current=\(debugHexByte(currentInput)),matchCount=\(matchCount),mismatchCount=\(mismatchCount),missingCount=\(missingCount),ddcAvailable=\(ddcAvailable),available=\(finalAvailable),state=\(debugStateName(state))}"
            let ddcSummary = debugChosenDDCSnapshotSummary(ddcSnapshot)

            guard isVerboseDDCDebugEnabled else {
                let hasMismatch = expectedInput != nil && currentInput != nil && expectedInput != currentInput
                let shouldLogCompactSummary = hasMismatch || !ddcAvailable || !finalAvailable || matchCount > 0 || mismatchCount > 0
                guard shouldLogCompactSummary else { continue }
                print("[LightsOut][DDC] \(displayName) [id=\(displayID)] \(ddcSummary) \(decisionSummary)")
                continue
            }

            let stages = [
                "target={\(debugIdentitySummary(targetIdentity)) uuid=\(targetUUID)}",
                debugCGDisplayServiceProbeSummary(displayID: displayID),
                debugCGSServiceProbeSummary(displayID: displayID),
                debugMatchedFramebufferProbeSummary(displayID: displayID, targetIdentity: targetIdentity),
                debugAVServiceProbeSummary(displayID: displayID, targetIdentity: targetIdentity, targetUUID: edidUUIDByDisplayID[displayID]),
                ddcSummary,
                decisionSummary
            ]

            print("[LightsOut][DDCProbe] \(displayName) [id=\(displayID)] \(stages.joined(separator: " | "))")
        }
#endif
    }

    private func readDDCFeature(controlID: UInt8, connect: IOI2CConnectRef) -> DDCReadResponse? {
        var sendBuffer = [UInt8](
            [
                DDCConstants.hostAddress,
                0x82,
                0x01,
                controlID
            ]
        )
        sendBuffer.append(checksum(for: sendBuffer, address: DDCConstants.displayWriteAddress))

        var replyBuffer = [UInt8](repeating: 0, count: 16)
        var request = IOI2CRequest()
        request.sendTransactionType = IOOptionBits(kIOI2CSimpleTransactionType)
        request.replyTransactionType = IOOptionBits(kIOI2CDDCciReplyTransactionType)
        request.sendAddress = UInt32(DDCConstants.displayWriteAddress)
        request.replyAddress = UInt32(DDCConstants.displayReadAddress)
        request.sendBytes = UInt32(sendBuffer.count)
        request.replyBytes = UInt32(replyBuffer.count)
        request.minReplyDelay = UInt64(10_000_000)

        return sendBuffer.withUnsafeMutableBufferPointer { sendPointer in
            replyBuffer.withUnsafeMutableBufferPointer { replyPointer in
                request.sendBuffer = vm_address_t(UInt(bitPattern: sendPointer.baseAddress))
                request.replyBuffer = vm_address_t(UInt(bitPattern: replyPointer.baseAddress))

                let status = IOI2CSendRequest(connect, IOOptionBits(), &request)
                guard status == KERN_SUCCESS, request.result == KERN_SUCCESS else {
                    return nil
                }

                let rawReply = Array(replyPointer.prefix(Int(request.replyBytes)))
                return parseDDCReadReply(rawReply, controlID: controlID)
            }
        }
    }

    private func readDDCFeature(controlID: UInt8, avService: IOAVServiceRef) -> DDCReadResponse? {
        debugReadDDCFeature(controlID: controlID, avService: avService).response
    }

    private func debugReadDDCFeature(controlID: UInt8, avService: IOAVServiceRef) -> AVDDCReadAttempt {
        guard let ioAVServiceFunctions else {
            return AVDDCReadAttempt(
                writeStatus: kern_return_t(-1),
                readStatus: kern_return_t(-1),
                rawReply: [],
                response: nil
            )
        }

        var writeBuffer = [UInt8](repeating: 0, count: 4)
        writeBuffer[0] = 0x82
        writeBuffer[1] = 0x01
        writeBuffer[2] = controlID
        writeBuffer[3] = DDCConstants.displayWriteAddress ^ UInt8(DDCConstants.ddcDataAddress) ^ writeBuffer[0] ^ writeBuffer[1] ^ writeBuffer[2]

        let writeStatus = writeBuffer.withUnsafeMutableBytes { bytes in
            ioAVServiceFunctions.writeI2C(
                avService,
                DDCConstants.ddcChipAddress,
                DDCConstants.ddcDataAddress,
                bytes.baseAddress,
                UInt32(bytes.count)
            )
        }
        guard writeStatus == KERN_SUCCESS else {
            return AVDDCReadAttempt(
                writeStatus: writeStatus,
                readStatus: kern_return_t(-1),
                rawReply: [],
                response: nil
            )
        }

        usleep(50_000)

        var replyBuffer = [UInt8](repeating: 0, count: 12)
        let readStatus = replyBuffer.withUnsafeMutableBytes { bytes in
            ioAVServiceFunctions.readI2C(
                avService,
                DDCConstants.ddcChipAddress,
                DDCConstants.ddcDataAddress,
                bytes.baseAddress,
                UInt32(bytes.count)
            )
        }
        guard readStatus == KERN_SUCCESS else {
            return AVDDCReadAttempt(
                writeStatus: writeStatus,
                readStatus: readStatus,
                rawReply: [],
                response: nil
            )
        }

        let rawReply = replyBuffer
        return AVDDCReadAttempt(
            writeStatus: writeStatus,
            readStatus: readStatus,
            rawReply: rawReply,
            response: parseDDCReadReply(rawReply, controlID: controlID)
        )
    }

    private func parseDDCReadReply(_ rawReply: [UInt8], controlID: UInt8) -> DDCReadResponse? {
        guard rawReply.count >= 8,
              let opcodeIndex = rawReply.firstIndex(of: DDCConstants.getVCPFeatureReplyOpcode),
              opcodeIndex + 7 < rawReply.count else {
            return nil
        }

        let resultCode = rawReply[opcodeIndex + 1]
        let returnedControlID = rawReply[opcodeIndex + 2]
        guard resultCode == 0x00, returnedControlID == controlID else { return nil }

        let maximumValue = (UInt16(rawReply[opcodeIndex + 4]) << 8) | UInt16(rawReply[opcodeIndex + 5])
        let currentValue = (UInt16(rawReply[opcodeIndex + 6]) << 8) | UInt16(rawReply[opcodeIndex + 7])

        return DDCReadResponse(
            currentValue: currentValue,
            maximumValue: maximumValue,
            rawReply: rawReply
        )
    }

    private func checksum(for payload: [UInt8], address: UInt8) -> UInt8 {
        payload.reduce(address, ^)
    }

    private func parseEDIDMetadata(_ edid: Data) -> EDIDMetadata? {
        guard edid.count >= 16 else { return nil }

        let bytes = [UInt8](edid)
        let manufacturerWord = (UInt16(bytes[8]) << 8) | UInt16(bytes[9])
        let first = UInt8((manufacturerWord >> 10) & 0x1F) + 64
        let second = UInt8((manufacturerWord >> 5) & 0x1F) + 64
        let third = UInt8(manufacturerWord & 0x1F) + 64
        let vendorString = String(bytes: [first, second, third], encoding: .ascii)

        let productID = UInt32(UInt16(bytes[10]) | (UInt16(bytes[11]) << 8))
        let serialNumber = UInt32(bytes[12])
            | (UInt32(bytes[13]) << 8)
            | (UInt32(bytes[14]) << 16)
            | (UInt32(bytes[15]) << 24)

        return EDIDMetadata(
            vendorID: vendorString.flatMap(Self.legacyVendorID(for:)),
            productID: productID,
            serialNumber: serialNumber,
            productName: parseEDIDDisplayName(bytes) ?? "Display"
        )
    }

    private func parseEDIDDisplayName(_ bytes: [UInt8]) -> String? {
        guard bytes.count >= 128 else { return nil }

        for offset in stride(from: 54, through: 108, by: 18) {
            let block = Array(bytes[offset..<(offset + 18)])
            if block[0] == 0x00, block[1] == 0x00, block[2] == 0x00, block[3] == 0xFC {
                let nameBytes = block[5..<18].prefix { $0 != 0x0A && $0 != 0x00 }
                let name = String(bytes: nameBytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
                if let name, !name.isEmpty {
                    return name
                }
            }
        }

        return nil
    }

    private static func legacyVendorID(for code: String) -> UInt32? {
        guard code.count == 3 else { return nil }
        let values = code.utf8.map { UInt32($0) - 64 }
        guard values.count == 3, values.allSatisfy({ (1...26).contains($0) }) else { return nil }
        return (values[0] << 10) | (values[1] << 5) | values[2]
    }

    private func isDDCAvailable(_ snapshot: DDCInputSourceSnapshot?, expectedInputSource: UInt16?) -> Bool {
        guard let snapshot else { return true }
        guard let expectedInputSource else { return true }
        return snapshot.currentValue == expectedInputSource
    }

    private func resolveDDCAvailability(
        for displayIdentity: DisplayIdentity,
        snapshot: DDCInputSourceSnapshot?,
        expectedInputSource: UInt16?,
        wasAvailable: Bool
    ) -> Bool {
        guard let expectedInputSource else {
            ddcMatchCountByDisplayIdentity[displayIdentity] = 0
            ddcMismatchCountByDisplayIdentity[displayIdentity] = 0
            ddcMissingCountByDisplayIdentity[displayIdentity] = 0
            return true
        }

        guard let snapshot else {
            ddcMatchCountByDisplayIdentity[displayIdentity] = 0
            ddcMismatchCountByDisplayIdentity[displayIdentity] = 0
            let missingCount = (ddcMissingCountByDisplayIdentity[displayIdentity] ?? 0) + 1
            ddcMissingCountByDisplayIdentity[displayIdentity] = missingCount
            return !wasAvailable ? false : missingCount < 2
        }

        guard snapshot.currentValue != expectedInputSource else {
            let matchCount = (ddcMatchCountByDisplayIdentity[displayIdentity] ?? 0) + 1
            ddcMatchCountByDisplayIdentity[displayIdentity] = matchCount
            ddcMismatchCountByDisplayIdentity[displayIdentity] = 0
            ddcMissingCountByDisplayIdentity[displayIdentity] = 0
            return wasAvailable || matchCount >= 2
        }

        ddcMatchCountByDisplayIdentity[displayIdentity] = 0
        ddcMissingCountByDisplayIdentity[displayIdentity] = 0
        let mismatchCount = (ddcMismatchCountByDisplayIdentity[displayIdentity] ?? 0) + 1
        ddcMismatchCountByDisplayIdentity[displayIdentity] = mismatchCount
        return !wasAvailable ? false : mismatchCount < 2
    }

    private func transportMatchScore(
        snapshot: DisplayTransportSnapshot,
        displayName: String,
        displayModel: UInt32,
        displaySerial: UInt32
    ) -> Int {
        var score = 0

        if let productName = snapshot.productName, productName == displayName {
            score += 3
        }
        if let productID = snapshot.productID, productID == displayModel, displayModel != 0 {
            score += 5
        }
        if let serialNumber = snapshot.serialNumber, serialNumber == displaySerial, displaySerial != 0 {
            score += 5
        }

        return score
    }

    private func isTransportAvailable(_ snapshot: DisplayTransportSnapshot) -> Bool {
        if snapshot.isActive { return true }
        if let sinkCount = snapshot.sinkCount, sinkCount > 0 { return true }
        if let linkRate = snapshot.linkRate, linkRate > 0 { return true }
        return false
    }

    private func ioRegistryProperties(for service: io_service_t) -> [String: Any]? {
        var propertiesRef: Unmanaged<CFMutableDictionary>?
        let result = IORegistryEntryCreateCFProperties(service, &propertiesRef, kCFAllocatorDefault, 0)
        guard result == KERN_SUCCESS,
              let properties = propertiesRef?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return properties
    }

    private func stringProperty(named name: String, in properties: [String: Any], fallback: [String: Any]) -> String? {
        (properties[name] as? String) ?? (fallback[name] as? String)
    }

    private func uint32Property(named name: String, in properties: [String: Any], fallback: [String: Any] = [:]) -> UInt32? {
        if let number = properties[name] as? NSNumber {
            return number.uint32Value
        }
        if let number = fallback[name] as? NSNumber {
            return number.uint32Value
        }
        return nil
    }

    private func intProperty(named name: String, in properties: [String: Any]) -> Int? {
        if let number = properties[name] as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func recursiveStringProperty(named name: String, on service: io_service_t) -> String? {
        IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            name as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) as? String
    }

    private func serviceClassName(_ service: io_service_t) -> String? {
        var className = [CChar](repeating: 0, count: 128)
        let status = IOObjectGetClass(service, &className)
        guard status == KERN_SUCCESS else { return nil }
        return String(cString: className)
    }

    private func debugLogDisplayResolution(
        displayID: CGDirectDisplayID,
        displayName: String,
        isBuiltIn: Bool,
        isManagedHidden: Bool,
        isActive: Bool,
        snapshot: DisplayTransportSnapshot?,
        hpmSnapshot: HPMDisplaySnapshot?,
        dcpSnapshot: DCPRemotePortSnapshot?,
        ddcSnapshot: DDCInputSourceSnapshot?,
        expectedInputSource: UInt16?,
        state: DisplayState,
        isAvailable: Bool
    ) {
#if DEBUG
        _ = displayID
        _ = displayName
        _ = isBuiltIn
        _ = isManagedHidden
        _ = isActive
        _ = snapshot
        _ = hpmSnapshot
        _ = dcpSnapshot
        _ = ddcSnapshot
        _ = expectedInputSource
        _ = state
        _ = isAvailable
#endif
    }

    private func debugStateName(_ state: DisplayState) -> String {
        switch state {
        case .active:
            return "active"
        case .disconnected:
            return "disconnected"
        case .pending:
            return "pending"
        }
    }

    private func debugSnapshotSummary(_ snapshot: DisplayTransportSnapshot) -> String {
        let name = snapshot.productName ?? "unknown"
        let productID = snapshot.productID.map(String.init) ?? "nil"
        let serial = snapshot.serialNumber.map(String.init) ?? "nil"
        let edidUUID = snapshot.edidUUID ?? "nil"
        let active = snapshot.isActive ? "yes" : "no"
        let sinkCount = snapshot.sinkCount.map(String.init) ?? "nil"
        let linkRate = snapshot.linkRate.map(String.init) ?? "nil"
        let subtreeHash = snapshot.subtreeHash ?? "nil"
        return "\(name) [registryID=\(snapshot.registryID), productID=\(productID), serial=\(serial), edidUUID=\(edidUUID), active=\(active), sink=\(sinkCount), link=\(linkRate), hash=\(subtreeHash)]"
    }

    private func debugDCPRemotePortSummary(_ snapshot: DCPRemotePortSnapshot) -> String {
        let name = snapshot.productName ?? "unknown"
        let edidUUID = snapshot.edidUUID ?? "nil"
        let sinkActive = snapshot.sinkActive.map(String.init) ?? "nil"
        let linkRate = snapshot.linkRate.map(String.init) ?? "nil"
        let laneCount = snapshot.laneCount.map(String.init) ?? "nil"
        let activate = snapshot.activate.map(String.init) ?? "nil"
        let registered = snapshot.registered.map(String.init) ?? "nil"
        let action = snapshot.lastAction ?? "nil"
        let eventCount = String(snapshot.eventCount)
        let eventTime = snapshot.lastEventTime.map(String.init) ?? "nil"
        let eventClass = snapshot.lastEventClass ?? "nil"
        let eventState: String
        if let lastStateName = snapshot.lastStateName,
           let lastStateValue = snapshot.lastStateValue {
            eventState = "\(lastStateName)=\(lastStateValue)"
        } else {
            eventState = "nil"
        }
        let subtreeHash = snapshot.subtreeHash ?? "nil"
        return "dcp=\(name) [registryID=\(snapshot.registryID), edidUUID=\(edidUUID), sink=\(sinkActive), link=\(linkRate), lanes=\(laneCount), activate=\(activate), registered=\(registered), action=\(action), events=\(eventCount), lastTime=\(eventTime), lastClass=\(eventClass), lastState=\(eventState), hash=\(subtreeHash)]"
    }

    private func debugHPMSnapshotSummary(_ snapshot: HPMDisplaySnapshot) -> String {
        let name = snapshot.productName ?? "unknown"
        let productID = snapshot.productID.map(String.init) ?? "nil"
        let serial = snapshot.serialNumber.map(String.init) ?? "nil"
        let edidUUID = snapshot.edidUUID ?? "nil"
        let connectionActive = snapshot.connectionActive ? "yes" : "no"
        let activeCable = snapshot.activeCable ? "yes" : "no"
        let transportsActive = snapshot.transportsActive.joined(separator: ",")
        let transportsProvisioned = snapshot.transportsProvisioned.joined(separator: ",")
        let transportsUnauthorized = snapshot.transportsUnauthorized.joined(separator: ",")
        let subtreeHash = snapshot.subtreeHash ?? "nil"
        return "hpm=\(name) [registryID=\(snapshot.hpmRegistryID), dpRegistryID=\(snapshot.displayPortRegistryID), productID=\(productID), serial=\(serial), edidUUID=\(edidUUID), connection=\(connectionActive), cable=\(activeCable), active=\(transportsActive), provisioned=\(transportsProvisioned), unauthorized=\(transportsUnauthorized), hash=\(subtreeHash)]"
    }

    private func debugAuxiliaryRegistrySummary(_ snapshots: [AuxiliaryRegistrySnapshot]) -> String {
        let parts = snapshots.map { snapshot in
            let uuid = snapshot.edidUUID ?? "nil"
            let location = snapshot.location ?? "nil"
            let productID = snapshot.identity.map { String($0.productID) } ?? "nil"
            let serial = snapshot.identity.map { String($0.serialNumber) } ?? "nil"
            let subtreeHash = snapshot.subtreeHash ?? "nil"
            return "\(snapshot.className)@\(snapshot.registryID){uuid=\(uuid),loc=\(location),product=\(productID),serial=\(serial),hash=\(subtreeHash)}"
        }
        return "aux=[\(parts.joined(separator: ", "))]"
    }

    private func debugDDCSnapshotSummary(_ snapshot: DDCInputSourceSnapshot) -> String {
        let rawReply = snapshot.rawReply.map { String(format: "%02X", $0) }.joined(separator: " ")
        return "ddc(bus=\(snapshot.busIndex), current=\(String(format: "0x%02X", snapshot.currentValue)), max=\(String(format: "0x%02X", snapshot.maximumValue)), raw=[\(rawReply)])"
    }

    private func debugChosenDDCSnapshotSummary(_ snapshot: DDCInputSourceSnapshot?) -> String {
        guard let snapshot else { return "ddc=none" }
        return "ddc={bus=\(snapshot.busIndex),current=\(String(format: "0x%02X", snapshot.currentValue)),max=\(String(format: "0x%02X", snapshot.maximumValue))}"
    }

    private var isVerboseRegistryDebugEnabled: Bool {
#if DEBUG
        isVerboseDDCDebugEnabled
#else
        false
#endif
    }

    private var isLegacyDDCFallbackEnabled: Bool {
#if DEBUG
        isVerboseDDCDebugEnabled
#else
        false
#endif
    }

    private func debugLogDDCStage(displayID: CGDirectDisplayID, displayName: String, message: String) {
#if DEBUG
        guard isVerboseDDCDebugEnabled else { return }
        _ = displayName
        let suppressedPrefixes = [
            "target ",
            "candidate ",
            "avservice-create-class=",
            "avservice-create-failed-class="
        ]
        if suppressedPrefixes.contains(where: { message.hasPrefix($0) }) {
            return
        }
        pendingDDCDebugStages[displayID, default: []].append(message)
#endif
    }

    private func debugIdentitySummary(_ identity: DisplayIdentity) -> String {
        "vendor=\(identity.vendorID) product=\(identity.productID) serial=\(identity.serialNumber) name=\(identity.displayName)"
    }

    private func debugHexByte(_ value: UInt16?) -> String {
        guard let value else { return "nil" }
        return String(format: "0x%02X", value)
    }

    private func hpmMatchScore(
        snapshot: HPMDisplaySnapshot,
        targetUUID: String?,
        displayName: String,
        displayModel: UInt32,
        displaySerial: UInt32
    ) -> Int {
        var score = 0

        if let targetUUID, let edidUUID = snapshot.edidUUID, targetUUID == edidUUID {
            score += 100
        }
        if let productID = snapshot.productID, productID == displayModel, displayModel != 0 {
            score += 10
        }
        if let serialNumber = snapshot.serialNumber, serialNumber == displaySerial, displaySerial != 0 {
            score += 10
        }
        if let productName = snapshot.productName, productName == displayName {
            score += 3
        }

        return score
    }

    private func auxiliaryMatchScore(
        snapshot: AuxiliaryRegistrySnapshot,
        targetUUID: String?,
        displayName: String,
        displayModel: UInt32,
        displaySerial: UInt32
    ) -> Int {
        var score = 0

        if let targetUUID, let edidUUID = snapshot.edidUUID, targetUUID == edidUUID {
            score += 100
        }
        if let identity = snapshot.identity {
            if identity.productID == displayModel, displayModel != 0 {
                score += 20
            }
            if identity.serialNumber == displaySerial, displaySerial != 0 {
                score += 20
            }
            if identity.displayName == displayName, !displayName.isEmpty {
                score += 5
            }
        }

        return score
    }

    private func recursiveDisplayIdentity(on service: io_service_t) -> DisplayIdentity? {
        guard let displayAttributes = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            "DisplayAttributes" as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) as? [String: Any],
        let productAttributes = displayAttributes["ProductAttributes"] as? [String: Any],
        let productID = (productAttributes["ProductID"] as? NSNumber)?.uint32Value,
        let serialNumber = (productAttributes["SerialNumber"] as? NSNumber)?.uint32Value else {
            return nil
        }

        return DisplayIdentity(
            vendorID: (productAttributes["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
            productID: productID,
            serialNumber: serialNumber,
            displayName: (productAttributes["ProductName"] as? String) ?? ""
        )
    }

    private func debugRegistrySubtreeHash(for service: io_service_t) -> String? {
#if DEBUG
        var fragments: [String] = []
        appendDebugRegistryFragment(for: service, into: &fragments)

        var iterator: io_iterator_t = 0
        let status = IORegistryEntryCreateIterator(
            service,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard status == KERN_SUCCESS else {
            return String(fragments.joined(separator: "|").hashValue)
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }
            appendDebugRegistryFragment(for: child, into: &fragments)
        }

        return String(fragments.sorted().joined(separator: "|").hashValue)
#else
        return nil
#endif
    }

    private func appendDebugRegistryFragment(for service: io_service_t, into fragments: inout [String]) {
#if DEBUG
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registryID)
        let className = serviceClassName(service) ?? "unknown"
        let properties = ioRegistryProperties(for: service) ?? [:]
        let normalized = debugNormalizeRegistryValue(properties)
        fragments.append("\(className)#\(registryID)=\(normalized)")
#else
        _ = service
        _ = &fragments
#endif
    }

    private func debugNormalizeRegistryValue(_ value: Any) -> String {
        if let string = value as? String {
            return "\"\(string)\""
        }
        if let number = value as? NSNumber {
            return number.stringValue
        }
        if let bool = value as? Bool {
            return bool ? "true" : "false"
        }
        if let data = value as? Data {
            return "<\(data.prefix(16).map { String(format: "%02X", $0) }.joined())...len=\(data.count)>"
        }
        if let dictionary = value as? [String: Any] {
            let parts = dictionary.keys.sorted().map { key in
                "\(key):\(debugNormalizeRegistryValue(dictionary[key] ?? "nil"))"
            }
            return "{\(parts.joined(separator: ","))}"
        }
        if let array = value as? [Any] {
            return "[\(array.map(debugNormalizeRegistryValue(_:)).joined(separator: ","))]"
        }
        if CFGetTypeID(value as CFTypeRef) == CFBooleanGetTypeID() {
            return (value as? NSNumber)?.boolValue == true ? "true" : "false"
        }
        return String(describing: value)
    }

    private func debugRegistrySubtreeCapture(for service: io_service_t) -> [DebugRegistryServiceSnapshot]? {
#if DEBUG
        var snapshots: [DebugRegistryServiceSnapshot] = []
        appendDebugRegistryServiceSnapshot(for: service, into: &snapshots)

        var iterator: io_iterator_t = 0
        let status = IORegistryEntryCreateIterator(
            service,
            kIOServicePlane,
            IOOptionBits(kIORegistryIterateRecursively),
            &iterator
        )
        guard status == KERN_SUCCESS else {
            return snapshots
        }
        defer { IOObjectRelease(iterator) }

        while true {
            let child = IOIteratorNext(iterator)
            guard child != 0 else { break }
            defer { IOObjectRelease(child) }
            appendDebugRegistryServiceSnapshot(for: child, into: &snapshots)
        }

        return snapshots.sorted {
            if $0.className != $1.className { return $0.className < $1.className }
            return $0.registryID < $1.registryID
        }
#else
        return nil
#endif
    }

    private func appendDebugRegistryServiceSnapshot(for service: io_service_t, into snapshots: inout [DebugRegistryServiceSnapshot]) {
#if DEBUG
        var registryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(service, &registryID)
        let className = serviceClassName(service) ?? "unknown"
        let properties = ioRegistryProperties(for: service) ?? [:]
        var normalizedProperties: [String: String] = [:]
        for key in properties.keys.sorted() {
            normalizedProperties[key] = debugNormalizeRegistryValue(properties[key] ?? "nil")
        }
        snapshots.append(
            DebugRegistryServiceSnapshot(
                className: className,
                registryID: registryID,
                properties: normalizedProperties
            )
        )
#else
        _ = service
        _ = &snapshots
#endif
    }

    private func debugLogRegistryPropertyDiff(
        scope: String,
        services: [DebugRegistryServiceSnapshot]?,
        label: String
    ) {
#if DEBUG
        guard let services else { return }
        let current = Dictionary(uniqueKeysWithValues: services.map { ($0.scopeKey, $0.properties) })
        defer { previousDebugRegistryPropertiesByScope[scope] = current }

        guard let previous = previousDebugRegistryPropertiesByScope[scope] else { return }

        var changes: [String] = []
        for serviceKey in Set(previous.keys).union(current.keys).sorted() {
            switch (previous[serviceKey], current[serviceKey]) {
            case (nil, let currentProperties?):
                changes.append("\(serviceKey) added keys=\(currentProperties.keys.count)")
            case (let previousProperties?, nil):
                changes.append("\(serviceKey) removed keys=\(previousProperties.keys.count)")
            case (let previousProperties?, let currentProperties?):
                let changedKeys = Set(previousProperties.keys).union(currentProperties.keys).sorted().compactMap { key -> String? in
                    let before = previousProperties[key]
                    let after = currentProperties[key]
                    guard before != after else { return nil }
                    return key
                }

                guard !changedKeys.isEmpty else { continue }
                let preview = changedKeys.prefix(8).joined(separator: ",")
                let suffix = changedKeys.count > 8 ? ",..." : ""
                changes.append("\(serviceKey) changed[\(preview)\(suffix)]")
            case (nil, nil):
                continue
            }
        }

        guard !changes.isEmpty else { return }
        print("[LightsOut][Diff] \(label) \(changes.joined(separator: " ; "))")
#endif
    }
}

private struct DisplayTransportSnapshot {
    let registryID: UInt64
    let productName: String?
    let productID: UInt32?
    let serialNumber: UInt32?
    let edidUUID: String?
    let isActive: Bool
    let sinkCount: Int?
    let linkRate: Int?
    let subtreeHash: String?
    let subtreeServices: [DebugRegistryServiceSnapshot]?
}

private struct DCPRemotePortSnapshot {
    let registryID: UInt64
    let productName: String?
    let edidUUID: String?
    let sinkActive: Int?
    let linkRate: Int?
    let laneCount: Int?
    let activate: Int?
    let registered: Int?
    let lastAction: String?
    let eventCount: Int
    let lastEventTime: UInt64?
    let lastEventClass: String?
    let lastStateName: String?
    let lastStateValue: Int?
    let subtreeHash: String?
    let subtreeServices: [DebugRegistryServiceSnapshot]?
}

private struct HPMDisplaySnapshot {
    let hpmRegistryID: UInt64
    let displayPortRegistryID: UInt64
    let productName: String?
    let productID: UInt32?
    let serialNumber: UInt32?
    let edidUUID: String?
    let connectionActive: Bool
    let activeCable: Bool
    let transportsActive: [String]
    let transportsProvisioned: [String]
    let transportsUnauthorized: [String]
    let subtreeHash: String?
    let subtreeServices: [DebugRegistryServiceSnapshot]?
}

private struct AuxiliaryRegistrySnapshot {
    let className: String
    let registryID: UInt64
    let edidUUID: String?
    let location: String?
    let identity: DisplayIdentity?
    let subtreeHash: String?
    let subtreeServices: [DebugRegistryServiceSnapshot]?
}

private struct DebugAVProbeCandidate {
    let service: io_service_t
    let className: String
    let registryID: UInt64
    var roles: [String]
    let insertionOrder: Int
}

private struct DebugRegistryServiceSnapshot {
    let className: String
    let registryID: UInt64
    let properties: [String: String]

    var scopeKey: String {
        "\(className)#\(registryID)"
    }
}

private struct DDCReadResponse {
    let currentValue: UInt16
    let maximumValue: UInt16
    let rawReply: [UInt8]
}

private struct AVDDCReadAttempt {
    let writeStatus: kern_return_t
    let readStatus: kern_return_t
    let rawReply: [UInt8]
    let response: DDCReadResponse?
}

private struct DDCInputSourceSnapshot {
    let busIndex: Int
    let currentValue: UInt16
    let maximumValue: UInt16
    let rawReply: [UInt8]
}

private struct EDIDMetadata {
    let vendorID: UInt32?
    let productID: UInt32
    let serialNumber: UInt32
    let productName: String
}

private struct AVServiceMetadata {
    let identity: DisplayIdentity
}

private struct DisplayIdentity: Hashable {
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32
    let displayName: String

    init(displayID: CGDirectDisplayID, displayName: String) {
        self.vendorID = CGDisplayVendorNumber(displayID)
        self.productID = CGDisplayModelNumber(displayID)
        self.serialNumber = CGDisplaySerialNumber(displayID)
        self.displayName = displayName
    }

    init(vendorID: UInt32?, productID: UInt32, serialNumber: UInt32, displayName: String) {
        self.vendorID = vendorID ?? 0
        self.productID = productID
        self.serialNumber = serialNumber
        self.displayName = displayName
    }

    func matches(_ other: DisplayIdentity) -> Bool {
        let vendorMatches = vendorID == 0 || other.vendorID == 0 || vendorID == other.vendorID
        let productMatches = productID == other.productID
        let serialMatches = serialNumber == 0 || other.serialNumber == 0 || serialNumber == other.serialNumber
        return vendorMatches && productMatches && serialMatches
    }
}

private struct DisplayHardwareIdentity: Hashable {
    let vendorID: UInt32
    let productID: UInt32
    let serialNumber: UInt32
}

private struct IOAVServiceFunctions {
    let createWithService: DisplaysViewModel.IOAVServiceCreateWithServiceFunction
    let copyEDID: DisplaysViewModel.IOAVServiceCopyEDIDFunction
    let readI2C: DisplaysViewModel.IOAVServiceReadI2CFunction
    let writeI2C: DisplaysViewModel.IOAVServiceWriteI2CFunction
}

extension DisplaysViewModel {
    fileprivate func reconnectDisplay(display: DisplayInfo) throws(DisplayError) {
        if display.isBuiltIn && currentClamshellState() != .open {
            throw DisplayError(msg: "Open the lid before enabling the built-in display.")
        }

        guard display.isAvailable else {
            throw DisplayError(msg: "Display '\(display.name)' is no longer available.")
        }

        willChangeDisplays?([])

        var cid: CGDisplayConfigRef?
        let beginStatus = CGBeginDisplayConfiguration(&cid)
        guard beginStatus == .success, let config = cid else {
            throw DisplayError(msg: "Failed to begin configuration for '\(display.name)'.")
        }

        let status = CGSConfigureDisplayEnabled(config, display.id, true)
        guard status == 0 else {
            CGCancelDisplayConfiguration(config)
            throw DisplayError(msg: "Failed to show '\(display.name)'.")
        }

        let completeStatus = CGCompleteDisplayConfiguration(config, .forAppOnly)
        guard completeStatus == .success else {
            throw DisplayError(msg: "Failed to complete configuration for '\(display.name)'.")
        }

        display.state = .active
        display.isAvailable = true
        removeDisabledDisplayIDForRecovery(display.id)
        didChangeDisplays?()
        fetchDisplays()
    }

    fileprivate func reconnectDisplay(displayID: CGDirectDisplayID) throws {
        if CGDisplayIsBuiltin(displayID) != 0 && currentClamshellState() != .open {
            throw DisplayError(msg: "Open the lid before enabling the built-in display.")
        }

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
        persistDisabledDisplayIDsForRecovery(disabledDisplayIDs)
    }

    private func removeDisabledDisplayIDForRecovery(_ displayID: CGDirectDisplayID) {
        var disabledDisplayIDs = loadDisabledDisplayIDsForRecovery()
        disabledDisplayIDs.remove(displayID)
        persistDisabledDisplayIDsForRecovery(disabledDisplayIDs)
    }

    private func persistDisabledDisplayIDsForRecovery(_ displayIDs: Set<CGDirectDisplayID>) {
        if displayIDs.isEmpty {
            clearDisabledDisplayIDsForRecovery()
        } else {
            defaults.set(displayIDs.map(Int.init), forKey: PersistenceKeys.disabledDisplayIDsForRecovery)
        }
    }

    private func clearDisabledDisplayIDsForRecovery() {
        defaults.removeObject(forKey: PersistenceKeys.disabledDisplayIDsForRecovery)
    }

    private func loadPendingReactivationDisplayIDs() -> Set<CGDirectDisplayID> {
        let rawValues = defaults.array(forKey: PersistenceKeys.pendingReactivationDisplayIDs) as? [Int] ?? []
        return Set(rawValues.map(CGDirectDisplayID.init))
    }

    private func persistPendingReactivationDisplayID(_ displayID: CGDirectDisplayID) {
        var displayIDs = loadPendingReactivationDisplayIDs()
        displayIDs.insert(displayID)
        persistPendingReactivationDisplayIDs(displayIDs)
    }

    private func removePendingReactivationDisplayID(_ displayID: CGDirectDisplayID) {
        var displayIDs = loadPendingReactivationDisplayIDs()
        displayIDs.remove(displayID)
        persistPendingReactivationDisplayIDs(displayIDs)
    }

    private func persistPendingReactivationDisplayIDs(_ displayIDs: Set<CGDirectDisplayID>) {
        if displayIDs.isEmpty {
            defaults.removeObject(forKey: PersistenceKeys.pendingReactivationDisplayIDs)
        } else {
            defaults.set(displayIDs.map(Int.init), forKey: PersistenceKeys.pendingReactivationDisplayIDs)
        }
    }

    private func attemptPendingDisplayReconnections(_ displayIDs: [CGDirectDisplayID]) {
        guard !displayIDs.isEmpty else { return }

        var remainingDisplayIDs = loadPendingReactivationDisplayIDs()
        var didReconnectAny = false

        for displayID in displayIDs {
            guard remainingDisplayIDs.contains(displayID) else { continue }
            do {
                try reconnectDisplay(displayID: displayID)
                remainingDisplayIDs.remove(displayID)
                didReconnectAny = true
            } catch {
                continue
            }
        }

        persistPendingReactivationDisplayIDs(remainingDisplayIDs)

        if didReconnectAny {
            fetchDisplays()
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (deviceDescription[key] as? CGDirectDisplayID) ?? 0
    }
}
