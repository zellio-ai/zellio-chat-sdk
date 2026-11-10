#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import ZellioChatCore

/// The real network layer. URLSession only. No third-party code.
///
/// Timeouts: connect and idle reads use the request timeout (30 s). Uploads use 120 s.
/// The SSE stream has no read timeout here; `RealtimeClient` treats 45 s without bytes as dead.
final class URLSessionTransport: HTTPTransport, @unchecked Sendable {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = false
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    private static func urlRequest(_ request: HTTPRequest) -> URLRequest {
        var result = URLRequest(url: request.url)
        result.httpMethod = request.method
        result.timeoutInterval = request.timeout > 0 ? request.timeout : 60 * 60 * 24
        for (key, value) in request.headers { result.setValue(value, forHTTPHeaderField: key) }
        result.httpBody = request.body
        return result
    }

    static func headers(_ response: HTTPURLResponse) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            if let key = key as? String, let value = value as? String { result[key] = value }
        }
        return result
    }

    static func map(_ error: Error) -> Error {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled: return CancellationError()
            case .timedOut: return ChatAPIError.timeout
            default: return ChatAPIError.network
            }
        }
        if error is CancellationError { return error }
        return ChatAPIError.network
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        do {
            let (data, response) = try await session.data(for: URLSessionTransport.urlRequest(request))
            guard let http = response as? HTTPURLResponse else { throw ChatAPIError.network }
            return HTTPResponse(status: http.statusCode, headers: URLSessionTransport.headers(http), body: data)
        } catch {
            throw URLSessionTransport.map(error)
        }
    }

    func upload(_ request: HTTPRequest, progress: @escaping @Sendable (Double) -> Void) async throws -> HTTPResponse {
        let box = UploadBox(progress: progress)
        let uploadSession = URLSession(configuration: session.configuration, delegate: box, delegateQueue: nil)
        defer { uploadSession.finishTasksAndInvalidate() }
        var urlRequest = URLSessionTransport.urlRequest(request)
        let body = urlRequest.httpBody ?? Data()
        urlRequest.httpBody = nil
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HTTPResponse, Error>) in
                let task = uploadSession.uploadTask(with: urlRequest, from: body) { data, response, error in
                    if let error = error {
                        continuation.resume(throwing: URLSessionTransport.map(error))
                    } else if let http = response as? HTTPURLResponse {
                        continuation.resume(returning: HTTPResponse(status: http.statusCode, headers: URLSessionTransport.headers(http), body: data ?? Data()))
                    } else {
                        continuation.resume(throwing: ChatAPIError.network)
                    }
                }
                box.task = task
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    func stream(_ request: HTTPRequest) -> AsyncThrowingStream<StreamChunk, Error> {
        AsyncThrowingStream { continuation in
            let delegate = StreamDelegate(continuation: continuation)
            let configuration = self.session.configuration
            configuration.timeoutIntervalForRequest = 60 * 60 * 24
            configuration.timeoutIntervalForResource = 60 * 60 * 24
            let streamSession = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            let task = streamSession.dataTask(with: URLSessionTransport.urlRequest(request))
            continuation.onTermination = { _ in
                task.cancel()
                streamSession.invalidateAndCancel()
            }
            task.resume()
        }
    }
}

private final class UploadBox: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Double) -> Void
    private let lock = NSLock()
    private var current: URLSessionTask?
    private var cancelled = false

    init(progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }

    var task: URLSessionTask? {
        get { lock.lock(); defer { lock.unlock() }; return current }
        set {
            lock.lock()
            current = newValue
            let shouldCancel = cancelled
            lock.unlock()
            if shouldCancel { newValue?.cancel() }
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let running = current
        lock.unlock()
        running?.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        guard totalBytesExpectedToSend > 0 else { return }
        progress(min(1, Double(totalBytesSent) / Double(totalBytesExpectedToSend)))
    }
}

private final class StreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation
    private var status = 0
    private var headers: [String: String] = [:]
    private var errorBody = Data()

    init(continuation: AsyncThrowingStream<StreamChunk, Error>.Continuation) { self.continuation = continuation }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let http = response as? HTTPURLResponse {
            status = http.statusCode
            headers = URLSessionTransport.headers(http)
        }
        if (200..<300).contains(status) { continuation.yield(.opened) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if (200..<300).contains(status) {
            continuation.yield(.data(data))
        } else if errorBody.count < 16_384 {
            errorBody.append(data)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if !(200..<300).contains(status), status != 0 {
            let retry = headers.first { $0.key.lowercased() == "retry-after" }.flatMap { TimeInterval($0.value) }
            continuation.finish(throwing: ChatAPIError.http(status: status, code: ErrorPolicy.parseCode(from: errorBody), retryAfter: retry))
        } else if let error = error {
            if let urlError = error as? URLError, urlError.code == .cancelled {
                continuation.finish()
            } else {
                continuation.finish(throwing: ChatAPIError.network)
            }
        } else {
            continuation.finish()
        }
    }
}
#endif
