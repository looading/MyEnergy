import Foundation

public struct AccountSession: Codable, Equatable, Sendable {
  public let accountID: String
  public let token: String
  public let expiresAt: Double
  public let mode: String
  public var isDevelopment: Bool { mode == "development" }
  public var isExpired: Bool { Date().timeIntervalSince1970 >= expiresAt }
}

public struct AuthChallenge: Codable, Sendable {
  public let id: String
  public let nonce: String
}
public struct RemoteVault: Codable, Sendable {
  public let revision: Int
  public let ciphertext: String?
  public let mutationID: String?
}
private struct APIErrorResponse: Decodable { let error: String }
private struct EmptyResponse: Decodable {}
private struct DevelopmentLogin: Encodable { let accountName: String }
private struct AppleLogin: Encodable { let identityToken: String; let challengeID: String }
private struct VaultWrite: Encodable { let expectedRevision: Int; let mutationID: String; let ciphertext: String }
private struct VaultWriteResult: Decodable { let revision: Int }

private final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    completionHandler(nil)
  }
}

public struct AccountClient: Sendable {
  private static let transport = URLSession(configuration: .ephemeral, delegate: RejectRedirects(), delegateQueue: nil)
  public let baseURL: URL
  public init(baseURL: URL) throws {
    let local = ["localhost", "127.0.0.1", "::1", "[::1]"].contains(baseURL.host?.lowercased() ?? "")
    guard baseURL.user == nil, baseURL.password == nil, baseURL.query == nil, baseURL.fragment == nil,
      baseURL.host != nil, baseURL.scheme == "https" || (baseURL.scheme == "http" && local) else { throw VaultError.invalidServer }
    self.baseURL = baseURL
  }
  public func challenge() async throws -> AuthChallenge {
    try await request(path: "v1/auth/challenge", method: "POST", body: Optional<String>.none)
  }
  public func signInApple(identityToken: String, challengeID: String) async throws -> AccountSession {
    try await request(path: "v1/auth/apple", method: "POST", body: AppleLogin(identityToken: identityToken, challengeID: challengeID))
  }
  public func signInDevelopment(accountName: String) async throws -> AccountSession {
    try await request(path: "v1/auth/development", method: "POST", body: DevelopmentLogin(accountName: accountName))
  }
  public func fetchVault(session: AccountSession) async throws -> RemoteVault {
    try await request(path: "v1/vault", method: "GET", session: session, body: Optional<String>.none)
  }
  public func uploadVault(_ ciphertext: String, expectedRevision: Int, mutationID: String, session: AccountSession) async throws -> Int {
    let result: VaultWriteResult = try await request(path: "v1/vault", method: "PUT", session: session,
      body: VaultWrite(expectedRevision: expectedRevision, mutationID: mutationID, ciphertext: ciphertext))
    return result.revision
  }
  public func signOut(session: AccountSession) async throws {
    let _: EmptyResponse = try await request(path: "v1/session", method: "DELETE", session: session, body: Optional<String>.none)
  }
  public func deleteAccount(session: AccountSession) async throws {
    let _: EmptyResponse = try await request(path: "v1/account", method: "DELETE", session: session, body: Optional<String>.none)
  }
  private func request<Body: Encodable, Result: Decodable>(path: String, method: String, session: AccountSession? = nil, body: Body?) async throws -> Result {
    var request = URLRequest(url: baseURL.appendingPathComponent(path))
    request.httpMethod = method
    request.timeoutInterval = 15
    request.cachePolicy = .reloadIgnoringLocalCacheData
    if let session { request.setValue("Bearer \(session.token)", forHTTPHeaderField: "Authorization") }
    if let body {
      request.httpBody = try JSONEncoder().encode(body)
      request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    let (data, response) = try await Self.transport.data(for: request)
    guard let http = response as? HTTPURLResponse, data.count <= 1_500_000 else { throw VaultError.invalidResponse }
    if http.statusCode == 401 { throw VaultError.sessionExpired }
    if http.statusCode == 409 { throw VaultError.revisionConflict }
    guard (200..<300).contains(http.statusCode) else {
      let code = (try? JSONDecoder().decode(APIErrorResponse.self, from: data).error) ?? "HTTP \(http.statusCode)"
      throw VaultError.server(code)
    }
    do { return try JSONDecoder().decode(Result.self, from: data) }
    catch { throw VaultError.invalidResponse }
  }
}
