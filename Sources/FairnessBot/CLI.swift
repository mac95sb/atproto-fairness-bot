import ArgumentParser
import Foundation

struct FairnessBotCLI: ParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "fairness-bot",
    abstract: "Watch Bluesky replies and flag unfair engagement.",
    subcommands: [Watch.self, Check.self],
    defaultSubcommand: Watch.self,
  )

  struct Watch: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Watch Jetstream continuously and reply only to unfair replies.",
    )

    func run() throws {
      try runBlocking {
        try await FairnessBotApp.run()
      }
    }
  }

  struct Check: ParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Evaluate one reply, dry-run by default.",
    )

    @Flag(name: .customLong("post"), help: "Post the suggested reply when the verdict is unfair.")
    var postReply = false

    @Argument(help: "An AT-URI or https://bsky.app/profile/<handle-or-did>/post/<rkey> URL.")
    var post: String

    func run() throws {
      let post = post
      let postReply = postReply
      try runBlocking {
        try await FairnessBotApp.check(post, postIfUnfair: postReply)
      }
    }
  }
}

private final class BlockingResult<Value>: @unchecked Sendable {
  var result: Result<Value, Error>?
}

private func runBlocking<Value: Sendable>(
  _ operation: @escaping @Sendable () async throws -> Value,
) throws -> Value {
  let semaphore = DispatchSemaphore(value: 0)
  let result = BlockingResult<Value>()

  Task.detached {
    defer { semaphore.signal() }
    do {
      result.result = .success(try await operation())
    } catch {
      result.result = .failure(error)
    }
  }

  semaphore.wait()
  return try result.result!.get()
}
