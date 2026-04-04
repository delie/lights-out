import SwiftUI

struct MenuBarHeader: View {
    @Binding var isLoading: Bool
    @EnvironmentObject var viewModel: DisplaysViewModel
    @EnvironmentObject var updateService: AppUpdateService
    @Environment(\.openURL) private var openURL
    @State private var showResetPopup: Bool = false

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "display.2")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("LightsOut")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(headerSubtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                updateStatusView
            }
            Spacer()

            HStack(spacing: 8) {
                Button {
                    isLoading = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        isLoading = false
                    }
                    viewModel.fetchDisplays()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .help("Refresh displays")

                Button {
                    viewModel.resetAllDisplays()
                    showResetPopup = true
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .help("Restore all displays")
            }
        }
        .overlay(
            Group {
                if showResetPopup {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.secondary)
                            Text("All displays restored to an active state")
                                .font(.system(size: 12))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .padding(.bottom, 12)
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
        )
    }

    @ViewBuilder
    private var updateStatusView: some View {
        switch updateService.status {
        case .idle:
            EmptyView()
        case .checking:
            Text("Checking for updates…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case let .upToDate(currentVersion):
            Text("Version \(currentVersion)")
                .font(.caption)
                .foregroundStyle(.tertiary)
        case let .updateAvailable(_, latestVersion, releaseURL):
            Button("Update available: \(latestVersion)") {
                openURL(releaseURL)
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(Color.accentColor)
        case let .unavailable(message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    private var headerSubtitle: String {
        let count = viewModel.displays.count
        if count == 0 {
            return "No displays connected"
        }
        if count == 1 {
            return "1 display available"
        }
        return "\(count) displays available"
    }
}

#Preview {
    MenuBarHeader(isLoading: .constant(false))
        .environmentObject(DisplaysViewModel())
        .environmentObject(AppUpdateService())
        .frame(width: 372)
        .padding()
}
