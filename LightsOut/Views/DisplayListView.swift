import SwiftUI

struct DisplayListView: View {
    @EnvironmentObject var viewModel: DisplaysViewModel

    var body: some View {
        Group {
            if viewModel.displays.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "display.slash")
                        .font(.title2)
                        .foregroundStyle(.secondary)

                    Text("No Displays")
                        .font(.headline)

                    Text("Connect a display to manage it here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                VStack(spacing: 2) {
                    ForEach(viewModel.displays) { display in
                        DisplayControlView(display: display)
                    }
                }
            }
        }
    }
}

struct DisplayControlView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var viewModel: DisplaysViewModel
    @EnvironmentObject var errorHandler: ErrorHandler

    @State private var isHovered = false
    @State private var isAnimating = false

    private var isOn: Bool {
        display.state == .active
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: display.state == .pending ? "ellipsis" : "power")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? .white : .secondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isOn ? Color.accentColor : Color.white.opacity(0.06))
                )
                .opacity(display.state == .pending && isAnimating ? 0.4 : 1.0)

            VStack(alignment: .leading, spacing: 1) {
                Text(display.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(isOn ? .primary : .secondary)

                HStack(spacing: 6) {
                    if display.isPrimary {
                        Text("Primary")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Text(statusLabel)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 12)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isHovered ? Color.white.opacity(0.1) : Color.clear)
        )
        .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .onHover { hovering in
            isHovered = hovering
        }
        .onTapGesture {
            handlePress()
        }
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

        do {
            if display.state.isOff() {
                try viewModel.turnOnDisplay(display: display)
            } else if shiftPressed {
                try viewModel.disableDisplay(display: display)
            } else {
                try viewModel.disconnectDisplay(display: display)
            }
        } catch {
            errorHandler.handle(error: error)
        }
    }

    private var statusLabel: String {
        switch display.state {
        case .mirrored:
            return "Mirror-disabled"
        case .disconnected:
            return "Disconnected"
        case .active:
            return "Available"
        case .pending:
            return "Applying change"
        }
    }
}

#Preview("Display List") {
    DisplayListView()
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
        .frame(width: 372)
        .padding()
}

#Preview("Display Control — Active") {
    DisplayControlView(display: DisplayInfo(id: 1, name: "LG Ultrafine 5K", state: .active, isPrimary: true))
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
        .frame(width: 372)
        .padding()
}

#Preview("Display Control — Disconnected") {
    DisplayControlView(display: DisplayInfo(id: 2, name: "Dell U2723QE", state: .disconnected, isPrimary: false))
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
        .frame(width: 372)
        .padding()
}
