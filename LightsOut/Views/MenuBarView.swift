import SwiftUI
import LaunchAtLogin

struct MenuBarView: View {
    @EnvironmentObject var viewModel: DisplaysViewModel
    @State private var isLoading: Bool = false
    @AppStorage("ShowStartupPrompt") private var showStartupPrompt: Bool = true

    var body: some View {
        ZStack {
            ContentView(isLoading: $isLoading)
                .environmentObject(viewModel)
                .disabled(isLoading)
                .opacity(isLoading ? 0.5 : 1.0)

            if showStartupPrompt {
                CustomUserPrompt(
                    title: "Enable Launch at Login",
                    message: "Would you like this app to launch automatically when you log in?",
                    primaryButton: ("Yes", {
                        showStartupPrompt = false
                        LaunchAtLogin.isEnabled = true
                    }),
                    secondaryButton: ("No", {
                        showStartupPrompt = false
                        LaunchAtLogin.isEnabled = false
                    })
                )
            }
        }
        .frame(width: 372)
        .animation(.snappy, value: isLoading)
    }
}

struct ContentView: View {
    @EnvironmentObject var viewModel: DisplaysViewModel
    @Binding var isLoading: Bool
    @State private var isShiftPressed = false

    var body: some View {
        VStack(spacing: 0) {
            MenuBarHeader(isLoading: $isLoading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.bottom, 12)

            Divider()

            DisplayListView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)

            Divider()

            Footer(isShiftPressed: $isShiftPressed)
                .padding(.top, 10)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }
}

struct Footer: View {
    @Binding var isShiftPressed: Bool
    @State private var eventMonitor: Any?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .trailing, spacing: 10){
            HStack(spacing: 4) {
                Image(systemName: "keyboard")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                
                Text("Hold Shift for mirror-based disable.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                
                if isShiftPressed {
                    Text("Shift")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                
                Spacer(minLength: 0)
                                
                Button(action: {
                    if let url = URL(string: "https://alonx2.github.io/LightsOut/docs/disable-methods.html") {
                        openURL(url)
                    }
                }) {
                    Image(systemName: "questionmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .onAppear {
                eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                    isShiftPressed = event.modifierFlags.contains(.shift)
                    return event
                }
            }
            .onDisappear {
                if let monitor = eventMonitor {
                    NSEvent.removeMonitor(monitor)
                    eventMonitor = nil
                }
            }
        }
    }
}

#Preview("MenuBarView") {
    MenuBarView()
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
}

#Preview("ContentView") {
    ContentView(isLoading: .constant(false))
        .environmentObject(DisplaysViewModel())
        .environmentObject(ErrorHandler())
        .frame(width: 372)
}

#Preview("Footer") {
    Footer(isShiftPressed: .constant(false))
        .padding()
}
