//
//  MenuBarHeaderView.swift
//  BlackoutTest

import SwiftUI

let texts = ["Darker then Terry A. Davis's humor.",
             "Collecting data about how much you love the dark.",
             "Also try Minecraft!",
            "Darker then the job market.",
             "Spacializing in dark humor.",
             "Bruteforce darkmode for the masses.",
             "No-suger No-milk coffee.",
             "Shh. The display is sleeping.",
             "Embrace the abyss — your monitor already has.",
             "No light-mode 'round these parts.",
             "Open-source and free, forever.",
             "Open-sourcing the dark, 13 billion years late.",
             "Pretty dark here. wink-wink.",
             "Least annoying app in your menubar.",
             "Feels a little lonely here - maybe get another monitor?",
             "Judging your monitor names.",
             "Spotlight dimming since '24.",
             "Your monitors deserve a break, too.",
             "No more cable fidgeting.",
             "Capable of keeping your dark secrets.",
             "Even Batman would approve.",
             "Clearly, you've moved to the dark side.",
             "Wielding the dark side, No lightsabers required.",
             "Somewhare, Neo nods in approval.",
             "Some call it witchcraft; We call it dark magic.",
             "No lumos casting allowed. No patronuses either.",
             "The best ideas are born in the dark.",
             "Turning your display into a star-less sky.",
             "Your screen called. It wants to go goth.",
             "We dim - so you don't squint.",
             "Brightness was a mistake. We fixed it.",
             "Dimmed for dramatic effect.",
             "Bright screens ruin vibes. We bring them back.",
             "Dimmer then your neighbour's Wi-Fi signal.",
             "Darkness so smooth, you'll want to sip it like fine coffee.",
             "No more \"light at the end of the tunnel\". Just the tunnel.",
             "Your monitor just joined the Witness Protection Program."
]

struct MenuBarHeader: View {
    @Binding var isLoading: Bool
    @State private var randomText: String = texts.randomElement()!
    @EnvironmentObject var viewModel: DisplaysViewModel
    @EnvironmentObject var updateService: AppUpdateService
    @Environment(\.openURL) private var openURL
    @State private var showResetPopup: Bool = false

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("LightsOut!")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundColor(.purple)
                Text(randomText)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundColor(.gray)
                    .onAppear {
                        randomText = texts.randomElement()!
                    }

                updateStatusView
            }
            Spacer()
            VStack(spacing: 4) {
                Image("menubarIcon")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 43, height: 43)
                    .foregroundColor(.gray)

                HStack(spacing: 16) {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color("AppBlue"))
                        .onTapGesture {
                            isLoading = true
                            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                                isLoading = false
                            }
                            viewModel.fetchDisplays()
                            
                            
                        }
                    
                    Image(systemName: "arrow.uturn.backward.circle")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundColor(Color("AppRed"))
                        .onTapGesture {
                            viewModel.resetAllDisplays()
                            showResetPopup = true
                        }
                }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .overlay(
            Group {
                if showResetPopup {
                    VStack {
                        Spacer()
                        Text("All displays restored to an active state!")
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundColor(.white)
                            .padding(8)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.8)))
                            .padding(.bottom, 20)
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
            Text("Checking GitHub for new releases...")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(Color("AppBlue"))
        case let .upToDate(currentVersion):
            Text("Version \(currentVersion) is current.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(Color("AppGreen"))
        case let .updateAvailable(_, latestVersion, releaseURL):
            Button("Version \(latestVersion) is available") {
                openURL(releaseURL)
            }
            .buttonStyle(.plain)
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundColor(Color("AppBlue"))
        case let .unavailable(message):
            Text(message)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(Color("AppRed"))
        }
    }

}
