import SwiftUI

struct AlertMessage: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

class ErrorHandler: ObservableObject {
    @Published var currentError: DisplayError?
    @Published var currentAlert: AlertMessage?
    @Published var postaction: (() -> Void)?
    
    func handle(error: DisplayError, postaction: (() -> Void)? = nil) {
        currentError = error
        self.postaction = postaction
    }

    func inform(title: String, message: String, postaction: (() -> Void)? = nil) {
        currentAlert = AlertMessage(title: title, message: message)
        self.postaction = postaction
    }
}

struct HandleErrorsByShowingAlertViewModifier: ViewModifier {
    @StateObject var errorHandling = ErrorHandler()
    
    func body(content: Content) -> some View {
        content
            .environmentObject(errorHandling)
            .alert(item: Binding(
                get: {
                    if let alert = errorHandling.currentAlert {
                        return alert
                    }
                    return errorHandling.currentError.map { AlertMessage(title: "Error", message: $0.msg) }
                },
                set: { newValue in
                    if newValue == nil {
                        errorHandling.currentAlert = nil
                        errorHandling.currentError = nil
                    }
                }
            )) { alert in
                Alert(
                    title: Text(alert.title),
                    message: Text(alert.message),
                    dismissButton: .default(Text("OK"), action: {
                        errorHandling.postaction?()
                        errorHandling.postaction = nil
                    })
                )
            }
    }
}

extension View {
    func withErrorHandling() -> some View {
        modifier(HandleErrorsByShowingAlertViewModifier())
    }
}
