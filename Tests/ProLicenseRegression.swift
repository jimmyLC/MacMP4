import Foundation

final class MemoryLicenseVault: LicenseVault {
    var data: Data?
    var failWrites = false
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { if failWrites { throw LicenseError.storage }; self.data = data }
}
final class PaymentMockProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))!
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status,data) = try Self.handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type":"application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data); client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
@main struct ProLicenseRegression {
    @MainActor static func main() async throws {
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String:String]
        let config = ProConfiguration(enabled:true,apiBaseURL:"https://pay.example.com",environment:"production",publicKey:fixture["publicKey"]!)
        let valid = try verifyLicenseToken(fixture["token"]!,email:" BUYER@example.com ",configuration:config)
        precondition(valid.lifetime)
        for (token,email) in [(fixture["stage"]!,"buyer@example.com"),(fixture["future"]!,"buyer@example.com"),(fixture["token"]!,"other@example.com"),(fixture["token"]!+"bad","buyer@example.com")] {
            do { _ = try verifyLicenseToken(token,email:email,configuration:config); fatalError("invalid license accepted") } catch {}
        }
        let stageConfig = ProConfiguration(enabled:true,apiBaseURL:"https://pay.example.com",environment:"staging",publicKey:fixture["publicKey"]!)
        precondition(stageConfig.baseURL == nil, "production accepts staging configuration")
        let suite = "local.macmp4.payment-test.\(UUID())"
        let defaults = UserDefaults(suiteName:suite)!
        defer { defaults.removePersistentDomain(forName:suite) }
        let access = AppAccess(defaults:defaults),vault=MemoryLicenseVault()
        let sessionConfig=URLSessionConfiguration.ephemeral; sessionConfig.protocolClasses=[PaymentMockProtocol.self]
        let session=URLSession(configuration:sessionConfig)
        func response(_ value:[String:Any]) -> Data { try! JSONSerialization.data(withJSONObject:value) }
        var paid=false, revoked=false, orderCalls=0
        PaymentMockProtocol.handler = { request in
            switch request.url!.path {
            case "/v1/config": return (200,response(["environment":"production","amount":90,"currency":"TWD","checkoutEnabled":true,"methods":["ApplePay","Credit"]]))
            case "/v1/orders":
                precondition(vault.data != nil,"order sent before storing recovery token")
                orderCalls += 1
                return (201,response(["orderId":"M1234567890123456789","checkoutURL":"https://pay.example.com/checkout/M1234567890123456789?token=test","amount":90,"currency":"TWD","environment":"production"]))
            case "/v1/licenses/activate":
                if revoked { return (409,response(["error":"license_revoked"])) }
                fallthrough
            default:
                return (200,paid ? response(["status":"paid","email":"buyer@example.com","serial":"MP4-"+String(repeating:"A",count:40),"licenseToken":fixture["token"]!]) : response(["status":"pending"]))
            }
        }
        let client=ProLicenseStore(configuration:config,vault:vault,session:session)
        await client.resume(access:access); precondition(!access.isPro && client.canPurchase)
        let invalidURL=await client.purchase(email:"invalid",method:"ApplePay")
        precondition(invalidURL == nil && orderCalls==0 && vault.data==nil)
        let url=await client.purchase(email:"Buyer@example.com",method:"ApplePay")
        precondition(url != nil && client.hasPendingPurchase && orderCalls==1)
        let pendingResult=await client.checkPayment(); precondition(!pendingResult && !access.isPro)
        await client.prepareNewOrder()
        precondition(!client.hasPendingPurchase && client.hasRecoverablePurchases, "old order recovery discarded")
        paid=true
        let paidResult=await client.checkPayment()
        precondition(paidResult && access.isPro && !client.hasPendingPurchase && !client.serial.isEmpty)
        PaymentMockProtocol.handler={ _ in throw URLError(.notConnectedToInternet) }
        let offlineAccess=AppAccess(defaults:defaults)
        let offline=ProLicenseStore(configuration:config,vault:vault,session:session)
        await offline.resume(access:offlineAccess)
        precondition(offlineAccess.isPro,"valid lifetime receipt lost offline")
        PaymentMockProtocol.handler={ _ in (409,response(["error":"license_revoked"])) }
        await offline.restore(email:"buyer@example.com",serial:client.serial)
        precondition(!offlineAccess.isPro,"revoked license retained Pro")
        let failedVault=MemoryLicenseVault();failedVault.failWrites=true
        PaymentMockProtocol.handler={ _ in (200,response(["environment":"production","amount":90,"currency":"TWD","checkoutEnabled":true,"methods":["Credit"]])) }
        let storageFailure=ProLicenseStore(configuration:config,vault:failedVault,session:session)
        await storageFailure.resume(access:AppAccess(defaults:defaults))
        let failureURL=await storageFailure.purchase(email:"buyer@example.com",method:"Credit")
        precondition(failureURL==nil && failedVault.data==nil)
        print("PASS: WebCrypto/CryptoKit signature compatibility, forged/staging/future/email rejection, pending/paid flow, recovery before create, offline lifetime, revocation, Keychain failure")
    }
}
