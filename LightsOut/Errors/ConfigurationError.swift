import Foundation

struct DisplayError: Error, Identifiable {
    var id: String { UUID().uuidString }
    var msg: String
}
