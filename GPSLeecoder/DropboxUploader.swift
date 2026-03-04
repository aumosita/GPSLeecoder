import Foundation
import CoreLocation

/// Uploads GPS data to Dropbox using OAuth2 with refresh tokens for long-term access.
///
/// Auth flow:
/// 1. User opens authorization URL in browser
/// 2. User copies the authorization code
/// 3. App exchanges code for access_token + refresh_token
/// 4. Refresh token is stored in Keychain (long-lived, does not expire)
/// 5. Access token auto-refreshes when expired (~4 hours)
enum DropboxUploader {

    // MARK: - Constants

    /// Register your app at https://www.dropbox.com/developers/apps
    /// Use "App folder" access for automatic scoping to /Apps/<AppName>/
    private static let appKey    = "ygxy13rbimwer73"
    private static let appSecret = "nzaurk0rtqvrfup"

    private static let refreshTokenKey = "dropboxRefreshToken"
    private static let accessTokenKey  = "dropboxAccessToken"
    private static let expiryKey       = "dropboxTokenExpiry"

    private static let uploadURL  = URL(string: "https://content.dropboxapi.com/2/files/upload")!
    private static let tokenURL   = URL(string: "https://api.dropboxapi.com/oauth2/token")!

    /// URL the user opens in Safari to authorize the app.
    static var authorizationURL: URL {
        var components = URLComponents(string: "https://www.dropbox.com/oauth2/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: appKey),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "token_access_type", value: "offline")
        ]
        return components.url!
    }

    /// Whether Dropbox upload is enabled **and** a refresh token is available.
    static var isConfigured: Bool {
        UserDefaults.standard.bool(forKey: "dropboxUploadEnabled")
            && (KeychainHelper.load(key: refreshTokenKey) != nil)
    }

    /// Whether the user has linked their Dropbox account (has a refresh token).
    static var isLinked: Bool {
        KeychainHelper.load(key: refreshTokenKey) != nil
    }

    // MARK: - Auth

    /// Exchange an authorization code for access_token + refresh_token.
    /// Call this after the user authorizes the app and pastes the code.
    static func exchangeAuthorizationCode(_ code: String) async -> Bool {
        let body = [
            "code": code.trimmingCharacters(in: .whitespacesAndNewlines),
            "grant_type": "authorization_code",
            "client_id": appKey,
            "client_secret": appSecret
        ]

        guard let tokens = await requestTokens(body: body) else { return false }
        saveTokens(tokens)
        return true
    }

    /// Refresh the short-lived access token using the stored refresh token.
    /// Returns the new access token, or nil on failure.
    @discardableResult
    private static func refreshAccessToken() async -> String? {
        guard let refreshToken = KeychainHelper.load(key: refreshTokenKey) else {
            print("[Dropbox] No refresh token — cannot refresh")
            return nil
        }

        let body = [
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "client_id": appKey,
            "client_secret": appSecret
        ]

        guard let tokens = await requestTokens(body: body) else { return nil }
        // refresh_token is NOT re-issued on refresh, keep existing
        KeychainHelper.save(key: accessTokenKey, value: tokens.accessToken)
        UserDefaults.standard.set(tokens.expiry.timeIntervalSince1970, forKey: expiryKey)
        print("[Dropbox] Access token refreshed, expires at \(tokens.expiry)")
        return tokens.accessToken
    }

    /// Get a valid access token, refreshing if expired.
    private static func validAccessToken() async -> String? {
        // Check if we have a non-expired access token
        if let token = KeychainHelper.load(key: accessTokenKey) {
            let expiry = UserDefaults.standard.double(forKey: expiryKey)
            if expiry > 0, Date().timeIntervalSince1970 < expiry - 300 { // 5 min buffer
                return token
            }
        }
        // Need to refresh
        return await refreshAccessToken()
    }

    /// Unlink the Dropbox account by removing all stored tokens.
    static func unlink() {
        KeychainHelper.delete(key: refreshTokenKey)
        KeychainHelper.delete(key: accessTokenKey)
        UserDefaults.standard.removeObject(forKey: expiryKey)
    }

    // MARK: - Token request helper

    private struct TokenResponse {
        let accessToken: String
        let refreshToken: String?
        let expiry: Date
    }

    private static func requestTokens(body: [String: String]) async -> TokenResponse? {
        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.map { "\($0.key)=\($0.value)" }
            .joined(separator: "&")
            .data(using: .utf8)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
                let responseBody = String(data: data, encoding: .utf8) ?? "n/a"
                print("[Dropbox] Token request failed (\(statusCode)): \(responseBody)")
                return nil
            }

            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = json["access_token"] as? String,
                  let expiresIn = json["expires_in"] as? Double else {
                print("[Dropbox] Unexpected token response format")
                return nil
            }

            let refreshToken = json["refresh_token"] as? String
            let expiry = Date().addingTimeInterval(expiresIn)

            return TokenResponse(accessToken: accessToken, refreshToken: refreshToken, expiry: expiry)
        } catch {
            print("[Dropbox] Token request error: \(error.localizedDescription)")
            return nil
        }
    }

    private static func saveTokens(_ tokens: TokenResponse) {
        KeychainHelper.save(key: accessTokenKey, value: tokens.accessToken)
        if let rt = tokens.refreshToken {
            KeychainHelper.save(key: refreshTokenKey, value: rt)
        }
        UserDefaults.standard.set(tokens.expiry.timeIntervalSince1970, forKey: expiryKey)
        print("[Dropbox] Tokens saved, expires at \(tokens.expiry)")
    }

    // MARK: - Upload location JSON

    /// Upload the latest location as a JSON file to Dropbox.
    static func uploadLocation(
        coordinate: CLLocationCoordinate2D,
        altitude: Double,
        timestamp: Date
    ) async {
        guard UserDefaults.standard.bool(forKey: "dropboxUploadEnabled") else { return }
        guard let token = await validAccessToken() else {
            print("[Dropbox] No valid access token — skipping upload")
            return
        }

        // Build JSON payload
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let timeString = formatter.string(from: timestamp)

        let json: [String: String] = [
            "time": timeString,
            "lat":  "\(coordinate.latitude)",
            "lon":  "\(coordinate.longitude)",
            "ele":  "\(altitude)"
        ]

        guard let body = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            print("[Dropbox] Failed to serialize JSON")
            return
        }

        // Build filename: recent_location_2026-02-25T014330.json
        let filenameFormatter = DateFormatter()
        filenameFormatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        filenameFormatter.timeZone = .current
        let filename = "recent_location_\(filenameFormatter.string(from: timestamp)).json"

        await uploadData(body, remotePath: "/\(filename)", token: token)
    }

    // MARK: - Upload file

    /// Upload an arbitrary local file to Dropbox, keeping its filename.
    static func uploadFile(localURL: URL) async {
        guard UserDefaults.standard.bool(forKey: "dropboxUploadEnabled") else { return }
        guard let token = await validAccessToken() else {
            print("[Dropbox] No valid access token — skipping file upload")
            return
        }

        guard let fileData = try? Data(contentsOf: localURL) else {
            print("[Dropbox] Failed to read file: \(localURL.lastPathComponent)")
            return
        }

        await uploadData(fileData, remotePath: "/\(localURL.lastPathComponent)", token: token)
    }

    // MARK: - Shared upload helper

    private static func uploadData(_ data: Data, remotePath: String, token: String) async {
        let apiArg: [String: Any] = [
            "path": remotePath,
            "mode": "overwrite",
            "autorename": false,
            "mute": true
        ]
        guard let apiArgData = try? JSONSerialization.data(withJSONObject: apiArg),
              let apiArgString = String(data: apiArgData, encoding: .utf8) else {
            print("[Dropbox] Failed to build API arg")
            return
        }

        var request = URLRequest(url: uploadURL)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(apiArgString, forHTTPHeaderField: "Dropbox-API-Arg")
        request.httpBody = data

        do {
            let (responseData, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                let body = String(data: responseData, encoding: .utf8) ?? ""
                print("[Dropbox] Upload failed (\(http.statusCode)): \(body)")
            } else {
                let name = remotePath.split(separator: "/").last ?? ""
                print("[Dropbox] Uploaded \(name)")
            }
        } catch {
            print("[Dropbox] Upload error: \(error.localizedDescription)")
        }
    }
}
