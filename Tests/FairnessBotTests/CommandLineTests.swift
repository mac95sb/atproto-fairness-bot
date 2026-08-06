import Testing

@testable import FairnessBot

@Suite("Command-line post references")
struct CommandLineTests {
  @Test
  func `An AT-URI is accepted`() throws {
    let reference = try PostReference.parse("at://did:plc:abc/app.bsky.feed.post/3kxyz")
    #expect(reference == .atURI("at://did:plc:abc/app.bsky.feed.post/3kxyz"))
  }

  @Test
  func `A Bluesky post URL is parsed`() throws {
    let reference = try PostReference.parse("https://bsky.app/profile/example.com/post/3kxyz")
    #expect(reference == .blueskyPost(actor: "example.com", rkey: "3kxyz"))
  }

  @Test(arguments: [
    "https://example.com/post/3kxyz", "https://bsky.app/profile/example.com", "not-a-uri",
  ])
  func `Invalid post references throw`(input: String) {
    #expect(throws: CommandLineError.self) {
      try PostReference.parse(input)
    }
  }

}
