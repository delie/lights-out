import SwiftUI

struct StatusButton: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var viewModel: DisplaysViewModel
    @EnvironmentObject var errorHandler: ErrorHandler
    
    @State private var isAnimating = false

    private var isOn: Bool {
        display.state == .active
    }

    var body: some View {
        Button(action: handlePress) {
            Image(systemName: display.state == .pending ? "ellipsis" : "power")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn ? .white : .secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(isOn ? Color.accentColor : Color.clear)
                )
                .opacity(display.state == .pending && isAnimating ? 0.4 : 1.0)
        }
        .buttonStyle(.plain)
        .disabled(display.state == .pending)
        .onAppear {
            guard display.state == .pending else { return }
            withAnimation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true)) {
                isAnimating.toggle()
            }
        }
    }

    private func handlePress() {
        if display.state == .pending { return }

        let shiftPressed = NSEvent.modifierFlags.contains(.shift)

        if shiftPressed {
            handleShiftTap()
        } else {
            handleTap()
        }
    }

    private func handleTap() {
        do {
            if display.state.isOff() {
                try viewModel.turnOnDisplay(display: display)
            } else {
                try viewModel.disconnectDisplay(display: display)
            }
        } catch let error {
            errorHandler.handle(error: error)
        }
    }

    private func handleShiftTap() {
        do {
            if display.state.isOff() {
                try viewModel.turnOnDisplay(display: display)
            } else {
                try viewModel.disableDisplay(display: display)
            }
        } catch let error {
            errorHandler.handle(error: error)
        }
    }
}

#Preview("Active") {
    StatusButton(display: DisplayInfo(id: 1, name: "Display", state: .active, isPrimary: false))
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
        .padding()
}

#Preview("Disconnected") {
    StatusButton(display: DisplayInfo(id: 2, name: "Display", state: .disconnected, isPrimary: false))
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
        .padding()
}
