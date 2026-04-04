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
                VStack(spacing: 0) {
                    ForEach(Array(viewModel.displays.enumerated()), id: \.element.id) { index, display in
                        DisplayControlView(display: display)
                            .environmentObject(viewModel)

                        if index < viewModel.displays.count - 1 {
                            Divider()
                                .padding(.leading, 32)
                        }
                    }
                }
                .background(Color.black.opacity(0.0001))
            }
        }
    }
}

struct DisplayControlView: View {
    @ObservedObject var display: DisplayInfo

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: displayIcon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 20)

            VStack(alignment: .leading, spacing: 1) {
                DisplayDetails(display: display)
            }
            Spacer(minLength: 12)
            StatusButton(display: display)
                .withErrorHandling()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var displayIcon: String {
        switch display.state {
        case .mirrored:
            return "square.on.square"
        case .disconnected:
            return "display.slash"
        case .active:
            return "display"
        case .pending:
            return "ellipsis.circle"
        }
    }
}

#Preview("Display List") {
    DisplayListView()
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
        .frame(width: 372)
}

#Preview("Display Control") {
    DisplayControlView(display: DisplayInfo(id: 1, name: "LG Ultrafine 5K", state: .active, isPrimary: true))
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
        .frame(width: 372)
}
