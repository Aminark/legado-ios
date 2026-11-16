import Foundation
import Security
import UIKit
@preconcurrency import GoogleSignIn

struct WebDAVBackupAccount: Codable {
    var address: String
    var username: String
    var password: String
    func transport() throws -> WebDAVLibraryCloud { try .init(address: address, username: username, password: password) }
}

enum BackupCredentialVault {
    private static var service: String { (Bundle.main.bundleIdentifier ?? "Legado") + ".backup-accounts" }
    static func readWebDAV() throws -> WebDAVBackupAccount? {
        var query = query(); query[kSecReturnData as String] = true; query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw vaultError(status) }
        return try JSONDecoder().decode(WebDAVBackupAccount.self, from: data)
    }
    static func saveWebDAV(_ account: WebDAVBackupAccount) throws {
        let data = try JSONEncoder().encode(account)
        let status = SecItemUpdate(query() as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(); item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw vaultError(added) }
        } else if status != errSecSuccess { throw vaultError(status) }
    }
    static func removeWebDAV() throws {
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw vaultError(status) }
    }
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: "webdav"]
    }
    private static func vaultError(_ status: OSStatus) -> NSError {
        let message = status == errSecMissingEntitlement
            ? "此安装包缺少钥匙串权限（\(status)），请安装签名配置正确的版本。"
            : "无法访问系统钥匙串（\(status)），请解锁设备后重试。"
        return NSError(domain: "Legado.BackupKeychain", code: Int(status), userInfo: [NSLocalizedDescriptionKey: message])
    }
}

@MainActor
final class GoogleBackupAccount {
    private let driveScope = "https://www.googleapis.com/auth/drive.appdata"
    var email: String? { GIDSignIn.sharedInstance.currentUser?.profile?.email }
    var accountIdentifier: String? { GIDSignIn.sharedInstance.currentUser?.userID }
    var isConfigured: Bool {
        guard let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String,
              id.hasSuffix(".apps.googleusercontent.com"), !id.contains("$("),
              Bundle.main.object(forInfoDictionaryKey: "GoogleClientBundleID") as? String == Bundle.main.bundleIdentifier else { return false }
        let reversed = id.split(separator: ".").reversed().joined(separator: ".")
        let schemes = (Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]] ?? []).flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] }
        return schemes.contains(reversed)
    }
    func restore() async throws {
        guard isConfigured else { return }
        configure(); _ = try await GIDSignIn.sharedInstance.restorePreviousSignIn()
    }
    func bind() async throws {
        guard isConfigured else { throw LibraryCloudError.unavailable("此安装包尚未完成 Google 登录配置，请使用配置完成后的版本。") }
        configure()
        guard let presenter = Self.presenter() else { throw LibraryCloudError.unavailable("暂时无法打开 Google 登录，请返回此页面后重试。") }
        let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter, hint: nil, additionalScopes: [driveScope])
        guard result.user.grantedScopes?.contains(driveScope) == true else { throw RemoteLibraryError.authentication }
    }
    func disconnect() { GIDSignIn.sharedInstance.signOut() }
    func store() throws -> GoogleDriveBackupStore {
        guard let id = GIDSignIn.sharedInstance.currentUser?.userID else { throw RemoteLibraryError.authentication }
        return GoogleDriveBackupStore { [self] in try await token(for: id) }
    }
    static func handle(_ url: URL) -> Bool { GIDSignIn.sharedInstance.handle(url) }
    private func configure() {
        if let id = Bundle.main.object(forInfoDictionaryKey: "GIDClientID") as? String { GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: id) }
    }
    private func token(for expectedID: String) async throws -> String {
        guard let user = GIDSignIn.sharedInstance.currentUser, user.userID == expectedID else { throw RemoteLibraryError.authentication }
        let refreshed = try await user.refreshTokensIfNeeded()
        guard GIDSignIn.sharedInstance.currentUser?.userID == expectedID, refreshed.grantedScopes?.contains(driveScope) == true else { throw RemoteLibraryError.authentication }
        return refreshed.accessToken.tokenString
    }
    private static func presenter() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
        var view = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController
        while let presented = view?.presentedViewController { view = presented }
        return view
    }
}
