import Foundation

/// Networking primitives shared across OpenAI calls (transcription,
/// proofread, key validation).
///
/// The key decision here is that we DO NOT use `URLSession.shared`. The
/// shared session can wait silently for connectivity on a flaky network,
/// which makes a WiFi-off dictation attempt hang with no user feedback
/// until `timeoutIntervalForRequest` fires (often after a long delay).
///
/// Instead we build a short-lived ephemeral session per call with:
///   - `waitsForConnectivity = false` — fail immediately if offline
///   - explicit `timeoutIntervalForRequest` and `timeoutIntervalForResource`
///   - no caching (transcription responses are single-use)
enum OpenAINetworking {
    /// Build an ephemeral session that fails fast rather than queueing.
    /// `requestTimeout` is the per-packet timeout; `resourceTimeout` is
    /// the overall deadline for the whole transfer.
    static func makeSession(
        requestTimeout: TimeInterval,
        resourceTimeout: TimeInterval
    ) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = requestTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: config)
    }

    /// Synchronously perform `request` on `session`, returning the
    /// response tuple. Blocks the calling thread — only use on a
    /// background queue.
    static func performSync(
        _ request: URLRequest,
        on session: URLSession
    ) -> (Data?, URLResponse?, Error?) {
        var resultData: Data?
        var resultResponse: URLResponse?
        var resultError: Error?
        let sem = DispatchSemaphore(value: 0)

        let task = session.dataTask(with: request) { data, response, error in
            resultData = data
            resultResponse = response
            resultError = error
            sem.signal()
        }
        task.resume()
        sem.wait()
        return (resultData, resultResponse, resultError)
    }

    /// Humanise a URLError into something useful for notifications.
    static func describe(_ error: Error) -> String {
        if let urlErr = error as? URLError {
            switch urlErr.code {
            case .notConnectedToInternet:
                return "No internet connection."
            case .timedOut:
                return "Request timed out."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed:
                return "Cannot reach OpenAI — check your network."
            case .networkConnectionLost:
                return "Network connection lost."
            default:
                return urlErr.localizedDescription
            }
        }
        return error.localizedDescription
    }
}
