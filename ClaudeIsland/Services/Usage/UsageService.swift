//
//  UsageService.swift
//  ClaudeIsland
//
//  Fetches Plan usage limits from Anthropic OAuth API
//  API: GET https://api.anthropic.com/api/oauth/usage
//

import Combine
import Foundation
import Security

// MARK: - Models

struct UsageLimitData: Sendable {
    let planName: String
    let fiveHourPercent: Double?   // 0.0–1.0, nil if unavailable
    let sevenDayPercent: Double?
    let fiveHourResetAt: Date?
    let sevenDayResetAt: Date?
    let lastUpdated: Date
}

// MARK: - Service

@MainActor
final class UsageService: ObservableObject {
    @Published var data: UsageLimitData?

    static let shared = UsageService()

    private let cacheURL: URL = {
        let claudeDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude")
        return claudeDir.appendingPathComponent(".claude-island-usage-cache.json")
    }()

    // 5-minute cache TTL
    private let cacheTTL: TimeInterval = 5 * 60

    private init() {
        loadCache()
        Task { await refresh() }
    }

    func refresh() async {
        // Return cached data if still fresh
        if let cached = data, Date().timeIntervalSince(cached.lastUpdated) < cacheTTL {
            return
        }

        guard let token = readOAuthToken(), !token.isEmpty else { return }

        guard let result = await fetchUsage(accessToken: token) else { return }
        data = result
        saveCache(result)
    }

    // MARK: - Keychain

    private func readOAuthToken() -> String? {
        // Primary: read from macOS Keychain (service: "Claude Code-credentials")
        let serviceNames = ["Claude Code-credentials", "claude-code-credentials", "Claude-Code-credentials"]
        for service in serviceNames {
            if let token = keychainToken(service: service) {
                return token
            }
        }
        // Fallback: read from ~/.claude/.credentials.json
        return fileCredentialsToken()
    }

    private func keychainToken(service: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let credentials = try? JSONDecoder().decode(CredentialsFile.self, from: data),
              let token = credentials.claudeAiOauth?.accessToken
        else { return nil }
        return token
    }

    private func fileCredentialsToken() -> String? {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: path),
              let credentials = try? JSONDecoder().decode(CredentialsFile.self, from: data),
              let token = credentials.claudeAiOauth?.accessToken
        else { return nil }
        return token
    }

    // MARK: - API Call

    private func fetchUsage(accessToken: String) async -> UsageLimitData? {
        guard let url = URL(string: "https://api.anthropic.com/api/oauth/usage") else { return nil }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("claude-code/2.1", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200
        else { return nil }

        guard let apiResp = try? JSONDecoder().decode(UsageApiResponse.self, from: responseData)
        else { return nil }

        // Determine plan name from keychain subscriptionType
        let planName = keychainPlanName() ?? "Pro"

        let iso = ISO8601DateFormatter()
        // API returns utilization as a percentage (e.g. 14.0 = 14%), normalize to 0.0–1.0
        return UsageLimitData(
            planName: planName,
            fiveHourPercent: apiResp.fiveHour?.utilization.map { $0 / 100.0 },
            sevenDayPercent: apiResp.sevenDay?.utilization.map { $0 / 100.0 },
            fiveHourResetAt: apiResp.fiveHour?.resetsAt.flatMap { iso.date(from: $0) },
            sevenDayResetAt: apiResp.sevenDay?.resetsAt.flatMap { iso.date(from: $0) },
            lastUpdated: Date()
        )
    }

    private func keychainPlanName() -> String? {
        let serviceNames = ["Claude Code-credentials", "claude-code-credentials"]
        for service in serviceNames {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let data = result as? Data,
                  let creds = try? JSONDecoder().decode(CredentialsFile.self, from: data),
                  let sub = creds.claudeAiOauth?.subscriptionType
            else { continue }
            return planDisplayName(sub)
        }
        return nil
    }

    private func planDisplayName(_ subscriptionType: String) -> String {
        switch subscriptionType.lowercased() {
        case "pro": return "Pro"
        case "max", "max5", "max20": return "Max"
        case "free": return "Free"
        default: return subscriptionType.capitalized
        }
    }

    // MARK: - Cache

    private struct CacheFile: Codable {
        let planName: String
        let fiveHourPercent: Double?
        let sevenDayPercent: Double?
        let fiveHourResetAt: Date?
        let sevenDayResetAt: Date?
        let lastUpdated: Date
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: cacheURL),
              let cache = try? JSONDecoder().decode(CacheFile.self, from: data),
              Date().timeIntervalSince(cache.lastUpdated) < cacheTTL * 2  // Accept up to 10min stale on launch
        else { return }

        self.data = UsageLimitData(
            planName: cache.planName,
            fiveHourPercent: cache.fiveHourPercent,
            sevenDayPercent: cache.sevenDayPercent,
            fiveHourResetAt: cache.fiveHourResetAt,
            sevenDayResetAt: cache.sevenDayResetAt,
            lastUpdated: cache.lastUpdated
        )
    }

    private func saveCache(_ d: UsageLimitData) {
        let cache = CacheFile(
            planName: d.planName,
            fiveHourPercent: d.fiveHourPercent,
            sevenDayPercent: d.sevenDayPercent,
            fiveHourResetAt: d.fiveHourResetAt,
            sevenDayResetAt: d.sevenDayResetAt,
            lastUpdated: d.lastUpdated
        )
        guard let encoded = try? JSONEncoder().encode(cache) else { return }
        try? encoded.write(to: cacheURL)
    }
}

// MARK: - Codable Models

private struct CredentialsFile: Decodable {
    let claudeAiOauth: OAuthCredentials?
}

private struct OAuthCredentials: Decodable {
    let accessToken: String?
    let refreshToken: String?
    let subscriptionType: String?
    let rateLimitTier: String?
    let expiresAt: Double?
}

private struct UsageApiResponse: Decodable {
    let fiveHour: UsageWindow?
    let sevenDay: UsageWindow?

    enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
    }
}

private struct UsageWindow: Decodable {
    let utilization: Double?
    let resetsAt: String?

    enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}
