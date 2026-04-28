import SwiftUI

let enableSpinnerHoldDuration: TimeInterval = 2.0

struct DisplayListView: View {
    @EnvironmentObject var viewModel: DisplaysViewModel

    var body: some View {
        Group {
            if viewModel.displays.isEmpty && !viewModel.hasCompletedInitialRefresh {
                VStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)

                    Text("Loading Displays")
                        .font(.headline)

                    Text("Checking connected displays...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 120)
            } else if viewModel.displays.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "display")
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
                        HideExternalsButton(isEnabled: hasActiveBuiltInDisplay)
                    }

                    if hasDisabledExternals {
                        ShowExternalsButton()
                    }

                    if hasActiveExternals || hasDisabledExternals {
                        Divider()
                            .padding(.vertical, 6)
                    }

                    ShowAllDisplaysButton(isEnabled: hasDisabledDisplays)
                }
            }
        }
    }

    private var hasActiveExternals: Bool {
        viewModel.displays.contains { !$0.isBuiltIn && $0.state == .active }
    }

    private var hasDisabledExternals: Bool {
        let externals = viewModel.displays.filter { !$0.isBuiltIn }
        return !externals.isEmpty && externals.allSatisfy { $0.state.isOff }
    }

    private var hasDisabledDisplays: Bool {
        viewModel.displays.contains { $0.state.isOff }
    }

    private var hasActiveBuiltInDisplay: Bool {
        viewModel.displays.contains { $0.isBuiltIn && $0.state == .active }
    }
}

struct HideExternalsButton: View {
    @EnvironmentObject var viewModel: DisplaysViewModel
    @EnvironmentObject var errorHandler: ErrorHandler
    let isEnabled: Bool
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

            Text("Hide External Displays")
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
            hideExternalDisplays()
        }
        .disabled(isBusy || !isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
    }

    private func hideExternalDisplays() {
        guard !isBusy, isEnabled else { return }

        let builtInIsActive = viewModel.displays.contains { $0.isBuiltIn && $0.state == .active }

        guard builtInIsActive else {
            errorHandler.handle(error: DisplayError(msg: "Cannot hide external displays — no built-in display is visible."))
            return
        }

        let externalActive = viewModel.displays.filter { !$0.isBuiltIn && $0.state == .active }

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
            viewModel.clearDisplaysBusy(busyDisplayIDs)
            isBusy = false
        }
    }
}

struct ShowExternalsButton: View {
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

            Text("Show External Displays")
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
            showExternalDisplays()
        }
        .disabled(isBusy)
    }

    private func showExternalDisplays() {
        guard !isBusy else { return }

        let externalDisabled = viewModel.displays.filter { !$0.isBuiltIn && $0.state.isOff }
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

struct ShowAllDisplaysButton: View {
    @EnvironmentObject var viewModel: DisplaysViewModel
    let isEnabled: Bool
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

            Text("Show All Displays")
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
            showAllDisplays()
        }
        .disabled(isBusy || !isEnabled)
        .opacity(isEnabled ? 1 : 0.45)
        .overlay(alignment: .bottom) {
            if showResetPopup {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.secondary)
                    Text("Show All Displays")
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

    private func showAllDisplays() {
        guard !isBusy, isEnabled else { return }

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

        let canAttemptRecoveryWhileHidden = display.state.isOff && display.isUserHidden

        guard display.isAvailable || !display.state.isOff || canAttemptRecoveryWhileHidden else {
            errorHandler.handle(error: DisplayError(msg: "Display '\(display.name)' is no longer available."))
            viewModel.fetchDisplays()
            return
        }

        let isEnablingDisplay = display.state.isOff
        let isReactivatingHiddenUnavailableDisplay = display.state.isOff && display.isUserHidden && !display.isAvailable
        isBusy = true
        viewModel.markDisplaysBusy([display.id])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            do {
                if display.state.isOff {
                    try viewModel.turnOnDisplay(display: display)
                    if isReactivatingHiddenUnavailableDisplay {
                        errorHandler.inform(
                            title: "Display Reactivation Pending",
                            message: "LightsOut will show '\(display.name)' again when it becomes available on the expected input."
                        )
                    }
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
            return display.isAvailable ? "Hidden" : "Unavailable"
        case .active:
            return "Visible"
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
    DisplayControlView(display: DisplayInfo(id: 1, name: "LG Ultrafine 5K", state: .active, isPrimary: true, isBuiltIn: false))
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
        .frame(width: 372)
        .padding()
}

#Preview("Display Control — Disconnected") {
    DisplayControlView(display: DisplayInfo(id: 2, name: "Dell U2723QE", state: .disconnected, isPrimary: false, isBuiltIn: false))
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
        .frame(width: 372)
        .padding()
}

#Preview("Display Control — Unavailable") {
    DisplayControlView(display: DisplayInfo(id: 3, name: "Studio Display", state: .disconnected, isPrimary: false, isBuiltIn: false, isUserHidden: true, isAvailable: false))
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
        .frame(width: 372)
        .padding()
}
