import CoreGraphics
import Foundation

class GammaUpdateService {
    private var originalGammaTables: [CGDirectDisplayID: (red: [CGGammaValue], green: [CGGammaValue], blue: [CGGammaValue])] = [:]
    private var gammaUpdateTimers: [DisplayInfo: Timer] = [:]

    func setZeroGamma(for display: DisplayInfo) {
        saveOriginalGamma(for: display.id)
        applyZeroGamma(for: display)
    }

    func restoreGamma(for display: DisplayInfo) {
        gammaUpdateTimers[display]?.invalidate()
        gammaUpdateTimers[display] = nil

        if let originalTables = originalGammaTables[display.id] {
            CGSetDisplayTransferByTable(display.id, UInt32(originalTables.red.count), originalTables.red, originalTables.green, originalTables.blue)
        }
    }

    private func saveOriginalGamma(for displayID: CGDirectDisplayID) {
        guard originalGammaTables[displayID] == nil else { return }
        var gammaTableSize: UInt32 = 256
        CGGetDisplayTransferByTable(displayID, 0, nil, nil, nil, &gammaTableSize)
        var redTable = [CGGammaValue](repeating: 0, count: Int(gammaTableSize))
        var greenTable = [CGGammaValue](repeating: 0, count: Int(gammaTableSize))
        var blueTable = [CGGammaValue](repeating: 0, count: Int(gammaTableSize))
        CGGetDisplayTransferByTable(displayID, gammaTableSize, &redTable, &greenTable, &blueTable, &gammaTableSize)
        originalGammaTables[displayID] = (red: redTable, green: greenTable, blue: blueTable)
    }

    private func applyZeroGamma(for display: DisplayInfo) {
        let zeroTable = [CGGammaValue](repeating: 0, count: 256)
        var runs = 0

        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            CGSetDisplayTransferByTable(display.id, 256, zeroTable, zeroTable, zeroTable)
            runs += 1

            if runs >= 5 {
                timer.invalidate()
                self?.gammaUpdateTimers[display] = nil
                display.state = .mirrored
            }
        }

        gammaUpdateTimers[display] = timer
    }
}
