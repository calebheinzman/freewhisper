import Foundation

/// Refuses to follow a redirect that changes host.
///
/// Both HTTP clients in this directory POST something sensitive to an endpoint
/// the *user* configured — a whole meeting recording in the transcription case,
/// the transcript in the summarization case. A 307 or 308 reply re-issues that
/// request, body and headers included, at whatever `Location` the server names.
/// So a mistyped or hostile endpoint could bounce a recording to a host the user
/// never agreed to, and whether CFNetwork strips `Authorization` across hosts is
/// version-dependent — not something to rest a privacy guarantee on.
///
/// Declining the redirect makes URLSession hand back the 3xx response itself, so
/// the caller sees an HTTP error rather than a silent success. Failing closed is
/// the right direction here.
private final class SameHostRedirectPolicy: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let from = task.originalRequest?.url?.host?.lowercased()
        let to = request.url?.host?.lowercased()
        guard let from, let to, from == to else {
            Log.llm.notice("refused cross-host redirect away from \(from ?? "?", privacy: .public)")
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

/// The session every outbound request in this package should use.
///
/// A singleton because `URLSession` holds a connection pool worth reusing, and
/// because a session with a delegate retains that delegate until it is
/// invalidated — which this one never is, by design.
public enum EgressSession {
    public static let shared: URLSession = URLSession(
        configuration: .default,
        delegate: SameHostRedirectPolicy(),
        delegateQueue: nil
    )
}
