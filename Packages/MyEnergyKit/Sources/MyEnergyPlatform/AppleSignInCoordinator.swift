import Foundation

public enum AppleSignInError: Error, LocalizedError, Sendable {
  case unavailable
  case busy
  case invalidNonce
  case missingPresentationWindow
  case missingIdentityToken

  public var errorDescription: String? {
    switch self {
    case .unavailable: "请在 iPhone、iPad 或 Mac 上完成 Apple 登录。"
    case .busy: "Apple 登录正在进行，请先完成或取消当前请求。"
    case .invalidNonce: "登录验证信息无效，请重新获取登录挑战。"
    case .missingPresentationWindow: "请打开应用窗口后再登录。"
    case .missingIdentityToken: "Apple 未返回可用登录凭证，请重试。"
    }
  }
}

#if canImport(AuthenticationServices) && (os(iOS) || os(macOS))
import AuthenticationServices
import CryptoKit
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// nonce 参数是服务器挑战的原始随机串；发送给 Apple 的 request.nonce 为 SHA-256 十六进制摘要。
/// 调用方必须保留此实例直到异步登录结束，并把原始挑战交回服务器验证一次性使用。
@MainActor
public final class AppleSignInCoordinator: NSObject {
  public typealias Credential = (identityToken: String, authorizationCode: String?)
  private var continuation: CheckedContinuation<Credential, any Error>?
  private var controller: ASAuthorizationController?
  private var presentationWindow: ASPresentationAnchor?
  private let suppliedWindow: ASPresentationAnchor?
  private var requestID: UUID?

  public init(presentationAnchor: ASPresentationAnchor? = nil) {
    suppliedWindow = presentationAnchor
    super.init()
  }

  public func obtainCredential(nonce: String) async throws -> Credential {
    try Task.checkCancellation()
    guard continuation == nil else { throw AppleSignInError.busy }
    guard !nonce.isEmpty, nonce.utf8.count <= 512,
      nonce.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
      throw AppleSignInError.invalidNonce
    }
    guard let anchor = suppliedWindow ?? currentWindow() else { throw AppleSignInError.missingPresentationWindow }
    let id = UUID()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        self.continuation = continuation
        requestID = id
        presentationWindow = anchor
        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = []
        request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        let controller = ASAuthorizationController(authorizationRequests: [request])
        self.controller = controller
        controller.delegate = self
        controller.presentationContextProvider = self
        controller.performRequests()
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.cancel(requestID: id) }
    }
  }

  public func cancel() {
    guard let requestID else { return }
    cancel(requestID: requestID)
  }

  private func cancel(requestID: UUID) {
    guard self.requestID == requestID else { return }
    let oldController = controller
    finish(.failure(CancellationError()))
    oldController?.cancel()
  }

  private func finish(_ result: Result<Credential, any Error>) {
    let pending = continuation
    continuation = nil
    controller = nil
    presentationWindow = nil
    requestID = nil
    pending?.resume(with: result)
  }

  private func currentWindow() -> ASPresentationAnchor? {
    #if os(macOS)
    NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
    #elseif os(iOS)
    UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
      .flatMap(\.windows).first(where: \.isKeyWindow)
    #endif
  }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
  public func authorizationController(
    controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization
  ) {
    guard self.controller === controller else { return }
    guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
      let tokenData = credential.identityToken, let token = String(data: tokenData, encoding: .utf8),
      !token.isEmpty else {
      finish(.failure(AppleSignInError.missingIdentityToken))
      return
    }
    let code = credential.authorizationCode.flatMap { String(data: $0, encoding: .utf8) }
    finish(.success((identityToken: token, authorizationCode: code)))
  }

  public func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
    guard self.controller === controller else { return }
    finish(.failure(error))
  }

  public func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
    // 请求开始前已经验证并持有真实窗口；系统仅在该请求生命周期内调用此方法。
    presentationWindow ?? suppliedWindow ?? ASPresentationAnchor()
  }
}
#else
@MainActor
public final class AppleSignInCoordinator {
  public init() {}

  public func obtainCredential(nonce: String) async throws -> (identityToken: String, authorizationCode: String?) {
    throw AppleSignInError.unavailable
  }

  public func cancel() {}
}
#endif
