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

  init(config: Config, urlSession: URLSession = .shared) {
    self.config = config
    self.urlSession = urlSession
  }

  // MARK: - Posting a reply

  func postReply(text: String, replyingTo: PostRecord.ReplyRef) async throws -> CreateRecordResponse
  {
    let record = ReplyPostRecord(
      text: text,
      createdAt: ISO8601DateFormatter().string(from: Date()),
      reply: replyingTo,
    )
    let url = config.botPDSURL.appending(path: "xrpc/com.atproto.repo.createRecord")

    let activeSession = try await currentSession()
    let body = CreateRecordRequest(
      repo: activeSession.did, collection: "app.bsky.feed.post", record: record)

    do {
      return try await send(body, to: url, bearer: activeSession.accessJwt)
    } catch ATProtoError.unauthorized {
      let refreshed = try await refresh()
      return try await send(body, to: url, bearer: refreshed.accessJwt)
    }
  }

  func configureProfile() async throws {
    let activeSession = try await currentSession()
    let record = ProfileRecord(
      displayName: String(config.botDisplayName.prefix(64)),
      description: String(config.botProfileDescription.prefix(256)),
    )
    let body = PutProfileRecordRequest(repo: activeSession.did, record: record)
    let url = config.botPDSURL.appending(path: "xrpc/com.atproto.repo.putRecord")

    do {
      let _: CreateRecordResponse = try await send(body, to: url, bearer: activeSession.accessJwt)
    } catch ATProtoError.unauthorized {
      let refreshed = try await refresh()
      let _: CreateRecordResponse = try await send(body, to: url, bearer: refreshed.accessJwt)
    }
  }

  // MARK: - Reading context (public AppView, no auth needed)

  /// Fetches the visible text of the parent and root posts of a reply, plus
  /// the replying account's handle, in one batched call — so the fairness
  /// judge has full conversational context to work from.
  func fetchContext(replyURI: String, reply: PostRecord.ReplyRef) async throws -> PostContext {
    let uris = Array(Set([reply.root.uri, reply.parent.uri, replyURI]))
    let posts = try await fetchPosts(uris: uris)
    let byURI = Dictionary(uniqueKeysWithValues: posts.map { ($0.uri, $0) })
    return PostContext(
      rootText: byURI[reply.root.uri]?.record.text,
      parentText: byURI[reply.parent.uri]?.record.text,
      replyAuthorHandle: byURI[replyURI]?.author.handle,
    )
  }

  func fetchPost(uri: String) async throws -> GetPostsResponse.PostView {
    guard let post = try await fetchPosts(uris: [uri]).first else {
      throw ATProtoError.postNotFound(uri)
    }
    return post
  }

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

  private func currentSession() async throws -> SessionResponse {
    if let session {
      return session
    }
    return try await login()
  }

  private func login() async throws -> SessionResponse {
    let request = CreateSessionRequest(
      identifier: config.botHandle, password: config.botAppPassword)
    let url = config.botPDSURL.appending(path: "xrpc/com.atproto.server.createSession")
    let response: SessionResponse = try await send(request, to: url, bearer: nil)
    session = response
    return response
  }

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

  // MARK: - Low-level request helper

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

enum ATProtoError: Error, CustomStringConvertible {
  case unauthorized
  case postNotFound(String)
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
