//
//  MenuBarView.swift
//  BlackoutTest

import SwiftUI
import LaunchAtLogin

struct MenuBarView: View {
    @EnvironmentObject var viewModel: DisplaysViewModel
    @EnvironmentObject var updateService: AppUpdateService
    @State private var isLoading: Bool = false
    @State private var isSpinning: Bool = false
    @State private var cachedHeight: CGFloat = 200
    @State private var cachedWidth: CGFloat = 200
    @AppStorage("ShowStartupPrompt") private var showStartupPrompt: Bool = true
    
    var body: some View {
        ZStack {
            if isLoading {
                LoadingView(cachedHeight: $cachedHeight, cachedWidth: $cachedWidth, isSpinning: $isSpinning)
            } else {
                ContentView(isLoading: $isLoading)
                    .environmentObject(viewModel)
                    .environmentObject(updateService)
                    .background(
                        GeometryReader { geometry in
                            Color("Background")
                                .onAppear {
                                    cachedHeight = geometry.size.height
                                    cachedWidth = geometry.size.width
                                }
                        }
                    )
                    .cornerRadius(8)
            }
            // Custom Alert Overlay
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
        
        .animation(.snappy, value: isLoading)
    }
}

struct ContentView: View {
    @EnvironmentObject var viewModel: DisplaysViewModel
    @EnvironmentObject var updateService: AppUpdateService
    @Binding var isLoading: Bool
    @State private var isShiftPressed = false

    var body: some View {
        VStack(spacing: 16) {
            // Header Section
            MenuBarHeader(isLoading: $isLoading)
                .environmentObject(updateService)
                .frame(maxWidth: .infinity, alignment: .leading) // Ensure full width

            // Display List Section
            DisplayListView()
                .frame(maxWidth: .infinity) // Make sure it fills the available space

            // Footer Section
            FooterText(isShiftPressed: $isShiftPressed)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 6)

    }
}

struct FooterText: View {
    @Binding var isShiftPressed: Bool
    @State private var eventMonitor: Any?
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack(spacing: 4) {
            Text("Hold")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.gray)

            Text("Shift")
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(.primary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4)
                        .fill(isShiftPressed ? Color("AppBlue") : Color.clear)
                )

            Text("to use a mirror-based disable ")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.gray)

            Button(action: {
                if let url = URL(string: "https://alonx2.github.io/LightsOut/docs/disable-methods.html") {
                    openURL(url)
                }
            }) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .onAppear {
            // Add the event monitor each time the view appears
            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                isShiftPressed = event.modifierFlags.contains(.shift)
                return event // Return the event to continue its propagation
            }
        }
        .onDisappear {
            // Remove the event monitor when the view disappears
            if let monitor = eventMonitor {
                NSEvent.removeMonitor(monitor)
                eventMonitor = nil
            }
        }
    }
}
