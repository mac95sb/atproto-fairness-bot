import Foundation
import Testing

@testable import FairnessBot

@Suite("Verdict record")
struct VerdictRecordTests {
  @Test
  func `Verdict record encodes its lexicon type and fields`() throws {
    let record = VerdictRecord(
      subject: StrongRef(uri: "at://did:plc:offender/app.bsky.feed.post/abc", cid: "cid-subject"),
      reply: StrongRef(uri: "at://did:plc:bot/app.bsky.feed.post/xyz", cid: "cid-reply"),
      score: 15,
      rhetoric: 15,
      relevance: 40,
      evidence: 30,
      reasoning: "Relied on insults instead of argument.",
      replyText: "That reply didn't engage with the point raised.",
      isSelfAssessment: false,
      createdAt: "2026-08-04T00:00:00Z",
    )
    let data = try JSONEncoder().encode(record)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["$type"] as? String == "dev.maclong.feed.verdict")
    #expect(object["score"] as? Int == 15)
    #expect(object["rhetoric"] as? Int == 15)
    #expect(object["relevance"] as? Int == 40)
    #expect(object["evidence"] as? Int == 30)
    #expect(object["reasoning"] as? String == "Relied on insults instead of argument.")
    #expect(object["selfAssessment"] as? Bool == false)

    let subject = try #require(object["subject"] as? [String: String])
    #expect(subject["uri"] == "at://did:plc:offender/app.bsky.feed.post/abc")
    #expect(subject["cid"] == "cid-subject")
  }

  @Test
  func `A self-assessment verdict omits reply and replyText and marks selfAssessment true`() throws
  {
    let record = VerdictRecord(
      subject: StrongRef(uri: "at://did:web:id.maclong.dev/app.bsky.feed.post/abc", cid: "cid-1"),
      reply: nil,
      score: 20,
      rhetoric: 20,
      relevance: 90,
      evidence: 85,
      reasoning: "The target's own reply relied on mockery.",
      replyText: nil,
      isSelfAssessment: true,
      createdAt: "2026-08-04T00:00:00Z",
    )
    let data = try JSONEncoder().encode(record)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(object["reply"] == nil)
    #expect(object["replyText"] == nil)
    #expect(object["selfAssessment"] as? Bool == true)
  }
}
