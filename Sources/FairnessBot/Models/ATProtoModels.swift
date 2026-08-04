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

struct CreateRecordRequest: Encodable {
  let repo: String
  let collection: String
  let record: ReplyPostRecord
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

  enum CodingKeys: String, CodingKey {
    case type = "$type"
    case displayName, description
  }
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
