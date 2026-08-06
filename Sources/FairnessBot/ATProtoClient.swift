import Foundation

/// Minimal hand-rolled XRPC client. Only implements the handful of endpoints
/// this bot needs: logging in and posting as the bot's own account (against
/// its own PDS), and reading post text from the public, unauthenticated
/// Bluesky AppView for judging context.
///
/// An `actor` so the session tokens are serialized: callers await access
/// rather than racing on read/refresh. The bot's main loop processes Jetstream
/// events strictly one at a time, so there's never more than one in-flight
/// caller in practice — no need for single-flight refresh coalescing here.
actor ATProtoClient {
  private let config: Config
  private let urlSession: URLSession
  private var session: SessionResponse?

  /// Creates a client for the bot's PDS and the public AppView.
  ///
  /// - Parameters:
  ///   - config: The bot's configuration.
  ///   - urlSession: The session used for all requests; defaults to `.shared`.
  init(config: Config, urlSession: URLSession = .shared) {
    self.config = config
    self.urlSession = urlSession
  }

  // MARK: - Posting a reply

  /// Posts a new `app.bsky.feed.post` reply from the bot's own account.
  ///
  /// - Parameters:
  ///   - text: The reply's text.
  ///   - replyingTo: The root and parent references the new post replies to.
  /// - Returns: The created post's URI and CID.
  /// - Throws: Rethrows any error from the underlying network request.
  func postReply(text: String, replyingTo: PostRecord.ReplyRef) async throws -> CreateRecordResponse
  {
    let url = config.botPDSURL.appending(path: "xrpc/com.atproto.repo.createRecord")
    return try await sendWithRefresh(to: url) { session in
      let record = ReplyPostRecord(
        text: text,
        createdAt: ISO8601DateFormatter().string(from: Date()),
        reply: replyingTo,
      )
      return CreateRecordRequest(
        repo: session.did, collection: "app.bsky.feed.post", record: record)
    }
  }

  /// Applies the configured display name, description, avatar, and `bot` self-label to the
  /// bot's own `app.bsky.actor.profile` record.
  ///
  /// - Throws: Rethrows any error from the underlying network request. A missing or failed
  ///   avatar upload never blocks the rest of the profile update.
  func configureProfile() async throws {
    // Best-effort: a missing avatar file or a failed upload shouldn't block
    // the required displayName/description update.
    let avatarBlob = try? await uploadAvatarBlob()
    let url = config.botPDSURL.appending(path: "xrpc/com.atproto.repo.putRecord")
    let _: CreateRecordResponse = try await sendWithRefresh(to: url) { session in
      let record = ProfileRecord(
        displayName: String(config.botDisplayName.prefix(64)),
        description: String(config.botProfileDescription.prefix(256)),
        avatar: avatarBlob,
      )
      return PutProfileRecordRequest(repo: session.did, record: record)
    }
  }

  /// Uploads the configured avatar file as a blob.
  ///
  /// - Returns: A reference to the uploaded blob.
  /// - Throws: Rethrows any error from reading the file or the underlying network request.
  private func uploadAvatarBlob() async throws -> BlobRef {
    let data = try Data(contentsOf: config.botAvatarPath)
    let session = try await currentSession()
    let url = config.botPDSURL.appending(path: "xrpc/com.atproto.repo.uploadBlob")
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue(avatarMimeType, forHTTPHeaderField: "Content-Type")
    urlRequest.setValue("Bearer \(session.accessJwt)", forHTTPHeaderField: "Authorization")
    urlRequest.httpBody = data

    let (responseData, response) = try await urlSession.data(for: urlRequest)
    try Self.checkStatus(response, data: responseData)
    return try JSONDecoder().decode(UploadBlobResponse.self, from: responseData).blob
  }

  /// Bluesky's `app.bsky.actor.profile` lexicon only accepts `image/png` and
  /// `image/jpeg` avatar blobs, so this maps the configured file's extension
  /// rather than assuming one.
  private var avatarMimeType: String {
    switch config.botAvatarPath.pathExtension.lowercased() {
    case "png": "image/png"
    default: "image/jpeg"
    }
  }

  /// Publishes a `dev.maclong.feed.verdict` record to the bot's own repo.
  ///
  /// - Parameters:
  ///   - subject: A strong reference to the reply post being judged.
  ///   - reply: A strong reference to the bot's own callout reply, or `nil` for a
  ///     self-assessment (which never posts a public counter-reply).
  ///   - score: The gate score (0-100): the lowest of `rhetoric`, `relevance`, and `evidence`.
  ///   - rhetoric: The tone sub-score (0-100).
  ///   - relevance: The point-engagement sub-score (0-100).
  ///   - evidence: The evidence sub-score (0-100).
  ///   - reasoning: The judge's explanation for the score.
  ///   - replyText: The exact text of the bot's callout reply, or `nil` for a self-assessment.
  ///   - selfAssessment: Whether the subject is the target account's own reply, judged under
  ///     self-review mode. Defaults to `false`.
  /// - Returns: The created record's URI and CID.
  /// - Throws: Rethrows any error from the underlying network request.
  func publishVerdict(
    subject: StrongRef, reply: StrongRef?, score: Int, rhetoric: Int, relevance: Int, evidence: Int,
    reasoning: String, replyText: String?, selfAssessment: Bool = false,
  ) async throws -> CreateRecordResponse {
    let url = config.botPDSURL.appending(path: "xrpc/com.atproto.repo.createRecord")
    return try await sendWithRefresh(to: url) { session in
      let record = VerdictRecord(
        subject: subject, reply: reply, score: score, rhetoric: rhetoric, relevance: relevance,
        evidence: evidence, reasoning: reasoning, replyText: replyText,
        isSelfAssessment: selfAssessment, createdAt: ISO8601DateFormatter().string(from: Date()))
      return CreateRecordRequest(
        repo: session.did, collection: "dev.maclong.feed.verdict", record: record)
    }
  }

  // MARK: - Reading context (public AppView, no auth needed)

  /// Fetches the visible text of the parent and root posts of a reply, plus
  /// the replying account's handle, in one batched call — so the fairness
  /// judge has full conversational context to work from.
  ///
  /// - Parameters:
  ///   - replyURI: The AT-URI of the reply itself.
  ///   - reply: The reply's root and parent references.
  /// - Returns: The assembled context; any post that couldn't be fetched leaves its
  ///   corresponding field `nil`.
  /// - Throws: Rethrows any error from the underlying network request.
  func fetchContext(replyURI: String, reply: PostRecord.ReplyRef) async throws -> PostContext {
    let uris = Array(Set([reply.root.uri, reply.parent.uri, replyURI]))
    let posts = try await fetchPosts(uris: uris)
    let byURI = Dictionary(uniqueKeysWithValues: posts.map { ($0.uri, $0) })
    return PostContext(
      rootText: byURI[reply.root.uri]?.record.text,
      parentText: byURI[reply.parent.uri]?.record.text,
      parentAuthorHandle: byURI[reply.parent.uri]?.author.handle,
      replyAuthorHandle: byURI[replyURI]?.author.handle,
    )
  }

  /// Fetches a single post by its AT-URI.
  ///
  /// - Parameter uri: The post's AT-URI.
  /// - Returns: The fetched post.
  /// - Throws: `ATProtoError.postNotFound` if the AppView has no post at `uri`.
  func fetchPost(uri: String) async throws -> GetPostsResponse.PostView {
    guard let post = try await fetchPosts(uris: [uri]).first else {
      throw ATProtoError.postNotFound(uri)
    }
    return post
  }

  /// Resolves a handle to its DID via the public AppView.
  ///
  /// - Parameter handle: The handle to resolve.
  /// - Returns: The resolved DID.
  /// - Throws: Rethrows any error from the underlying network request.
  func resolveHandle(_ handle: String) async throws -> String {
    var components = URLComponents(
      url: config.appViewURL.appending(path: "xrpc/com.atproto.identity.resolveHandle"),
      resolvingAgainstBaseURL: false,
    )!
    components.queryItems = [URLQueryItem(name: "handle", value: handle)]
    let (data, response) = try await urlSession.data(from: components.url!)
    try Self.checkStatus(response, data: data)
    return try JSONDecoder().decode(ResolveHandleResponse.self, from: data).did
  }

  /// Fetches multiple posts in one batched AppView call.
  ///
  /// - Parameter uris: The AT-URIs to fetch.
  /// - Returns: Whichever of the requested posts the AppView could return; missing posts are
  ///   silently omitted rather than causing an error.
  /// - Throws: Rethrows any error from the underlying network request.
  private func fetchPosts(uris: [String]) async throws -> [GetPostsResponse.PostView] {
    var components = URLComponents(
      url: config.appViewURL.appending(path: "xrpc/app.bsky.feed.getPosts"),
      resolvingAgainstBaseURL: false,
    )!
    components.queryItems = uris.map { URLQueryItem(name: "uris", value: $0) }
    let (data, response) = try await urlSession.data(from: components.url!)
    try Self.checkStatus(response, data: data)
    return try JSONDecoder().decode(GetPostsResponse.self, from: data).posts
  }

  // MARK: - Auth

  /// Returns the current session, logging in if none has been established yet.
  ///
  /// - Returns: The active session.
  /// - Throws: Rethrows any error from `login()`.
  private func currentSession() async throws -> SessionResponse {
    if let session {
      return session
    }
    return try await login()
  }

  /// Creates a new session with the bot's own credentials.
  ///
  /// - Returns: The newly created session, which is also cached for future calls.
  /// - Throws: Rethrows any error from the underlying network request.
  private func login() async throws -> SessionResponse {
    let request = CreateSessionRequest(
      identifier: config.botHandle, password: config.botAppPassword)
    let url = config.botPDSURL.appending(path: "xrpc/com.atproto.server.createSession")
    let response: SessionResponse = try await send(request, to: url, bearer: nil)
    session = response
    return response
  }

  /// Refreshes the current session's tokens, or logs in fresh if there's no refresh token yet.
  ///
  /// - Returns: The refreshed (or newly created) session, which is also cached.
  /// - Throws: Rethrows any error from the underlying network request.
  private func refresh() async throws -> SessionResponse {
    guard let refreshJwt = session?.refreshJwt else { return try await login() }
    let url = config.botPDSURL.appending(path: "xrpc/com.atproto.server.refreshSession")
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("Bearer \(refreshJwt)", forHTTPHeaderField: "Authorization")

    let (data, response) = try await urlSession.data(for: urlRequest)
    try Self.checkStatus(response, data: data)
    let decoded = try JSONDecoder().decode(SessionResponse.self, from: data)
    session = decoded
    return decoded
  }

  // MARK: - Low-level request helpers

  /// Sends an authenticated request built from the current session, retrying
  /// once after a fresh `refresh()` if the session had expired.
  ///
  /// - Parameters:
  ///   - url: The endpoint to POST to.
  ///   - makeBody: Builds the request body from the active session (e.g. to read its DID).
  /// - Returns: The decoded response.
  /// - Throws: Rethrows any error from the underlying network request, including a second
  ///   `ATProtoError.unauthorized` if the retry after refreshing also fails.
  private func sendWithRefresh<Body: Encodable, Response: Decodable>(
    to url: URL, makeBody: (SessionResponse) -> Body,
  ) async throws -> Response {
    let activeSession = try await currentSession()
    let body = makeBody(activeSession)
    do {
      return try await send(body, to: url, bearer: activeSession.accessJwt)
    } catch ATProtoError.unauthorized {
      let refreshed = try await refresh()
      return try await send(body, to: url, bearer: refreshed.accessJwt)
    }
  }

  /// Sends a single JSON POST request and decodes its response.
  ///
  /// - Parameters:
  ///   - body: The request body to encode.
  ///   - url: The endpoint to POST to.
  ///   - bearer: The bearer token for the `Authorization` header, or `nil` to send none.
  /// - Returns: The decoded response.
  /// - Throws: `ATProtoError` on a non-2xx status; rethrows any other transport or decode error.
  private func send<Response: Decodable>(
    _ body: some Encodable, to url: URL, bearer: String?,
  ) async throws -> Response {
    var urlRequest = URLRequest(url: url)
    urlRequest.httpMethod = "POST"
    urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
    if let bearer {
      urlRequest.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
    }
    urlRequest.httpBody = try JSONEncoder().encode(body)

    let (data, response) = try await urlSession.data(for: urlRequest)
    try Self.checkStatus(response, data: data)
    return try JSONDecoder().decode(Response.self, from: data)
  }

  /// Throws an `ATProtoError` if `response` isn't a 2xx HTTP status.
  ///
  /// - Parameters:
  ///   - response: The response to check.
  ///   - data: The response body, used to decode an XRPC error message if the status isn't OK.
  /// - Throws: `ATProtoError.unauthorized` for a 401, or `ATProtoError.requestFailed` for any
  ///   other non-2xx status.
  private static func checkStatus(_ response: URLResponse, data: Data) throws {
    guard let http = response as? HTTPURLResponse else { return }
    guard (200..<300).contains(http.statusCode) else {
      if http.statusCode == 401 {
        throw ATProtoError.unauthorized
      }
      let decoded = try? JSONDecoder().decode(XRPCError.self, from: data)
      throw ATProtoError.requestFailed(
        status: http.statusCode, message: decoded?.message ?? decoded?.error)
    }
  }
}

/// An error raised while talking to a PDS or the public AppView.
enum ATProtoError: Error, CustomStringConvertible {
  /// The request's session token was rejected or had expired.
  case unauthorized
  /// The AppView had no post at the given AT-URI.
  case postNotFound(String)
  /// The request failed with a non-2xx, non-401 HTTP status.
  case requestFailed(status: Int, message: String?)

  var description: String {
    switch self {
    case .unauthorized:
      "Unauthorized (401) — session expired or invalid"
    case .postNotFound(let uri):
      "Post not found: \(uri)"
    case .requestFailed(let status, let message):
      "Request failed (\(status)): \(message ?? "no message")"
    }
  }
}
