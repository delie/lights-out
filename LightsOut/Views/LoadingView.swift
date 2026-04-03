import SwiftUI

struct LoadingView: View {
    @Binding var cachedHeight: CGFloat
    @Binding var cachedWidth: CGFloat
    @Binding var isSpinning: Bool

    var body: some View {
        VStack(spacing: 12) {
            Spacer()
            ProgressView()
                .controlSize(.regular)
                .onAppear { isSpinning = true }
                .onDisappear { isSpinning = false }
            Text("Refreshing Displays")
                .font(.headline)
            Text("Updating the menu state")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(width: cachedWidth, height: cachedHeight)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .padding(8)
    }
}
