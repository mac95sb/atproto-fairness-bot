import Foundation
import Testing

@testable import fairness_bot

@Suite("Bot profile")
struct ProfileRecordTests {
  @Test
  func `Profile record declares the account as a bot`() throws {
    let record = ProfileRecord(displayName: "Fairness Bot 🤖", description: "An automated account.")
    let data = try JSONEncoder().encode(record)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let labels = try #require(object["labels"] as? [String: Any])
    let values = try #require(labels["values"] as? [[String: String]])

    #expect(labels["$type"] as? String == "com.atproto.label.defs#selfLabels")
    #expect(values == [["val": "bot"]])
  }
}
