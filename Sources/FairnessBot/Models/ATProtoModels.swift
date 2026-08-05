import Foundation

// MARK: - com.atproto.server.createSession / refreshSession

struct CreateSessionRequest: Encodable {
  let identifier: String
  let password: String
}

struct SessionResponse: Decodable {
  let did: String
  let handle: String
  let accessJwt: String
  let refreshJwt: String
}

// MARK: - com.atproto.repo.createRecord

struct CreateRecordRequest<Record: Encodable>: Encodable {
  let repo: String
  let collection: String
  let record: Record
}

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

struct CreateRecordResponse: Decodable {
  let uri: String
  let cid: String
}

// MARK: - dev.maclong.feed.verdict

/// A fairness-bot verdict, published to the bot's own repo alongside the
/// callout reply it triggered. See `lexicons/dev.maclong.feed.verdict.json`.
struct VerdictRecord: Encodable {
  let type = "dev.maclong.feed.verdict"
  let subject: StrongRef
  let reply: StrongRef
  let score: Int
  let reasoning: String
  let replyText: String
  let createdAt: String

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case subject, reply, score, reasoning, replyText, createdAt
  }
}

struct PutProfileRecordRequest: Encodable {
  let repo: String
  let collection = "app.bsky.actor.profile"
  let rkey = "self"
  let record: ProfileRecord
}

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

struct BlobLink: Codable {
  let link: String

  enum CodingKeys: String, CodingKey {
    case link = "$link"
  }
}

struct SelfLabels: Encodable {
  let type = "com.atproto.label.defs#selfLabels"
  let values: [SelfLabel]

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case values
  }
}

struct SelfLabel: Encodable {
  let val: String
}

// MARK: - app.bsky.feed.getPosts (public AppView, unauthenticated)

struct GetPostsResponse: Decodable {
  let posts: [PostView]

  struct PostView: Decodable {
    let uri: String
    let cid: String
    let author: Author
    let record: PostRecord

    struct Author: Decodable {
      let did: String
      let handle: String
    }
  }
}

/// Conversational context assembled for the fairness judge.
struct PostContext {
  let rootText: String?
  let parentText: String?
  let replyAuthorHandle: String?
}

// MARK: - com.atproto.identity.resolveHandle

struct ResolveHandleResponse: Decodable {
  let did: String
}

// MARK: - XRPC error envelope

struct XRPCError: Decodable, Error {
  let error: String?
  let message: String?
}
