import Foundation

/// A single event frame from a Jetstream subscription.
/// https://github.com/bluesky-social/jetstream
struct JetstreamEvent: Decodable {
  /// The DID of the repo the event belongs to.
  let did: String
  /// The event's microsecond-resolution timestamp, used as the resumable cursor.
  let timeUs: Int64
  /// The event type, e.g. `"commit"`.
  let kind: String
  /// The repo operation, present for `"commit"` events.
  let commit: Commit?

  enum CodingKeys: String, CodingKey {
    case did
    case timeUs = "time_us"
    case kind
    case commit
  }

  /// A single repo operation within a commit event.
  struct Commit: Decodable {
    let rev: String
    /// The operation type, e.g. `"create"`.
    let operation: String
    /// The collection NSID the record belongs to, e.g. `"app.bsky.feed.post"`.
    let collection: String
    /// The record key.
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
