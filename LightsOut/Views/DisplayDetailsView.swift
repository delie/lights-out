import SwiftUI

struct DisplayDetails: View {
    @ObservedObject var display: DisplayInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(display.name)
                .font(.body.weight(.medium))
                .foregroundStyle(.primary)

            HStack(spacing: 6) {
                if display.isPrimary {
                    Text("Primary")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(secondaryLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var secondaryLabel: String {
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

#Preview("Active Display") {
    DisplayDetails(display: DisplayInfo(id: 1, name: "LG Ultrafine 5K", state: .active, isPrimary: true))
        .padding()
}

#Preview("Disconnected Display") {
    DisplayDetails(display: DisplayInfo(id: 2, name: "Dell Monitor", state: .disconnected, isPrimary: false))
        .padding()
}
