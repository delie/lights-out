import SwiftUI

struct CustomUserPrompt: View {
    let title: String
    let message: String
    let primaryButton: (String, () -> Void)
    let secondaryButton: (String, () -> Void)

    var body: some View {
        ZStack {
            Color.black.opacity(0.2)
                .ignoresSafeArea()

            VStack(spacing: 18) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)

                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 12) {
                    Button(action: secondaryButton.1) {
                        Text(secondaryButton.0)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PromptButtonStyle(isPrimary: false))

                    Button(action: primaryButton.1) {
                        Text(primaryButton.0)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(PromptButtonStyle(isPrimary: true))
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .shadow(color: Color.black.opacity(0.12), radius: 12, x: 0, y: 8)
            .padding(.horizontal, 40)
        }
    }
}

#Preview {
    CustomUserPrompt(
        title: "Enable Launch at Login",
        message: "Would you like this app to launch automatically when you log in?",
        primaryButton: ("Yes", {}),
        secondaryButton: ("No", {})
    )
    .frame(width: 372, height: 200)
}

private struct PromptButtonStyle: ButtonStyle {
    let isPrimary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13))
            .foregroundStyle(isPrimary ? Color.white : Color.primary)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity)
            .background(background(for: configuration))
    }

    @ViewBuilder
    private func background(for configuration: Configuration) -> some View {
        if isPrimary {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.accentColor.opacity(configuration.isPressed ? 0.75 : 0.9))
        } else {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor))
        }
    }
}
