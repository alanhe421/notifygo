import Foundation
import Combine
import CryptoKit
import Security
import UserNotifications
import UIKit

private struct Installation: Codable {
    var id: String
    var token: String
    var pushURL: String?
    var urls: [String: String] = [:]
}

/// One-time code that moves this installation to another device. The code itself is the only secret:
/// the server receives a lookup value and ciphertext derived from it, never the key.
struct MigrationCode {
    static let prefix = "NGM1-"
    let secret: SymmetricKey

    init() { secret = SymmetricKey(size: .bits256) }

    init?(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix(Self.prefix) else { return nil }
        var encoded = String(value.dropFirst(Self.prefix.count)).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded), data.count == 32 else { return nil }
        secret = SymmetricKey(data: data)
    }

    var text: String {
        let encoded = secret.withUnsafeBytes { Data($0) }.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return Self.prefix + encoded
    }

    private func derive(_ purpose: String) -> SymmetricKey {
        HKDF<SHA256>.deriveKey(inputKeyMaterial: secret, info: Data("notifygo-migration-\(purpose)".utf8), outputByteCount: 32)
    }

    var lookup: String { derive("lookup").withUnsafeBytes { $0.map { String(format: "%02x", $0) }.joined() } }
    var key: SymmetricKey { derive("key") }
}

enum MigrationStatus { case pending, expired, completed }

private struct MigrationSecrets: Codable {
    var pushURL: String?
    var urls: [String: String]
}

enum CallbackError: LocalizedError {
    case unavailable, request(Int), invalidPayload, keychain, permission, migrationCode, migration(Int)
    var errorDescription: String? {
        switch self {
        case .unavailable: "The NotifyGo service is not configured in this build. Contact the app publisher."
        case .request(let status):
            switch status {
            case 400: "Check your fields, rules and template settings."
            case 401: "This device is no longer connected to NotifyGo. If you migrated to another device, continue there."
            case 404: "This Callback is no longer available. Refresh and try again."
            case 409: "You have reached the limit of 20 Callbacks."
            case 410: "This Callback is paused. Enable it before sending a test."
            case 422: "Apple signature verification failed. Check the signed payload, Bundle ID, App Apple ID and environment."
            case 429: "Too many requests. Try again in a minute."
            case 502: "APNs could not deliver this notification. Check the device registration and publisher push configuration, then try again."
            default: "The service is unavailable. Please try again."
            }
        case .invalidPayload: "Enter a valid JSON object."
        case .keychain: "Your credentials could not be saved securely. Please try again."
        case .permission: "Notifications are disabled. Enable them in Settings to receive pushes."
        case .migrationCode: "Enter a valid migration code from your other device."
        case .migration(let status):
            switch status {
            case 404: "This migration code is invalid, expired or already used. Create a new one on your old device."
            case 409: "This code can only be used on a different device that has no Callbacks."
            case 429: "Too many requests. Try again in a minute."
            default: "Migration could not be completed. Please try again."
            }
        }
    }
}

@MainActor
final class CallbackStore: ObservableObject {
    @Published private(set) var callbacks: [HostedCallback] = []
    @Published private(set) var isLoading = false
    @Published private(set) var connected = false
    @Published var error: String?
    @Published private(set) var deviceRegistered = false
    @Published private(set) var pushURL: String?
    @Published private(set) var deviceToken: String?
    private var installation: Installation?
    private var revision = 0
    private let session: URLSession
    private let baseURL: URL?

    init(session: URLSession = .shared) {
        self.session = session
        let configured = (Bundle.main.object(forInfoDictionaryKey: "NotifyGoServiceURL") as? String) ?? ""
        if let url = URL(string: configured), url.scheme == "https", url.host != nil,
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
           url.path.isEmpty || url.path == "/" {
            self.baseURL = url
        } else { self.baseURL = nil }
    }

    private var keychainQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "cn.alanhe.notifygo.installation",
         kSecAttrAccount as String: baseURL?.absoluteString ?? "unconfigured"]
    }

    private func loadInstallation() throws -> Installation? {
        var query = keychainQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw CallbackError.keychain }
        return try JSONDecoder().decode(Installation.self, from: data)
    }

    private func persist(_ value: Installation) throws {
        let data = try JSONEncoder().encode(value)
        let changes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(keychainQuery as CFDictionary, changes as CFDictionary)
        if status == errSecItemNotFound {
            var query = keychainQuery
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else { throw CallbackError.keychain }
        } else if status != errSecSuccess { throw CallbackError.keychain }
        installation = value
    }

    private func request<T: Decodable>(_ path: String, method: String = "GET", body: Data? = nil) async throws -> T {
        guard let baseURL else { throw CallbackError.unavailable }
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 30
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let installation { request.setValue("Bearer \(installation.token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw CallbackError.request((response as? HTTPURLResponse)?.statusCode ?? 503)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard baseURL != nil else { throw CallbackError.unavailable }
            if installation == nil {
                installation = try loadInstallation()
                if installation == nil {
                    struct Response: Decodable { let id: String; let token: String; let pushURL: String }
                    let response: Response = try await request("v1/installations", method: "POST", body: Data("{}".utf8))
                    try persist(Installation(id: response.id, token: response.token, pushURL: response.pushURL))
                }
            }
            pushURL = installation?.pushURL
            if pushURL == nil { try await rotateDeviceKey() }
            struct Response: Decodable { let callbacks: [HostedCallback] }
            let requestedRevision = revision
            let response: Response = try await request("v1/callbacks")
            if requestedRevision == revision {
                callbacks = response.callbacks.map { callback in
                    var value = callback
                    value.callbackURL = installation?.urls[value.id]
                    return value
                }
            }
            connected = true
            if let deviceToken { try await registerDevice(deviceToken) }
        } catch is CancellationError {} catch { report(error) }
    }

    func report(_ error: Error) {
        if (error as? URLError)?.code == .cancelled { return }
        self.error = error.localizedDescription
    }

    func enableNotifications() async {
        do {
            let allowed = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            guard allowed else { throw CallbackError.permission }
            UIApplication.shared.registerForRemoteNotifications()
        } catch { report(error) }
    }

    func registerDevice(_ token: String) async throws {
        deviceToken = token
        guard installation != nil else { return }
        let environment = (Bundle.main.object(forInfoDictionaryKey: "NotifyGoAPNsEnvironment") as? String) ?? "production"
        let data = try JSONEncoder().encode(["token": token, "environment": environment])
        let _: JSONValue = try await request("v1/device", method: "PUT", body: data)
        deviceRegistered = true
    }

    func rotateDeviceKey() async throws {
        struct Response: Decodable { let pushURL: String }
        let response: Response = try await request("v1/device/rotate", method: "POST", body: Data("{}".utf8))
        guard var value = installation else { throw CallbackError.keychain }
        value.pushURL = response.pushURL
        try persist(value)
        pushURL = response.pushURL
    }

    func createMigration() async throws -> (code: MigrationCode, expiresAt: Date) {
        guard let installation else { throw CallbackError.unavailable }
        struct Body: Encodable { let lookup: String; let payload: String }
        struct Response: Decodable { let expiresAt: String }
        let code = MigrationCode()
        let secrets = try JSONEncoder().encode(MigrationSecrets(pushURL: installation.pushURL, urls: installation.urls))
        guard let sealed = try AES.GCM.seal(secrets, using: code.key).combined else { throw CallbackError.keychain }
        let response: Response = try await request("v1/transfers", method: "POST", body: JSONEncoder().encode(Body(lookup: code.lookup, payload: sealed.base64EncodedString())))
        return (code, Self.date(response.expiresAt) ?? Date().addingTimeInterval(600))
    }

    func migrationStatus() async throws -> MigrationStatus {
        struct Response: Decodable { let pending: Bool }
        do {
            let response: Response = try await request("v1/transfers")
            return response.pending ? .pending : .expired
        } catch CallbackError.request(401) {
            // The new device now owns this installation; forget the revoked credentials here.
            SecItemDelete(keychainQuery as CFDictionary)
            installation = nil
            revision += 1
            callbacks = []
            pushURL = nil
            connected = false
            deviceRegistered = false
            return .completed
        }
    }

    func cancelMigration() async throws {
        let _: JSONValue = try await request("v1/transfers", method: "DELETE")
    }

    func redeemMigration(_ text: String) async throws {
        guard let code = MigrationCode(text) else { throw CallbackError.migrationCode }
        struct Response: Decodable { let id: String; let token: String; let payload: String }
        let response: Response
        do {
            response = try await request("v1/transfers/redeem", method: "POST", body: JSONEncoder().encode(["lookup": code.lookup]))
        } catch CallbackError.request(let status) { throw CallbackError.migration(status) }
        guard let data = Data(base64Encoded: response.payload),
              let opened = try? AES.GCM.open(AES.GCM.SealedBox(combined: data), using: code.key),
              let secrets = try? JSONDecoder().decode(MigrationSecrets.self, from: opened) else { throw CallbackError.migrationCode }
        try persist(Installation(id: response.id, token: response.token, pushURL: secrets.pushURL, urls: secrets.urls))
        revision += 1
        callbacks = []
        pushURL = secrets.pushURL
        deviceRegistered = false
        await refresh()
    }

    private static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value)
    }

    func sendDirect(title: String, subtitle: String, body: String, url: String, icon: String, group: String, sound: String, level: String) async throws {
        guard let pushURL, let endpoint = URL(string: pushURL) else { throw CallbackError.unavailable }
        struct Payload: Encodable {
            let title: String
            let subtitle: String
            let body: String
            let url: String
            let icon: String
            let group: String
            let sound: String
            let level: String
        }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Payload(title: title, subtitle: subtitle, body: body, url: url, icon: icon, group: group, sound: sound, level: level))
        let (_, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
            throw CallbackError.request((response as? HTTPURLResponse)?.statusCode ?? 503)
        }
    }

    func save(_ callback: HostedCallback) async throws -> HostedCallback {
        let isNew = callback.id.isEmpty
        var response: HostedCallback = try await request(isNew ? "v1/callbacks" : "v1/callbacks/\(callback.id)", method: isNew ? "POST" : "PUT", body: JSONEncoder().encode(callback))
        if let url = response.callbackURL, var value = installation {
            value.urls[response.id] = url
            try persist(value)
        }
        response.callbackURL = installation?.urls[response.id]
        revision += 1
        if let index = callbacks.firstIndex(where: { $0.id == response.id }) { callbacks[index] = response }
        else { callbacks.insert(response, at: 0) }
        return response
    }

    func rotate(_ id: String) async throws {
        struct Response: Decodable { let callbackURL: String }
        let response: Response = try await request("v1/callbacks/\(id)/rotate", method: "POST", body: Data("{}".utf8))
        guard var value = installation else { throw CallbackError.keychain }
        value.urls[id] = response.callbackURL
        try persist(value)
        revision += 1
        if let index = callbacks.firstIndex(where: { $0.id == id }) { callbacks[index].callbackURL = response.callbackURL }
    }

    func delete(_ id: String) async throws {
        let _: JSONValue = try await request("v1/callbacks/\(id)", method: "DELETE")
        revision += 1
        callbacks.removeAll { $0.id == id }
        if var value = installation { value.urls.removeValue(forKey: id); try persist(value) }
    }

    private func payload(_ text: String) throws -> JSONValue {
        guard let data = text.data(using: .utf8), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              case .object = value else { throw CallbackError.invalidPayload }
        return value
    }

    func preview(_ callback: HostedCallback, text: String, appleSample: Bool) async throws -> CallbackPreview {
        struct Body: Encodable { let config: HostedCallback; let payload: JSONValue; let appleSample: Bool }
        return try await request("v1/preview", method: "POST", body: JSONEncoder().encode(Body(config: callback, payload: payload(text), appleSample: appleSample)))
    }

    func test(_ id: String, text: String) async throws -> CallbackPreview {
        try await request("v1/callbacks/\(id)/test", method: "POST", body: JSONEncoder().encode(payload(text)))
    }

    func history(_ id: String) async throws -> [CallbackEvent] {
        struct Response: Decodable { let events: [CallbackEvent] }
        let response: Response = try await request("v1/callbacks/\(id)/history")
        return response.events
    }

    func history() async throws -> [CallbackEvent] {
        var events: [CallbackEvent] = []
        for callback in callbacks {
            events.append(contentsOf: try await history(callback.id))
        }
        return events.sorted { $0.createdAt > $1.createdAt }
    }
}
