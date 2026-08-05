import Testing

@testable import fairness_bot

@Suite("Fairness verdict parsing")
struct FairnessJudgeTests {
  @Test
  func `Plain JSON content parses directly`() throws {
    let content =
      #"{"isDebate": true, "score": 95, "reasoning": "Engaged with the evidence.", "reply": null}"#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.isDebate == true)
    #expect(verdict.score == 95)
    #expect(verdict.reasoning == "Engaged with the evidence.")
    #expect(verdict.reply == nil)
  }

  @Test
  func `An unfair verdict carries a non-null reply`() throws {
    let content =
      #"{"isDebate": true, "score": 10, "reasoning": "Ad hominem, no counter-argument.", "reply": "This response focused on..."}"#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.score == 10)
    #expect(verdict.reply == "This response focused on...")
  }

  @Test
  func `JSON wrapped in a markdown code fence still parses`() throws {
    let content = """
      Here's my verdict:
      ```json
      {"isDebate": true, "score": 20, "reasoning": "Strawmans the original point.", "reply": "A quick note..."}
      ```
      """
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.score == 20)
    #expect(verdict.reasoning == "Strawmans the original point.")
  }

  @Test
  func `JSON preceded and followed by stray prose still parses`() throws {
    let content =
      #"Sure! {"isDebate": true, "score": 100, "reasoning": "Fine.", "reply": null} Hope that helps."#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.score == 100)
  }

  @Test
  func `General conversation is never fair-scored regardless of threshold`() throws {
    let content =
      #"{"isDebate": false, "score": null, "reasoning": "Friendly agreement, not a critical response.", "reply": null}"#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.isDebate == false)
    #expect(verdict.score == nil)
    #expect(verdict.isFair(threshold: 0) == true)
    #expect(verdict.isFair(threshold: 100) == true)
  }

  @Test(arguments: [(100, true), (60, true), (59, false), (0, false)])
  func `isFair compares the score against the threshold for debate replies`(
    score: Int, expectedFair: Bool,
  ) throws {
    let content = #"{"isDebate": true, "score": \#(score), "reasoning": "n/a", "reply": null}"#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.isFair(threshold: 60) == expectedFair)
  }

  @Test
  func `Approved review supplies the final reply`() throws {
    let content =
      #"{"approved": true, "reasoning": "Softened the claim.", "reply": "Please address the point directly."}"#
    let review = try FairnessJudge.parseReview(from: content)

    #expect(review.approved == true)
    #expect(review.reply == "Please address the point directly.")
  }

  @Test(
    arguments: ["", "not json at all", "{\"score\": \"not-a-number\"}", "{"],
  )
  func `Unparsable content throws`(content: String) {
    #expect(throws: FairnessJudgeError.self) {
      try FairnessJudge.parseVerdict(from: content)
    }
  }
}
