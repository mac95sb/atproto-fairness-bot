import Foundation
import Testing

@testable import FairnessBotCore

@Suite("Reply log dedupe persistence")
struct ReplyLogTests {
  let stateDirectory: URL

  init() {
    stateDirectory = FileManager.default.temporaryDirectory
      .appendingPathComponent("fairness-bot-tests-\(UUID().uuidString)")
  }

  @Test
  func `A URI that hasn't been marked is not already replied`() async {
    let log = ReplyLog(stateDirectory: stateDirectory)
    #expect(await log.hasReplied(to: "at://did:plc:x/app.bsky.feed.post/1") == false)
  }

  @Test
  func `Marking a URI makes it show as already replied`() async {
    let log = ReplyLog(stateDirectory: stateDirectory)
    let uri = "at://did:plc:x/app.bsky.feed.post/1"

    await log.markReplied(uri)

    #expect(await log.hasReplied(to: uri) == true)
  }

  @Test
  func `Other URIs remain unaffected after marking one`() async {
    let log = ReplyLog(stateDirectory: stateDirectory)
    await log.markReplied("at://did:plc:x/app.bsky.feed.post/1")

    #expect(await log.hasReplied(to: "at://did:plc:x/app.bsky.feed.post/2") == false)
  }

  @Test
  func `Marked URIs persist across a new ReplyLog instance pointed at the same directory`() async {
    let uri = "at://did:plc:x/app.bsky.feed.post/1"
    let first = ReplyLog(stateDirectory: stateDirectory)
    await first.markReplied(uri)

    let second = ReplyLog(stateDirectory: stateDirectory)
    #expect(await second.hasReplied(to: uri) == true)
  }

  @Test
  func `Marking the same URI twice is idempotent`() async {
    let log = ReplyLog(stateDirectory: stateDirectory)
    let uri = "at://did:plc:x/app.bsky.feed.post/1"

    await log.markReplied(uri)
    await log.markReplied(uri)

    #expect(await log.hasReplied(to: uri) == true)
  }
}
