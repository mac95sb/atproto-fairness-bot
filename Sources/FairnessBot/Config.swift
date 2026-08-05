import Foundation

/// All bot behavior is driven by environment variables so anyone can point this
/// at their own PDS/account and LLM provider without touching source. See `.env.example`.
struct Config: CustomStringConvertible {
  let llmBaseURL: URL
  let llmAPIKey: String
  let llmModel: String
  let reviewLLM: ReviewLLM?

  let targetHandle: String
  let targetDID: String

  let botPDSURL: URL
  let botHandle: String
  let botAppPassword: String
  let botDisplayName: String
  let botProfileDescription: String
  let botAvatarPath: URL

  let jetstreamURL: URL
  let appViewURL: URL
  let stateDirectory: URL
  let fairnessScoreThreshold: Int

  struct ReviewLLM {
    let baseURL: URL
    let apiKey: String
    let model: String
  }

  enum ConfigError: Error, CustomStringConvertible {
    case missing([String])

    var description: String {
      switch self {
      case .missing(let keys):
        "Missing required environment variable(s): \(keys.joined(separator: ", "))"
      }
    }
  }

  init(environment: [String: String] = ProcessInfo.processInfo.environment) throws {
    func required(_ key: String, missing: inout [String]) -> String {
      guard let value = environment[key], !value.isEmpty else {
        missing.append(key)
        return ""
      }
      return value
    }

    func optional(_ key: String) -> String? {
      guard let value = environment[key], !value.isEmpty else { return nil }
      return value
    }

    var missing: [String] = []
    let llmBaseURLString = required("LLM_BASE_URL", missing: &missing)
    let llmAPIKey = required("LLM_API_KEY", missing: &missing)
    let llmModel = required("LLM_MODEL", missing: &missing)
    let botPDSURLString = required("BOT_PDS_URL", missing: &missing)
    let botHandle = required("BOT_HANDLE", missing: &missing)
    let botAppPassword = required("BOT_APP_PASSWORD", missing: &missing)
    guard missing.isEmpty else { throw ConfigError.missing(missing) }

    guard let botPDSURL = URL(string: botPDSURLString) else {
      throw ConfigError.missing(["BOT_PDS_URL (not a valid URL)"])
    }
    guard let llmBaseURL = URL(string: llmBaseURLString) else {
      throw ConfigError.missing(["LLM_BASE_URL (not a valid URL)"])
    }

    self.llmBaseURL = llmBaseURL
    self.llmAPIKey = llmAPIKey
    self.llmModel = llmModel

    if let reviewModel = optional("LLM_REVIEW_MODEL") {
      let reviewBaseURLString = optional("LLM_REVIEW_BASE_URL") ?? llmBaseURLString
      guard let reviewBaseURL = URL(string: reviewBaseURLString) else {
        throw ConfigError.missing(["LLM_REVIEW_BASE_URL (not a valid URL)"])
      }
      reviewLLM = ReviewLLM(
        baseURL: reviewBaseURL,
        apiKey: optional("LLM_REVIEW_API_KEY") ?? llmAPIKey,
        model: reviewModel,
      )
    } else {
      reviewLLM = nil
    }

    targetHandle = environment["TARGET_HANDLE"] ?? "maclong.dev"
    targetDID = environment["TARGET_DID"] ?? "did:web:id.maclong.dev"

    self.botPDSURL = botPDSURL
    self.botHandle = botHandle
    self.botAppPassword = botAppPassword
    botDisplayName = environment["BOT_DISPLAY_NAME"] ?? "Fairness Bot"
    botProfileDescription =
      environment["BOT_PROFILE_DESCRIPTION"]
      ?? "Automated account that encourages fair, evidence-based discussion."
    botAvatarPath = URL(
      fileURLWithPath: environment["BOT_AVATAR_PATH"] ?? "assets/logo.jpg",
    )

    jetstreamURL = URL(
      string: environment["JETSTREAM_URL"]
        ?? "wss://jetstream2.us-east.bsky.network/subscribe",
    )!
    appViewURL = URL(
      string: environment["APP_VIEW_URL"] ?? "https://public.api.bsky.app",
    )!
    stateDirectory = URL(
      fileURLWithPath: environment["STATE_DIR"] ?? "state",
      isDirectory: true,
    )

    if let thresholdString = optional("FAIRNESS_SCORE_THRESHOLD") {
      guard let threshold = Int(thresholdString) else {
        throw ConfigError.missing(["FAIRNESS_SCORE_THRESHOLD (not a valid integer)"])
      }
      fairnessScoreThreshold = threshold
    } else {
      fairnessScoreThreshold = 60
    }
  }

  /// Redacted on purpose: never let the app password or API key end up in logs,
  /// error messages, or an accidental `print(config)`.
  var description: String {
    """
    Config(
      targetHandle: \(targetHandle), targetDID: \(targetDID),
      botHandle: \(botHandle), botPDSURL: \(botPDSURL.absoluteString),
      botDisplayName: \(botDisplayName),
      botProfileDescription: \(botProfileDescription),
      llmBaseURL: \(llmBaseURL.absoluteString), llmModel: \(llmModel),
      reviewLLM: \(reviewLLM?.model ?? "<disabled>"),
      jetstreamURL: \(jetstreamURL.absoluteString), appViewURL: \(appViewURL.absoluteString),
      stateDirectory: \(stateDirectory.path), fairnessScoreThreshold: \(fairnessScoreThreshold),
      botAppPassword: <redacted>, llmAPIKey: <redacted>
    )
    """
  }
}
