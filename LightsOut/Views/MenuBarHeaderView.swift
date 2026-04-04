import SwiftUI

struct MenuBarHeader: View {
    @Binding var isLoading: Bool
    @EnvironmentObject var viewModel: DisplaysViewModel
    @Environment(\.openURL) private var openURL
    @State private var showResetPopup: Bool = false
    
    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "display.2")
                .font(.system(size: 18))
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("LightsOut")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                
                Text(version ?? "1")
            }
            Spacer()

            HStack(spacing: 8) {
                Button {
                    isLoading = true
                    viewModel.fetchDisplays()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                        isLoading = false
                    }
                } label: {
                    if isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .buttonStyle(.borderless)
                .controlSize(.large)
                .disabled(isLoading)
                .help("Refresh displays")

                Button {
                    viewModel.resetAllDisplays()
                    showResetPopup = true
                } label: {
                    Image(systemName: "power")
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
                            Text("Restore all displays")
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
}

#Preview {
    MenuBarHeader(isLoading: .constant(false))
        .environmentObject(DisplaysViewModel())
        .frame(width: 372)
        .padding()
}
