import Foundation
import Testing

@testable import FairnessBot

@Suite("Bot profile")
struct ProfileRecordTests {
  @Test
  func `Profile record declares the account as a bot`() throws {
    let record = ProfileRecord(
      displayName: "Fairness Bot", description: "An automated account.", avatar: nil)
    let data = try JSONEncoder().encode(record)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let labels = try #require(object["labels"] as? [String: Any])
    let values = try #require(labels["values"] as? [[String: String]])

    #expect(labels["$type"] as? String == "com.atproto.label.defs#selfLabels")
    #expect(values == [["val": "bot"]])
  }

  @Test
  func `Avatar is omitted when nil and included as a blob ref when set`() throws {
    let withoutAvatar = ProfileRecord(displayName: "Fairness Bot", description: "", avatar: nil)
    let withoutObject = try #require(
      JSONSerialization.jsonObject(with: try JSONEncoder().encode(withoutAvatar)) as? [String: Any])
    #expect(withoutObject["avatar"] == nil)

    let avatar = BlobRef(ref: BlobLink(link: "bafy..."), mimeType: "image/png", size: 123)
    let withAvatar = ProfileRecord(displayName: "Fairness Bot", description: "", avatar: avatar)
    let withObject = try #require(
      JSONSerialization.jsonObject(with: try JSONEncoder().encode(withAvatar)) as? [String: Any])
    let avatarObject = try #require(withObject["avatar"] as? [String: Any])

    #expect(avatarObject["$type"] as? String == "blob")
    #expect(avatarObject["mimeType"] as? String == "image/png")
    #expect(avatarObject["size"] as? Int == 123)
    let ref = try #require(avatarObject["ref"] as? [String: String])
    #expect(ref["$link"] == "bafy...")
  }
}
