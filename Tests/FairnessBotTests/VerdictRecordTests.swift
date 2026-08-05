import Foundation
import Testing

@testable import fairness_bot

@Suite("Verdict record")
struct VerdictRecordTests {
  @Test
  func `Verdict record encodes its lexicon type and fields`() throws {
    let record = VerdictRecord(
      subject: StrongRef(uri: "at://did:plc:offender/app.bsky.feed.post/abc", cid: "cid-subject"),
      reply: StrongRef(uri: "at://did:plc:bot/app.bsky.feed.post/xyz", cid: "cid-reply"),
      score: 15,
      reasoning: "Relied on insults instead of argument.",
      replyText: "That reply didn't engage with the point raised.",
      createdAt: "2026-08-04T00:00:00Z",
    )
    let data = try JSONEncoder().encode(record)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["$type"] as? String == "dev.maclong.feed.verdict")
    #expect(object["score"] as? Int == 15)
    #expect(object["reasoning"] as? String == "Relied on insults instead of argument.")

    let subject = try #require(object["subject"] as? [String: String])
    #expect(subject["uri"] == "at://did:plc:offender/app.bsky.feed.post/abc")
    #expect(subject["cid"] == "cid-subject")
  }
}
