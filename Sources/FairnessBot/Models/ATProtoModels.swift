import Foundation

// MARK: - com.atproto.server.createSession / refreshSession

/// The request body for `com.atproto.server.createSession`.
struct CreateSessionRequest: Encodable {
  let identifier: String
  let password: String
}

/// The response to a create- or refresh-session call: the account's identity and auth tokens.
struct SessionResponse: Decodable {
  let did: String
  let handle: String
  let accessJwt: String
  let refreshJwt: String
}

// MARK: - com.atproto.repo.createRecord

/// The request body for `com.atproto.repo.createRecord`, generic over the record type written.
struct CreateRecordRequest<Record: Encodable>: Encodable {
  let repo: String
  let collection: String
  let record: Record
}

/// An `app.bsky.feed.post` record body for one of the bot's own callout replies.
struct ReplyPostRecord: Encodable {
  let type = "app.bsky.feed.post"
  let text: String
  let createdAt: String
  let reply: PostRecord.ReplyRef

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case text, createdAt, reply
  }
}

/// The response to a successful `com.atproto.repo.createRecord` call.
struct CreateRecordResponse: Decodable {
  let uri: String
  let cid: String
}

// MARK: - dev.maclong.feed.verdict

/// A fairness-bot verdict, published to the bot's own repo alongside the
/// callout reply it triggered. See `lexicons/dev.maclong.feed.verdict.json`.
struct VerdictRecord: Encodable {
  let type = "dev.maclong.feed.verdict"
  /// The reply post being judged.
  let subject: StrongRef
  /// The bot's own callout reply, posted in response to the subject. `nil` for a
  /// self-assessment, which never posts a public counter-reply.
  let reply: StrongRef?
  /// The gate score (0-100): the lowest of `rhetoric`, `relevance`, and `evidence`.
  let score: Int
  /// Tone, 0-100. See `FairnessVerdict.rhetoric`.
  let rhetoric: Int
  /// Engagement with the actual point, 0-100. See `FairnessVerdict.relevance`.
  let relevance: Int
  /// Support for the reply's claims, 0-100. See `FairnessVerdict.evidence`.
  let evidence: Int
  /// The judge's explanation for the score.
  let reasoning: String
  /// The exact text of the bot's callout reply. `nil` for a self-assessment.
  let replyText: String?
  /// Whether the subject is the target account's own reply, judged under self-review mode,
  /// rather than an external reply to the target.
  let isSelfAssessment: Bool
  let createdAt: String

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case subject, reply, score, rhetoric, relevance, evidence, reasoning, replyText
    case isSelfAssessment = "selfAssessment"
    case createdAt
  }
}

/// The request body for `com.atproto.repo.putRecord` against `app.bsky.actor.profile`.
struct PutProfileRecordRequest: Encodable {
  let repo: String
  let collection = "app.bsky.actor.profile"
  let rkey = "self"
  let record: ProfileRecord
}

/// An `app.bsky.actor.profile` record body: the bot's display name, description, avatar,
/// and automation self-label.
struct ProfileRecord: Encodable {
  let type = "app.bsky.actor.profile"
  let displayName: String
  let description: String
  let avatar: BlobRef?
  let labels = SelfLabels(values: [SelfLabel(val: "bot")])

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case displayName, description, avatar, labels
  }
}

// MARK: - com.atproto.repo.uploadBlob

/// The response to a successful `com.atproto.repo.uploadBlob` call.
struct UploadBlobResponse: Decodable {
  let blob: BlobRef
}

/// A blob reference as returned by `uploadBlob` and embedded back into a
/// record (e.g. `ProfileRecord.avatar`) to point at the uploaded bytes.
struct BlobRef: Codable {
  let type = "blob"
  let ref: BlobLink
  let mimeType: String
  let size: Int

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case ref, mimeType, size
  }
}

/// The CBOR-link identifier of an uploaded blob.
struct BlobLink: Codable {
  let link: String

  enum CodingKeys: String, CodingKey {
    case link = "$link"
  }
}

/// A `com.atproto.label.defs#selfLabels` value, applied to a record to declare labels
/// about itself (here, the profile's `bot` automation label).
struct SelfLabels: Encodable {
  let type = "com.atproto.label.defs#selfLabels"
  let values: [SelfLabel]

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case values
  }
}

/// A single self-applied label value.
struct SelfLabel: Encodable {
  let val: String
}

// MARK: - app.bsky.feed.getPosts (public AppView, unauthenticated)

/// The response to a `app.bsky.feed.getPosts` call.
struct GetPostsResponse: Decodable {
  let posts: [PostView]

  /// A single post as returned by the public AppView.
  struct PostView: Decodable {
    let uri: String
    let cid: String
    let author: Author
    let record: PostRecord

    /// The identity of a post's author.
    struct Author: Decodable {
      let did: String
      let handle: String
    }
  }
}

/// Conversational context assembled for the fairness judge.
struct PostContext {
  /// The text of the root post of the thread, if it could be fetched.
  let rootText: String?
  /// The text of the message the new reply answers, if it could be fetched.
  let parentText: String?
  /// The handle of whoever authored the message the new reply answers.
  let parentAuthorHandle: String?
  /// The handle of whoever posted the new reply.
  let replyAuthorHandle: String?
}

// MARK: - com.atproto.identity.resolveHandle

/// The response to a `com.atproto.identity.resolveHandle` call.
struct ResolveHandleResponse: Decodable {
  let did: String
}

// MARK: - XRPC error envelope

/// The standard XRPC error response body, returned by a non-2xx status.
struct XRPCError: Decodable, Error {
  let error: String?
  let message: String?
}
