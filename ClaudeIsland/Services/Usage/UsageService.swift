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
    // In-memory token cache to avoid redundant keychain reads after refresh
    private var cachedAccessToken: String?
    private var cachedTokenExpiry: Date?

    private init() {
        loadCache()
        Task { await refresh() }
        startPeriodicRefresh()
    }

    private func startPeriodicRefresh() {
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10 * 60 * 1_000_000_000) // every 10 min
                await refresh()
            }
        }
    }

    func refresh() async {
        // Return cached data if still fresh
        if let cached = data, Date().timeIntervalSince(cached.lastUpdated) < cacheTTL {
            return
        }

        guard let token = await getValidToken(), !token.isEmpty else { return }

        guard let result = await fetchUsage(accessToken: token) else { return }
        data = result
        saveCache(result)
    }

    // MARK: - Token Management

    /// Returns a valid (non-expired) access token, refreshing via refresh_token if needed.
    private func getValidToken() async -> String? {
        // Use in-memory cached token if still valid
        if let token = cachedAccessToken, let expiry = cachedTokenExpiry, Date() < expiry {
            return token
        }

        let serviceNames = ["Claude Code-credentials", "claude-code-credentials", "Claude-Code-credentials"]
        for service in serviceNames {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne
            ]
            var result: AnyObject?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                  let keychainData = result as? Data,
                  let creds = try? JSONDecoder().decode(CredentialsFile.self, from: keychainData),
                  let oauth = creds.claudeAiOauth,
                  let accessToken = oauth.accessToken, !accessToken.isEmpty
            else { continue }

            // Check token expiry (with 60s buffer)
            if let expAt = oauth.expiresAt {
                let expDate = Date(timeIntervalSince1970: expAt > 1e10 ? expAt / 1000.0 : expAt)
                if Date() < expDate.addingTimeInterval(-60) {
                    // Token still valid
                    cachedAccessToken = accessToken
                    cachedTokenExpiry = expDate
                    return accessToken
                }
                // Token expired — try refresh
                if let refreshToken = oauth.refreshToken,
                   let newToken = await performTokenRefresh(refreshToken: refreshToken) {
                    cachedAccessToken = newToken
                    cachedTokenExpiry = Date().addingTimeInterval(3600)
                    return newToken
                }
                // Refresh failed, try the expired token anyway (server may still accept it briefly)
                return accessToken
            }

            return accessToken
        }

        // Fallback: credentials file
        return fileCredentialsToken()
    }

    /// Exchanges a refresh_token for a new access_token via Anthropic OAuth endpoint.
    private func performTokenRefresh(refreshToken: String) async -> String? {
        guard let url = URL(string: "https://console.anthropic.com/v1/oauth/token") else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        guard let clientID = UsageService.oauthClientID else { return nil }
        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID
        ]
        guard let bodyData = try? JSONEncoder().encode(body) else { return nil }
        request.httpBody = bodyData

        guard let (responseData, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse,
              http.statusCode == 200,
              let tokenResp = try? JSONDecoder().decode(TokenRefreshResponse.self, from: responseData)
        else { return nil }

        return tokenResp.accessToken
    }

    // MARK: - OAuth Client ID Discovery

    /// Reads CLIENT_ID from the Claude Code CLI installation.
    static let oauthClientID: String? = {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path

        var candidates = [
            "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js",
            "/opt/homebrew/lib/node_modules/@anthropic-ai/claude-code/cli.js",
            "\(home)/.npm/lib/node_modules/@anthropic-ai/claude-code/cli.js",
        ]

        // Best-effort: resolve `which claude` → find cli.js near the binary
        if let dynamic = cliJSFromWhich() { candidates.insert(dynamic, at: 0) }

        for path in candidates {
            guard fm.fileExists(atPath: path), let id = clientIDInFile(path) else { continue }
            return id
        }

        return nil
    }()

    private static func cliJSFromWhich() -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = ["claude"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }

        let bin = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bin.isEmpty else { return nil }

        // claude binary lives in .../bin/claude; cli.js is at .../cli.js
        let resolved = URL(fileURLWithPath: bin).resolvingSymlinksInPath()
        var dir = resolved.deletingLastPathComponent()
        for _ in 0..<3 {
            let candidate = dir.appendingPathComponent("cli.js").path
            if FileManager.default.fileExists(atPath: candidate) { return candidate }
            dir = dir.deletingLastPathComponent()
        }
        // Fallback: the binary itself may be a bundled JS binary containing CLIENT_ID
        return resolved.path
    }

    private static func clientIDInFile(_ path: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/grep")
        // -a: treat binary as text  -o: only print match  -m1: first match only
        // Use specific pattern with OAUTH_FILE_SUFFIX to identify the Claude Code OAuth client,
        // avoiding other unrelated CLIENT_ID entries in the binary.
        p.arguments = ["-aom1", "CLIENT_ID:\"[^\"]*\",OAUTH_FILE_SUFFIX", path]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        p.waitUntilExit()

        // Output format: CLIENT_ID:"<uuid>",OAUTH_FILE_SUFFIX  → extract the uuid
        // Take the LAST match: binary may contain an old (expired) CLIENT_ID first,
        // followed by the current valid one.
        let raw = (String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Find the last occurrence of CLIENT_ID:"..."
        let lines = raw.components(separatedBy: .newlines).filter { $0.contains("CLIENT_ID:") }
        guard let lastLine = lines.last else { return nil }
        let parts = lastLine.components(separatedBy: "\"")
        guard parts.count >= 2, !parts[1].isEmpty else { return nil }
        return parts[1]
    }

    // MARK: - Keychain (read-only helpers)

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
              Date().timeIntervalSince(cache.lastUpdated) < 3600  // Accept up to 1 hour stale on launch
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

private struct TokenRefreshResponse: Decodable {
    let accessToken: String
    let refreshToken: String?
    let expiresIn: Int?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
    }
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
