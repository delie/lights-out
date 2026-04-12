import SwiftUI

enum DisplayState {
    case disconnected
    case pending
    case active
    
    func isOff() -> Bool {
        switch self {
        case .disconnected:
            return true
        default:
            return false
        }
    }
}

class DisplayInfo: ObservableObject, Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    var isPrimary: Bool
    let isBuiltIn: Bool
    @Published var isUserHidden: Bool
    @Published var isAvailable: Bool
    @Published var state: DisplayState

    init(
        id: CGDirectDisplayID,
        name: String,
        state: DisplayState,
        isPrimary: Bool,
        isBuiltIn: Bool,
        isUserHidden: Bool = false,
        isAvailable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.state = state
        self.isPrimary = isPrimary
        self.isBuiltIn = isBuiltIn
        self.isUserHidden = isUserHidden
        self.isAvailable = isAvailable
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }
    
    static func == (lhs: DisplayInfo, rhs: DisplayInfo) -> Bool {
        return lhs.id == rhs.id
    }
}
