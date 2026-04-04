import SwiftUI

class ErrorHandler: ObservableObject {
    @Published var currentError: DisplayError?
    @Published var postaction: (() -> Void)?
    
    func handle(error: DisplayError, postaction: (() -> Void)? = nil) {
        currentError = error
        self.postaction = postaction
    }
}

struct HandleErrorsByShowingAlertViewModifier: ViewModifier {
    @StateObject var errorHandling = ErrorHandler()
    
    func body(content: Content) -> some View {
        content
            .environmentObject(errorHandling)
            .alert(item: $errorHandling.currentError) { error in
                Alert(
                    title: Text("Error"),
                    message: Text(error.msg),
                    dismissButton: .default(Text("OK"), action: {
                        errorHandling.postaction?()
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
