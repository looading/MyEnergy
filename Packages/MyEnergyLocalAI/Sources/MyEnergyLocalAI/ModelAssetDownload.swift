import Foundation

struct URLSessionModelAssetTransport: ModelAssetTransport {
  func download(_ asset: QwenAssetManifest.Asset, to destination: URL,
                progress: @escaping @Sendable (Int64) -> Void) async throws {
    try await ModelAssetDownload(asset: asset, destination: destination, progress: progress).run()
  }
}

/// URLSession 直接下载到磁盘，避免把整个模型放进 Data；可取消，且不接受超出清单的内容。
final class ModelAssetDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
  private let asset: QwenAssetManifest.Asset
  private let destination: URL
  private let progress: @Sendable (Int64) -> Void
  // URLSession 的代理队列与取消调用共享的状态全部由 lock 保护。
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Void, any Error>?
  private var session: URLSession?
  private var downloadTask: URLSessionDownloadTask?
  private var cancelled = false
  private var completed = false
  private var movedFile = false
  private var localError: (any Error)?

  init(asset: QwenAssetManifest.Asset, destination: URL, progress: @escaping @Sendable (Int64) -> Void) {
    self.asset = asset
    self.destination = destination
    self.progress = progress
  }

  func run() async throws {
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        let shouldStart = lock.withLock {
          guard !cancelled else { return false }
          self.continuation = continuation
          let configuration = URLSessionConfiguration.ephemeral
          configuration.urlCache = nil
          configuration.httpCookieStorage = nil
          configuration.urlCredentialStorage = nil
          configuration.httpShouldSetCookies = false
          configuration.timeoutIntervalForRequest = 90
          configuration.timeoutIntervalForResource = 3_600
          let queue = OperationQueue()
          queue.maxConcurrentOperationCount = 1
          let session = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
          self.session = session
          var request = URLRequest(url: asset.url, cachePolicy: .reloadIgnoringLocalCacheData)
          request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
          self.downloadTask = session.downloadTask(with: request)
          return true
        }
        if shouldStart {
          lock.withLock { downloadTask }?.resume()
        } else {
          continuation.resume(throwing: CancellationError())
        }
      }
    } onCancel: {
      let task = self.lock.withLock {
        self.cancelled = true
        return self.downloadTask
      }
      task?.cancel()
    }
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                  totalBytesExpectedToWrite: Int64) {
    if totalBytesWritten > asset.bytes || totalBytesExpectedToWrite > asset.bytes {
      lock.withLock { localError = AssetFailure.invalidDownload }
      downloadTask.cancel()
      return
    }
    progress(min(asset.bytes, max(0, totalBytesWritten)))
  }

  func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                  didFinishDownloadingTo location: URL) {
    guard !lock.withLock({ cancelled }) else { return }
    do {
      guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200,
            response.url?.scheme == "https" else { throw AssetFailure.invalidDownload }
      let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
      guard attributes[.type] as? FileAttributeType == .typeRegular,
            (attributes[.size] as? NSNumber)?.int64Value == asset.bytes else {
        throw AssetFailure.invalidDownload
      }
      try FileManager.default.moveItem(at: location, to: destination)
      lock.withLock { movedFile = true }
    } catch {
      lock.withLock { localError = error }
    }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
    let finish = lock.withLock { () -> (CheckedContinuation<Void, any Error>, (any Error)?)? in
      guard !completed, let continuation else { return nil }
      completed = true
      self.continuation = nil
      self.downloadTask = nil
      self.session = nil
      let resultError: (any Error)?
      if cancelled { resultError = CancellationError() }
      else if let localError { resultError = localError }
      else if let error { resultError = error }
      else { resultError = movedFile ? nil : AssetFailure.invalidDownload }
      return (continuation, resultError)
    }
    session.finishTasksAndInvalidate()
    guard let (continuation, error) = finish else { return }
    if let error { continuation.resume(throwing: error) }
    else { continuation.resume() }
  }

  func urlSession(_ session: URLSession, task: URLSessionTask,
                  willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                  completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
    // HF 的公开权重会跳转至签名 CDN；不携带账号凭据，并且禁止降级为明文 HTTP。
    guard request.url?.scheme == "https" else {
      lock.withLock { localError = AssetFailure.invalidDownload }
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }
}

enum AssetFailure: Error {
  case invalidDownload
  case invalidAsset
  case invalidDirectory
}
