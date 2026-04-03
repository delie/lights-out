import Foundation
import SwiftUI

final class AppUpdateService: ObservableObject {
    enum Status: Equatable {
        case idle
        case checking
        case upToDate(currentVersion: String)
        case updateAvailable(currentVersion: String, latestVersion: String, releaseURL: URL)
        case unavailable(message: String)
    }

    @Published private(set) var status: Status = .idle

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    var releasesPageURL: URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "LSReleasesPageURL") as? String else {
            return nil
        }

        return URL(string: value)
    }

    func checkForUpdates() {
        Task {
            await refresh()
        }
    }

    func refresh() async {
        guard let currentVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
              let apiURLString = Bundle.main.object(forInfoDictionaryKey: "LSLatestReleaseAPIURL") as? String,
              let apiURL = URL(string: apiURLString) else {
            await setStatus(.unavailable(message: "Release check is not configured."))
            return
        }

        await setStatus(.checking)

        do {
            let (data, response) = try await session.data(from: apiURL)
            guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
                await setStatus(.unavailable(message: "Could not reach the release feed."))
                return
            }

            let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
            let latestVersion = Self.normalize(version: release.tagName)

            guard !latestVersion.isEmpty else {
                await setStatus(.unavailable(message: "Latest release did not include a usable version."))
                return
            }

            let releaseURL = URL(string: release.htmlURL) ?? releasesPageURL

            if Self.compareVersions(latestVersion, currentVersion) == .orderedDescending,
               let releaseURL {
                await setStatus(.updateAvailable(
                    currentVersion: currentVersion,
                    latestVersion: latestVersion,
                    releaseURL: releaseURL
                ))
            } else {
                await setStatus(.upToDate(currentVersion: currentVersion))
            }
        } catch {
            await setStatus(.unavailable(message: "Could not check for a newer version."))
        }
    }

    private static func normalize(version: String) -> String {
        version
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"^[^0-9]*"#, with: "", options: .regularExpression)
    }

    private static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let lhsParts = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let rhsParts = rhs.split(separator: ".").map { Int($0) ?? 0 }
        let count = max(lhsParts.count, rhsParts.count)

        for index in 0..<count {
            let lhsValue = index < lhsParts.count ? lhsParts[index] : 0
            let rhsValue = index < rhsParts.count ? rhsParts[index] : 0

            if lhsValue < rhsValue {
                return .orderedAscending
            }

            if lhsValue > rhsValue {
                return .orderedDescending
            }
        }

        return .orderedSame
    }

    private func setStatus(_ newStatus: Status) async {
        await MainActor.run {
            status = newStatus
        }
    }
}

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
    }
}
