import ArgumentParser
import Foundation

@main
struct FairnessBotCLI: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "fairness-bot",
    abstract: "Watch Bluesky replies and flag unfair engagement.",
    subcommands: [Watch.self, Check.self, SetupProfile.self],
    defaultSubcommand: Watch.self,
  )

  struct Watch: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Watch Jetstream continuously and reply only to unfair replies.",
    )

    func run() async throws {
      try await FairnessBotApp.run()
    }
  }

  struct SetupProfile: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      commandName: "setup-profile",
      abstract: "Apply the configured profile and Bluesky automation label.",
    )

    func run() async throws {
      let config = try Config()
      let atproto = ATProtoClient(config: config)
      try await atproto.configureProfile()
      print("Bot profile updated for @\(config.botHandle).")
    }
  }

  struct Check: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
      abstract: "Evaluate one reply, dry-run by default.",
    )

    @Flag(name: .customLong("post"), help: "Post the suggested reply when the verdict is unfair.")
    var postReply = false

    @Argument(help: "An AT-URI or https://bsky.app/profile/<handle-or-did>/post/<rkey> URL.")
    var post: String

    func run() async throws {
      try await FairnessBotApp.check(post, postIfUnfair: postReply)
    }
  }
}
