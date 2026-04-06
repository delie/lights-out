import SwiftUI

let enableSpinnerHoldDuration: TimeInterval = 2.0

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
                VStack(spacing: 0) {
                    Text("Displays")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.top, 8)
                        .padding(.bottom, 6)

                    VStack(spacing: 2) {
                        ForEach(viewModel.displays) { display in
                            DisplayControlView(display: display)
                        }
                    }

                    if hasActiveExternals || hasDisabledExternals {
                        Divider()
                            .padding(.vertical, 6)
                    }

                    if hasActiveExternals {
                        DisableExternalsButton()
                    }

                    if hasDisabledExternals {
                        RestoreExternalsButton()
                    }

                    if showsRestoreAllButton && (hasActiveExternals || hasDisabledExternals) {
                        Divider()
                            .padding(.vertical, 6)
                    }

                    if showsRestoreAllButton {
                        RestoreAllDisplaysButton()
                    }
                }
            }
        }
    }

    private var hasActiveExternals: Bool {
        viewModel.displays.contains { !$0.isPrimary && $0.state == .active }
    }

    private var hasDisabledExternals: Bool {
        let externals = viewModel.displays.filter { !$0.isPrimary }
        return !externals.isEmpty && externals.allSatisfy { $0.state.isOff() }
    }

    private var hasDisabledDisplays: Bool {
        viewModel.displays.contains { $0.state.isOff() }
    }

    private var showsRestoreAllButton: Bool {
        hasDisabledDisplays
    }
}

struct DisableExternalsButton: View {
    @EnvironmentObject var viewModel: DisplaysViewModel
    @EnvironmentObject var errorHandler: ErrorHandler
    @State private var isHovered = false
    @State private var isBusy = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                } else {
                    Image(systemName: "display.2")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            Text("Disable External Displays")
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)

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
            disableExternalDisplays()
        }
        .disabled(isBusy)
    }

    private func disableExternalDisplays() {
        guard !isBusy else { return }

        let primaryIsActive = viewModel.displays.contains { $0.isPrimary && $0.state == .active }

        guard primaryIsActive else {
            errorHandler.handle(error: DisplayError(msg: "Cannot disable external displays — the primary display is not active."))
            return
        }

        let externalActive = viewModel.displays.filter { !$0.isPrimary && $0.state == .active }

        guard !externalActive.isEmpty else { return }

        let busyDisplayIDs = Set(externalActive.map(\.id))
        isBusy = true
        viewModel.markDisplaysBusy(busyDisplayIDs)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for display in externalActive {
                do {
                    try viewModel.disconnectDisplay(display: display)
                } catch {
                    errorHandler.handle(error: displayError(from: error))
                    viewModel.fetchDisplays()
                    viewModel.clearDisplaysBusy(busyDisplayIDs)
                    isBusy = false
                    return
                }
            }
            viewModel.fetchDisplays()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0) {
                viewModel.clearDisplaysBusy(busyDisplayIDs)
                isBusy = false
            }
        }
    }
}

struct RestoreExternalsButton: View {
    @EnvironmentObject var viewModel: DisplaysViewModel
    @EnvironmentObject var errorHandler: ErrorHandler
    @State private var isHovered = false
    @State private var isBusy = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                } else {
                    Image(systemName: "display.2")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            Text("Enable External Displays")
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)

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
            restoreExternalDisplays()
        }
        .disabled(isBusy)
    }

    private func restoreExternalDisplays() {
        guard !isBusy else { return }

        let externalDisabled = viewModel.displays.filter { !$0.isPrimary && $0.state.isOff() }
        guard !externalDisabled.isEmpty else { return }

        let busyDisplayIDs = Set(externalDisabled.map(\.id))
        isBusy = true
        viewModel.markDisplaysBusy(busyDisplayIDs)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            for display in externalDisabled {
                do {
                    try viewModel.turnOnDisplay(display: display)
                } catch {
                    errorHandler.handle(error: displayError(from: error))
                    viewModel.fetchDisplays()
                    viewModel.clearDisplaysBusy(busyDisplayIDs)
                    isBusy = false
                    return
                }
            }
            viewModel.fetchDisplays()
            DispatchQueue.main.asyncAfter(deadline: .now() + enableSpinnerHoldDuration) {
                viewModel.clearDisplaysBusy(busyDisplayIDs)
                isBusy = false
            }
        }
    }
}

struct RestoreAllDisplaysButton: View {
    @EnvironmentObject var viewModel: DisplaysViewModel
    @State private var isHovered = false
    @State private var isBusy = false
    @State private var showResetPopup = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.secondary)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            Text("Restore All Displays")
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)

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
            restoreAllDisplays()
        }
        .disabled(isBusy)
        .overlay(alignment: .bottom) {
            if showResetPopup {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("Restore All Displays")
                        .font(.system(size: 12))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .offset(y: 44)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .allowsHitTesting(false)
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        showResetPopup = false
                    }
                }
            }
        }
    }

    private func restoreAllDisplays() {
        guard !isBusy else { return }

        let busyDisplayIDs = Set(viewModel.displays.map(\.id))
        isBusy = true
        viewModel.markDisplaysBusy(busyDisplayIDs)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            viewModel.resetAllDisplays()
            DispatchQueue.main.asyncAfter(deadline: .now() + enableSpinnerHoldDuration) {
                viewModel.clearDisplaysBusy(busyDisplayIDs)
                showResetPopup = true
                isBusy = false
            }
        }
    }
}

struct DisplayControlView: View {
    @ObservedObject var display: DisplayInfo
    @EnvironmentObject var viewModel: DisplaysViewModel
    @EnvironmentObject var errorHandler: ErrorHandler

    @State private var isHovered = false
    @State private var isBusy = false

    private var isOn: Bool {
        display.state == .active
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Group {
                if isBusy || viewModel.busyDisplayIDs.contains(display.id) || display.state == .pending {
                    ProgressView()
                        .controlSize(.small)
                        .tint(isOn ? .white : .secondary)
                } else {
                    Image(systemName: "power")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOn ? .white : .secondary)
                }
            }
            .frame(width: 24, height: 24)
            .background(
                Circle()
                    .fill(isOn ? Color.accentColor : Color.white.opacity(0.06))
            )

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
        .disabled(display.state == .pending || isBusy)
    }

    private func handlePress() {
        if display.state == .pending || isBusy { return }

        let isEnablingDisplay = display.state.isOff()
        isBusy = true
        viewModel.markDisplaysBusy([display.id])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            do {
                if display.state.isOff() {
                    try viewModel.turnOnDisplay(display: display)
                } else {
                    try viewModel.disconnectDisplay(display: display)
                }
            } catch {
                errorHandler.handle(error: displayError(from: error))
            }
            viewModel.fetchDisplays()
            let spinnerHoldDuration = isEnablingDisplay ? enableSpinnerHoldDuration : 0
            DispatchQueue.main.asyncAfter(deadline: .now() + spinnerHoldDuration) {
                viewModel.clearDisplaysBusy([display.id])
                isBusy = false
            }
        }
    }

    private var statusLabel: String {
        switch display.state {
        case .disconnected:
            return "Disconnected"
        case .active:
            return "Available"
        case .pending:
            return "Applying change"
        }
    }
}

private func displayError(from error: Error) -> DisplayError {
    error as? DisplayError ?? DisplayError(msg: error.localizedDescription)
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
