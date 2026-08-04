import Foundation

/// A single event frame from a Jetstream subscription.
/// https://github.com/bluesky-social/jetstream
struct JetstreamEvent: Decodable {
  let did: String
  let timeUs: Int64
  let kind: String
  let commit: Commit?

  enum CodingKeys: String, CodingKey {
    case did
    case timeUs = "time_us"
    case kind
    case commit
  }

  struct Commit: Decodable {
    let rev: String
    let operation: String
    let collection: String
    let rkey: String
    let cid: String?
    let record: PostRecord?
  }
}

/// The subset of an `app.bsky.feed.post` record this bot cares about.
struct PostRecord: Decodable {
  let text: String?
  let createdAt: String?
  let reply: ReplyRef?

  /// `Codable` (not just `Decodable`) because the bot also re-sends this ref
  /// as the `reply` field when it posts its own fairness reply.
  struct ReplyRef: Codable, Equatable {
    let root: StrongRef
    let parent: StrongRef
  }
}

/// An AT Protocol strong reference: a record's URI paired with its CID.
struct StrongRef: Codable, Equatable {
  let uri: String
  let cid: String
}
