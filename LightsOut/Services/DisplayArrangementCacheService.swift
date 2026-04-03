import CoreGraphics
import Foundation

class DisplayArrangementCacheService {
    private var displayArrangement: DisplayArrangement?
    
    func cache() throws {
        var displayCount: UInt32 = 0
        let maxDisplays: UInt32 = 32
        var activeDisplays = [CGDirectDisplayID](repeating: 0, count: Int(maxDisplays))
        CGGetActiveDisplayList(maxDisplays, &activeDisplays, &displayCount)
        
        var positions: [CGDirectDisplayID: CGPoint] = [:]
        for displayID in activeDisplays.prefix(Int(displayCount)) {
            let rect = CGDisplayBounds(displayID)
            positions[displayID] = CGPoint(x: rect.origin.x, y: rect.origin.y)
        }
        
        displayArrangement = DisplayArrangement(positions: positions)
    }
    
    func restore() throws {
        guard let arrangement = displayArrangement else { return }

        var configRef: CGDisplayConfigRef?
        let beginConfigError = CGBeginDisplayConfiguration(&configRef)
        guard beginConfigError == .success, let config = configRef else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(beginConfigError.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "Failed to begin display configuration."
            ])
        }

        for (displayID, position) in arrangement.positions {
            let moveError = CGConfigureDisplayOrigin(config, displayID, Int32(position.x), Int32(position.y))
            guard moveError == .success else {
                CGCancelDisplayConfiguration(config)
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(moveError.rawValue), userInfo: [
                    NSLocalizedDescriptionKey: "Failed to move display \(displayID) to position \(position)."
                ])
            }
        }
        
        let completeConfigError = CGCompleteDisplayConfiguration(config, .permanently)
        guard completeConfigError == .success else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(completeConfigError.rawValue), userInfo: [
                NSLocalizedDescriptionKey: "Failed to complete display configuration."
            ])
        }
        
    }
}

struct DisplayArrangement {
    let positions: [CGDirectDisplayID: CGPoint]
}
