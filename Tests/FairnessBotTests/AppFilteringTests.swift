import Testing

@testable import fairness_bot

@Suite("Jetstream event filtering")
struct AppFilteringTests {
  let targetDID = "did:web:id.maclong.dev"

  private func makeEvent(
    authorDID: String,
    kind: String = "commit",
    operation: String = "create",
    collection: String = "app.bsky.feed.post",
    rkey: String = "abc123",
    cid: String? = "bafyreicid",
    text: String? = "some reply text",
    parentURI: String? = "at://did:web:id.maclong.dev/app.bsky.feed.post/root1",
    rootURI: String? = "at://did:web:id.maclong.dev/app.bsky.feed.post/root1",
  ) -> JetstreamEvent {
    let reply: PostRecord.ReplyRef? = {
      guard let parentURI, let rootURI else { return nil }
      return PostRecord.ReplyRef(
        root: StrongRef(uri: rootURI, cid: "rootcid"),
        parent: StrongRef(uri: parentURI, cid: "parentcid"),
      )
    }()
    let record = PostRecord(text: text, createdAt: "2026-01-01T00:00:00Z", reply: reply)
    let commit = JetstreamEvent.Commit(
      rev: "rev1", operation: operation, collection: collection, rkey: rkey, cid: cid,
      record: record,
    )
    return JetstreamEvent(did: authorDID, timeUs: 1000, kind: kind, commit: commit)
  }

  @Test
  func `A direct reply to the target account qualifies`() throws {
    let event = makeEvent(authorDID: "did:plc:someReplier")
    let qualifying = try #require(FairnessBotApp.qualifyingReply(in: event, targetDID: targetDID))

    #expect(qualifying.uri == "at://did:plc:someReplier/app.bsky.feed.post/abc123")
    #expect(qualifying.cid == "bafyreicid")
    #expect(qualifying.authorDID == "did:plc:someReplier")
    #expect(qualifying.text == "some reply text")
  }

  @Test
  func `A reply to someone other than the target is ignored`() {
    let event = makeEvent(
      authorDID: "did:plc:someReplier",
      parentURI: "at://did:plc:someoneElse/app.bsky.feed.post/root1",
      rootURI: "at://did:plc:someoneElse/app.bsky.feed.post/root1",
    )
    #expect(FairnessBotApp.qualifyingReply(in: event, targetDID: targetDID) == nil)
  }

  @Test
  func `A reply to someone else beneath a target post is ignored`() {
    let event = makeEvent(
      authorDID: "did:plc:secondReplier",
      parentURI: "at://did:plc:firstReplier/app.bsky.feed.post/reply1",
      rootURI: "at://did:web:id.maclong.dev/app.bsky.feed.post/root1",
    )
    #expect(FairnessBotApp.qualifyingReply(in: event, targetDID: targetDID) == nil)
  }

  @Test
  func `The target account replying to itself is ignored`() {
    let event = makeEvent(authorDID: targetDID)
    #expect(FairnessBotApp.qualifyingReply(in: event, targetDID: targetDID) == nil)
  }

  @Test(
    arguments: [
      "wrong-kind", "wrong-operation", "wrong-collection", "missing-cid", "missing-record",
      "missing-reply", "missing-text",
    ],
  )
  func `Non-qualifying event shapes are all ignored`(reason: String) {
    let event: JetstreamEvent
    switch reason {
    case "wrong-kind":
      event = makeEvent(authorDID: "did:plc:someReplier", kind: "identity")
    case "wrong-operation":
      event = makeEvent(authorDID: "did:plc:someReplier", operation: "update")
    case "wrong-collection":
      event = makeEvent(authorDID: "did:plc:someReplier", collection: "app.bsky.feed.like")
    case "missing-cid":
      event = makeEvent(authorDID: "did:plc:someReplier", cid: nil)
    case "missing-reply":
      event = makeEvent(authorDID: "did:plc:someReplier", parentURI: nil, rootURI: nil)
    case "missing-text":
      event = makeEvent(authorDID: "did:plc:someReplier", text: nil)
    case "missing-record":
      event = JetstreamEvent(
        did: "did:plc:someReplier", timeUs: 1000, kind: "commit",
        commit: .init(
          rev: "rev1", operation: "create", collection: "app.bsky.feed.post", rkey: "x", cid: "c",
          record: nil),
      )
    default:
      Issue.record("Unhandled test case: \(reason)")
      return
    }
    #expect(FairnessBotApp.qualifyingReply(in: event, targetDID: targetDID) == nil)
  }

  @Test
  func `Post text under the limit is returned unchanged`() {
    let text = "Short reply, well under budget."
    #expect(FairnessBotApp.boundedPostText(text) == text)
  }

  @Test
  func `Post text over the limit truncates at the last sentence boundary`() {
    let sentence = "This is a fairly long sentence made of enough words to matter. "
    let text = String(repeating: sentence, count: 5)
    let result = FairnessBotApp.boundedPostText(text)

    #expect(result.count <= 300)
    #expect(result.hasSuffix("."))
    #expect(result != String(text.prefix(300)))
  }

  @Test
  func `Post text with no sentence punctuation truncates at the last word boundary`() {
    let word = "supercalifragilisticexpialidocious "
    let text = String(repeating: word, count: 10)
    let result = FairnessBotApp.boundedPostText(text)

    #expect(result.count <= 300)
    #expect(!result.hasSuffix(" "))
    #expect(text.hasPrefix(result))
    #expect(result != String(text.prefix(300)))
  }

  @Test
  func `Post text with no usable boundary falls back to a hard 300 cut`() {
    let text = String(repeating: "🦋", count: 301)
    #expect(FairnessBotApp.boundedPostText(text).count == 300)
  }

  @Test(
    arguments: [
      ("at://did:plc:abc123/app.bsky.feed.post/xyz", "did:plc:abc123"),
      ("at://did:web:id.maclong.dev/app.bsky.feed.post/xyz", "did:web:id.maclong.dev"),
    ],
  )
  func `authorDID extracts the DID from an AT-URI`(uri: String, expectedDID: String) {
    #expect(FairnessBotApp.authorDID(fromURI: uri) == expectedDID)
  }

  @Test(
    arguments: ["", "not-a-uri", "https://example.com", "at:/missing-slash"],
  )
  func `authorDID returns nil for malformed URIs`(uri: String) {
    #expect(FairnessBotApp.authorDID(fromURI: uri) == nil)
  }
}
