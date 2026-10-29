import Foundation
import Combine
import CryptoKit
import Security
import IOKit

private final class NoPaymentRedirects: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
private func privatePaymentSession() -> URLSession {
    let config = URLSessionConfiguration.ephemeral
    config.urlCache = nil
    return URLSession(configuration: config, delegate: NoPaymentRedirects(), delegateQueue: nil)
}

struct ProConfiguration: Codable {
    let enabled: Bool
    let apiBaseURL: String
    let environment: String
    let publicKey: String

    static func bundled() -> ProConfiguration? {
        guard let url = Bundle.main.url(forResource: "ProConfiguration", withExtension: "json"),
              let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    var baseURL: URL? {
        guard enabled, let url = URL(string: apiBaseURL), url.scheme == "https",
              let host = url.host, !host.hasSuffix(".invalid"), url.port == nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", let keyData = Data(base64Encoded: publicKey),
              (try? P256.Signing.PublicKey(x963Representation: keyData)) != nil else { return nil }
        #if MACMP4_STAGING
        guard ["staging", "production"].contains(environment) else { return nil }
        #else
        guard environment == "production" else { return nil }
        #endif
        return url
    }
}

struct LicenseClaims: Codable {
    let version: Int
    let product: String
    let environment: String
    let licenseId: String
    let email: String
    let issuedAt: Int
    let lifetime: Bool
}

enum LicenseError: LocalizedError {
    case unavailable, invalid, storage, revoked, pending, deviceReplaced, request(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return L("付款服務尚未設定完成，請稍後再試。")
        case .invalid: return L("無法驗證授權，請確認 Email 與序號。")
        case .storage: return L("無法將授權資料儲存至鑰匙圈，請確認鑰匙圈已解鎖。")
        case .revoked: return L("此授權已停用，請聯絡客服。")
        case .pending: return L("尚未收到付款確認，可稍後再檢查。")
        case .deviceReplaced: return L("此序號已在另一台電腦啟用，這台已變回 Free。要改在這台使用，請在「已有序號？恢復 Pro」輸入 Email 與序號。")
        case .request(let code):
            switch code {
            case "rate_limited": return L("操作太頻繁，請稍後再試。")
            case "pending_limit": return L("未完成訂單較多，請聯絡客服協助確認付款。")
            case "checkout_expired": return L("付款連結已過期，請聯絡客服協助處理訂單。")
            case "device_change_limited": return L("24 小時內只能更換一次使用的電腦，請稍後再試，或聯絡客服。")
            case "update_required": return L("請先更新 MacMP4 到最新版本。")
            default: return L("目前無法連線至付款服務，請稍後再試。")
            }
        }
    }
}

/// 這台 Mac 的穩定識別（硬體 UUID 加 App 專用字串後雜湊）。只送出雜湊，伺服器無法還原硬體 UUID。
func licenseDeviceID() -> String {
    var uuid = ""
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
    if service != 0 {
        uuid = (IORegistryEntryCreateCFProperty(service, "IOPlatformUUID" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? String) ?? ""
        IOObjectRelease(service)
    }
    if uuid.isEmpty {
        let key = "LicenseFallbackDeviceID"
        uuid = UserDefaults.standard.string(forKey: key) ?? UUID().uuidString
        UserDefaults.standard.set(uuid, forKey: key)
    }
    let digest = SHA256.hash(data: Data(("macmp4.device.v1:" + uuid).utf8))
    return Data(digest).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}
/// 購買信與付款頁使用 App 目前的語言（"zh-Hant" 或 "en"）。
func licenseLanguage(override: String? = UserDefaults.standard.string(forKey: "AppLanguage"), preferred: [String] = Locale.preferredLanguages) -> String {
    ((override ?? preferred.first ?? "en").lowercased().hasPrefix("zh")) ? "zh-Hant" : "en"
}
func normalizedLicenseEmail(_ value: String) -> String { value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
func decodeBase64URL(_ value: String) -> Data? {
    let base = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    return Data(base64Encoded: base + String(repeating: "=", count: (4 - base.count % 4) % 4))
}
func verifyLicenseToken(_ token: String, email: String, configuration: ProConfiguration) throws -> LicenseClaims {
    guard configuration.baseURL != nil else { throw LicenseError.unavailable }
    let parts = token.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 2, let keyData = Data(base64Encoded: configuration.publicKey),
          let signatureData = decodeBase64URL(String(parts[1])),
          let payload = decodeBase64URL(String(parts[0])), payload.count < 4096,
          let key = try? P256.Signing.PublicKey(x963Representation: keyData),
          let signature = try? P256.Signing.ECDSASignature(rawRepresentation: signatureData),
          key.isValidSignature(signature, for: Data(parts[0].utf8)),
          let claims = try? JSONDecoder().decode(LicenseClaims.self, from: payload),
          claims.version == 1, claims.product == "macmp4-pro-lifetime", claims.lifetime,
          claims.environment == configuration.environment, !claims.licenseId.isEmpty,
          claims.email == normalizedLicenseEmail(email), claims.issuedAt > 0,
          claims.issuedAt <= Int(Date().timeIntervalSince1970) + 300 else { throw LicenseError.invalid }
    return claims
}

protocol LicenseVault {
    func read() throws -> Data?
    func write(_ data: Data) throws
}
struct KeychainLicenseVault: LicenseVault {
    var environment = "production"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: (Bundle.main.bundleIdentifier ?? "local.jimmy.MacMP4") + ".license." + environment,
         kSecAttrAccount as String: "pro-v1"]
    }
    func read() throws -> Data? {
        var lookup = query
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LicenseError.storage }
        return item as? Data
    }
    func write(_ data: Data) throws {
        let values: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        let update = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if update == errSecItemNotFound {
            let added = query.merging(values) { _, new in new }
            guard SecItemAdd(added as CFDictionary, nil) == errSecSuccess else { throw LicenseError.storage }
        } else if update != errSecSuccess { throw LicenseError.storage }
    }
}
struct PendingPurchase: Codable {
    var email: String
    var method: String
    var accessToken: String
    var orderId: String?
    var checkoutURL: String?
}
struct LicenseRecord: Codable {
    var email: String = ""
    var serial: String = ""
    var licenseToken: String = ""
    var pending: PendingPurchase?
    var previousPending: [PendingPurchase]?
}
struct OrderReply: Decodable { let orderId: String; let checkoutURL: String; let amount: Int; let currency: String; let environment: String }
struct PaidReply: Decodable { let status: String; let email: String?; let serial: String?; let licenseToken: String? }
struct PaymentOptions: Decodable { let environment: String; let amount: Int; let currency: String; let checkoutEnabled: Bool; let methods: [String] }
struct ServiceFailure: Decodable { let error: String }

/// 金流密鑰永不進入 App。授權只能由固定公開金鑰驗證的伺服器收據解鎖。
final class ProLicenseStore: ObservableObject {
    @Published private(set) var email = ""
    @Published private(set) var serial = ""
    @Published private(set) var isBusy = false
    @Published private(set) var hasPendingPurchase = false
    @Published private(set) var message: String?
    @Published private(set) var options: PaymentOptions?
    @Published private(set) var showPurchaseCelebration = false
    private let configuration: ProConfiguration?
    private let vault: LicenseVault
    private let session: URLSession
    private let deviceID: String
    private var record = LicenseRecord()
    private weak var access: AppAccess?
    private var started = false
    var hasRecoverablePurchases: Bool { record.pending != nil || !(record.previousPending ?? []).isEmpty }
    var pendingEmail: String? { record.pending?.email }
    var pendingMethod: String? { record.pending?.method }
    var privacyURL: URL { configuration?.baseURL?.appendingPathComponent("privacy") ?? URL(string: "https://jimmy-tools.com/MacMP4/")! }
    var isConfigured: Bool { configuration?.baseURL != nil }
    var canPurchase: Bool { isConfigured && options?.checkoutEnabled == true }
    var applePayAvailable: Bool { options?.methods.contains("ApplePay") == true }

    init(configuration: ProConfiguration? = .bundled(), vault: LicenseVault? = nil, session: URLSession? = nil, deviceID: String? = nil) {
        self.deviceID = deviceID ?? licenseDeviceID()
        self.configuration = configuration; self.vault = vault ?? KeychainLicenseVault(environment: configuration?.environment ?? "production"); self.session = session ?? privatePaymentSession()
    }
    @MainActor func resume(access: AppAccess) async {
        self.access = access
        guard !started else { return }
        started = true
        do {
            if let data = try vault.read() { record = try JSONDecoder().decode(LicenseRecord.self, from: data) }
            publishRecord()
            if !record.licenseToken.isEmpty, let configuration,
               (try? verifyLicenseToken(record.licenseToken, email: record.email, configuration: configuration)) != nil {
                access.updateEntitlement(.pro)
            }
        } catch { message = error.localizedDescription }
        await loadOptions()
        if hasRecoverablePurchases { _ = await checkPayment() }
        // 離線時保留已驗簽的終身收據；連線恢復時以伺服器狀態檢查撤銷。
        if !record.serial.isEmpty { await restore(email: record.email, serial: record.serial, quietly: true) }
    }
    @MainActor private func publishRecord() {
        email = record.email; serial = record.serial; hasPendingPurchase = record.pending != nil
    }
    private func persist(_ updated: LicenseRecord) throws {
        try vault.write(JSONEncoder().encode(updated)); record = updated
    }
    @MainActor func dismissPurchaseCelebration() { showPurchaseCelebration = false }
    @MainActor func reportBrowserFailure() { message = L("無法開啟瀏覽器，請按「重新開啟付款頁」重試。") }
    @MainActor func loadOptions() async {
        guard isConfigured else { return }
        do {
            let result: PaymentOptions = try await call("/v1/config", method: "GET")
            guard result.environment == configuration?.environment, result.amount == 90, result.currency == "TWD" else { throw LicenseError.invalid }
            options = result
        } catch { message = error.localizedDescription }
    }
    @MainActor func purchase(email: String, method: String) async -> URL? {
        guard !isBusy else { return nil }
        guard canPurchase else { message = LicenseError.unavailable.localizedDescription; return nil }
        let normalized = normalizedLicenseEmail(email)
        guard record.pending != nil || normalized.range(of: "^[a-z0-9.!#$%&'*+/=?^_`{|}~-]+@[a-z0-9][a-z0-9.-]*\\.[a-z]{2,63}$", options: .regularExpression) != nil && normalized.count <= 254 else {
            message = L("請輸入有效的 Email。"); return nil
        }
        isBusy = true; message = nil
        defer { isBusy = false }
        do {
            if record.pending == nil {
                let random = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
                let token = random.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
                var updated = record
                updated.pending = PendingPurchase(email: normalizedLicenseEmail(email), method: method, accessToken: token)
                // 先保存恢復能力，再向伺服器建單；網路逾時可使用相同權杖重試。
                try persist(updated); publishRecord()
            }
            guard let pending = record.pending else { throw LicenseError.invalid }
            let reply: OrderReply = try await call("/v1/orders", body: ["email":pending.email,"method":pending.method,"accessToken":pending.accessToken,"language":licenseLanguage()])
            guard reply.amount == 90, reply.currency == "TWD", reply.environment == configuration?.environment,
                  let url = URL(string: reply.checkoutURL), url.scheme == "https", url.host == configuration?.baseURL?.host,
                  url.port == nil, url.user == nil, url.password == nil, url.path == "/checkout/" + reply.orderId,
                  reply.orderId.range(of: "^[A-Z0-9]{20}$", options: .regularExpression) != nil else { throw LicenseError.invalid }
            var updated = record
            updated.pending?.orderId = reply.orderId; updated.pending?.checkoutURL = reply.checkoutURL
            try persist(updated); publishRecord()
            return url
        } catch { message = error.localizedDescription; return nil }
    }
    @MainActor @discardableResult func checkPayment() async -> Bool {
        guard !isBusy else { return false }
        let pendingOrders = ([record.pending].compactMap { $0 }) + (record.previousPending ?? [])
        guard !pendingOrders.isEmpty else { return false }
        isBusy = true; defer { isBusy = false }
        var lastError: Error?
        for pending in pendingOrders {
            guard let orderId = pending.orderId else { continue }
            do {
                let reply: PaidReply = try await call("/v1/orders/" + orderId, method: "GET", token: pending.accessToken)
                if reply.status == "paid" {
                    try accept(reply, expectedEmail: pending.email, celebratePurchase: true)
                    message = L("超級感謝！Pro 已啟用。")
                    return true
                }
            } catch { lastError = error }
        }
        message = lastError?.localizedDescription ?? LicenseError.pending.localizedDescription
        return false
    }
    /// 重建前先檢查原訂單，保留其權杖，以防延遲通知導致付費後找不到授權。
    @MainActor func prepareNewOrder() async {
        guard !isBusy, let pending = record.pending else { return }
        isBusy = true; defer { isBusy = false }
        do {
            if let id = pending.orderId {
                let reply: PaidReply = try await call("/v1/orders/" + id, method: "GET", token: pending.accessToken)
                if reply.status == "paid" { try accept(reply, expectedEmail: pending.email, celebratePurchase: true); return }
            }
            var updated = record
            var previous = updated.previousPending ?? []
            guard previous.count < 5 else { throw LicenseError.request("pending_limit") }
            previous.append(pending); updated.previousPending = previous; updated.pending = nil
            try persist(updated); publishRecord(); message = nil
        } catch { message = error.localizedDescription }
    }
    @MainActor func restore(email: String, serial: String, quietly: Bool = false) async {
        guard !isBusy else { return }
        isBusy = true; if !quietly { message = nil }; defer { isBusy = false }
        do {
            // 背景檢查（啟動時）不會搶走其他電腦的授權；使用者按「啟用 Pro」才會改由這台使用。
            let reply: PaidReply = try await call("/v1/licenses/activate", body: ["email":normalizedLicenseEmail(email),"serial":serial,"deviceId":deviceID,"takeover":quietly ? "false" : "true"])
            try accept(reply, expectedEmail: normalizedLicenseEmail(email))
            if !quietly { message = L("超級感謝！Pro 已啟用。") }
        } catch LicenseError.deviceReplaced {
            var updated = record; updated.licenseToken = ""
            do { try persist(updated); publishRecord() } catch { message = error.localizedDescription }
            access?.updateEntitlement(.free); message = LicenseError.deviceReplaced.localizedDescription
        } catch LicenseError.revoked {
            var updated = record; updated.licenseToken = ""
            do { try persist(updated); publishRecord() } catch { message = error.localizedDescription }
            access?.updateEntitlement(.free); message = LicenseError.revoked.localizedDescription
        } catch { if !quietly { message = error.localizedDescription } }
    }
    @MainActor private func accept(_ reply: PaidReply, expectedEmail: String, celebratePurchase: Bool = false) throws {
        guard reply.status == "paid", let email = reply.email, let serial = reply.serial,
              let token = reply.licenseToken, let configuration,
              email == normalizedLicenseEmail(expectedEmail) else { throw LicenseError.invalid }
        _ = try verifyLicenseToken(token, email: email, configuration: configuration)
        let firstPurchase = celebratePurchase && record.licenseToken.isEmpty
        var updated = record
        updated.email = email; updated.serial = serial; updated.licenseToken = token; updated.pending = nil; updated.previousPending = nil
        try persist(updated); publishRecord(); access?.updateEntitlement(.pro)
        if firstPurchase { showPurchaseCelebration = true }
    }
    private func call<T: Decodable>(_ path: String, method: String = "POST", body: [String:String]? = nil, token: String? = nil) async throws -> T {
        guard let base = configuration?.baseURL else { throw LicenseError.unavailable }
        var request = URLRequest(url: base.appendingPathComponent(String(path.dropFirst())), timeoutInterval: 20)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue(deviceID, forHTTPHeaderField: "X-Device-Id")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, data.count < 32768 else { throw LicenseError.invalid }
        guard (200..<300).contains(http.statusCode) else {
            let code = (try? JSONDecoder().decode(ServiceFailure.self, from: data))?.error ?? "service_unavailable"
            if code == "license_revoked" { throw LicenseError.revoked }
            if code == "device_replaced" { throw LicenseError.deviceReplaced }
            if code == "invalid_license" { throw LicenseError.invalid }
            throw LicenseError.request(code)
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
}
