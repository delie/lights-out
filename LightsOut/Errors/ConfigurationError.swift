import Foundation

struct DisplayError: Error, Identifiable {
    let id = UUID()
    var msg: String
}
