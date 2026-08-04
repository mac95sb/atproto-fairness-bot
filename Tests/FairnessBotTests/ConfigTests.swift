import Testing

@testable import fairness_bot

@Suite("Config loading")
struct ConfigTests {
  private func baseValidEnv() -> [String: String] {
    [
      "LLM_BASE_URL": "https://llm.example.com/v1",
      "LLM_API_KEY": "test-llm-key",
      "LLM_MODEL": "test-model",
      "BOT_PDS_URL": "https://id.example.com",
      "BOT_HANDLE": "fairness.example.com",
      "BOT_APP_PASSWORD": "test-password",
    ]
  }

  @Test
  func `Loads successfully with only the required variables, applying defaults`() throws {
    let config = try Config(environment: baseValidEnv())

    #expect(config.llmBaseURL.absoluteString == "https://llm.example.com/v1")
    #expect(config.llmModel == "test-model")
    #expect(config.targetHandle == "maclong.dev")
    #expect(config.targetDID == "did:web:id.maclong.dev")
    #expect(config.botDisplayName == "Fairness Bot")
    #expect(config.jetstreamURL.absoluteString == "wss://jetstream2.us-east.bsky.network/subscribe")
  }

  @Test
  func `Explicit values override the defaults`() throws {
    var env = baseValidEnv()
    env["TARGET_HANDLE"] = "someoneelse.dev"
    env["TARGET_DID"] = "did:plc:someoneelse"
    env["LLM_BASE_URL"] = "https://api.openai.com/v1"
    env["LLM_MODEL"] = "some/other-model"
    env["BOT_DISPLAY_NAME"] = "Custom Bot"

    let config = try Config(environment: env)

    #expect(config.targetHandle == "someoneelse.dev")
    #expect(config.targetDID == "did:plc:someoneelse")
    #expect(config.llmBaseURL.absoluteString == "https://api.openai.com/v1")
    #expect(config.llmModel == "some/other-model")
    #expect(config.botDisplayName == "Custom Bot")
  }

  @Test(
    arguments: [
      "LLM_BASE_URL", "LLM_API_KEY", "LLM_MODEL", "BOT_PDS_URL", "BOT_HANDLE", "BOT_APP_PASSWORD",
    ],
  )
  func `Missing a required variable throws`(key: String) {
    var env = baseValidEnv()
    env.removeValue(forKey: key)

    #expect(throws: Config.ConfigError.self) {
      try Config(environment: env)
    }
  }

  @Test
  func `Missing multiple required variables reports all of them by name`() {
    do {
      _ = try Config(environment: [:])
      Issue.record("Expected Config init to throw")
    } catch let Config.ConfigError.missing(keys) {
      #expect(
        Set(keys)
          == Set([
            "LLM_BASE_URL", "LLM_API_KEY", "LLM_MODEL", "BOT_PDS_URL", "BOT_HANDLE",
            "BOT_APP_PASSWORD",
          ]))
    } catch {
      Issue.record("Wrong error thrown: \(error)")
    }
  }

  @Test
  func `Redacted description never includes the app password or API key`() throws {
    var env = baseValidEnv()
    env["LLM_API_KEY"] = "super-secret-llm-key"
    env["BOT_APP_PASSWORD"] = "super-secret-app-password"

    let config = try Config(environment: env)
    let description = config.description

    #expect(description.contains("super-secret-llm-key") == false)
    #expect(description.contains("super-secret-app-password") == false)
  }
}
