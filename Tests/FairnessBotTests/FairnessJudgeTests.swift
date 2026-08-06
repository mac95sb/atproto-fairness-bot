import Testing

@testable import FairnessBot

@Suite("Fairness verdict parsing")
struct FairnessJudgeTests {
  @Test
  func `Plain JSON content parses directly`() throws {
    let content =
      #"{"isDebate": true, "rhetoric": 95, "relevance": 95, "evidence": 95, "reasoning": "Engaged with the evidence.", "reply": null}"#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.isDebate == true)
    #expect(verdict.score == 95)
    #expect(verdict.reasoning == "Engaged with the evidence.")
    #expect(verdict.reply == nil)
  }

  @Test
  func `An unfair verdict carries a non-null reply`() throws {
    let content =
      #"{"isDebate": true, "rhetoric": 10, "relevance": 10, "evidence": 10, "reasoning": "Ad hominem, no counter-argument.", "reply": "This response focused on..."}"#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.score == 10)
    #expect(verdict.reply == "This response focused on...")
  }

  @Test
  func `The gate score is the weakest of the three axes, not their average`() throws {
    let content =
      #"{"isDebate": true, "rhetoric": 20, "relevance": 95, "evidence": 90, "reasoning": "Mostly substantive but one nasty aside.", "reply": "A quick note..."}"#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.rhetoric == 20)
    #expect(verdict.relevance == 95)
    #expect(verdict.evidence == 90)
    #expect(verdict.score == 20)
    #expect(verdict.isFair(threshold: 60) == false)
  }

  @Test
  func `JSON wrapped in a markdown code fence still parses`() throws {
    let content = """
      Here's my verdict:
      ```json
      {"isDebate": true, "rhetoric": 20, "relevance": 20, "evidence": 20, "reasoning": "Strawmans the original point.", "reply": "A quick note..."}
      ```
      """
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.score == 20)
    #expect(verdict.reasoning == "Strawmans the original point.")
  }

  @Test
  func `JSON preceded and followed by stray prose still parses`() throws {
    let content =
      #"Sure! {"isDebate": true, "rhetoric": 100, "relevance": 100, "evidence": 100, "reasoning": "Fine.", "reply": null} Hope that helps."#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.score == 100)
  }

  @Test
  func `General conversation is never fair-scored regardless of threshold`() throws {
    let content =
      #"{"isDebate": false, "rhetoric": null, "relevance": null, "evidence": null, "reasoning": "Friendly agreement, not a critical response.", "reply": null}"#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.isDebate == false)
    #expect(verdict.score == nil)
    #expect(verdict.isFair(threshold: 0) == true)
    #expect(verdict.isFair(threshold: 100) == true)
  }

  @Test(arguments: [(100, true), (60, true), (59, false), (0, false)])
  func `isFair compares the gate score against the threshold for debate replies`(
    score: Int, expectedFair: Bool,
  ) throws {
    let content =
      #"{"isDebate": true, "rhetoric": \#(score), "relevance": \#(score), "evidence": \#(score), "reasoning": "n/a", "reply": null}"#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.isFair(threshold: 60) == expectedFair)
  }

  @Test
  func `Approved review supplies the final reply`() throws {
    let content =
      #"{"verdictSupported": true, "approved": true, "reasoning": "Softened the claim.", "reply": "Please address the point directly."}"#
    let review = try FairnessJudge.parseReview(from: content)

    #expect(review.isVerdictSupported == true)
    #expect(review.isApproved == true)
    #expect(review.reply == "Please address the point directly.")
  }

  @Test
  func `A reviewer that disagrees with the finding sets verdictSupported false`() throws {
    let content =
      #"{"verdictSupported": false, "approved": false, "reasoning": "This actually engaged fairly.", "reply": null}"#
    let review = try FairnessJudge.parseReview(from: content)

    #expect(review.isVerdictSupported == false)
    #expect(review.isApproved == false)
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

@Suite("Review outcome resolution")
struct ReviewOutcomeTests {
  @Test
  func `A supported, approved review with text resolves to approved`() {
    let review = ReviewVerdict(
      isVerdictSupported: true, isApproved: true, reasoning: "Fine.", reply: "Please reconsider.")

    #expect(FairnessJudge.reviewOutcome(from: review) == .approved(reply: "Please reconsider."))
  }

  @Test
  func `An unsupported review overturns the verdict regardless of approved`() {
    let review = ReviewVerdict(
      isVerdictSupported: false, isApproved: true, reasoning: "Actually engaged fairly.",
      reply: "Please reconsider.")

    #expect(
      FairnessJudge.reviewOutcome(from: review)
        == .verdictOverturned(reasoning: "Actually engaged fairly."))
  }

  @Test
  func `A supported but unapproved review rejects the reply`() {
    let review = ReviewVerdict(
      isVerdictSupported: true, isApproved: false, reasoning: "Too harsh.", reply: nil)

    #expect(FairnessJudge.reviewOutcome(from: review) == .replyRejected(reasoning: "Too harsh."))
  }

  @Test
  func `Approved true with an empty reply still rejects`() {
    let review = ReviewVerdict(
      isVerdictSupported: true, isApproved: true, reasoning: "Nothing usable.", reply: "")

    #expect(
      FairnessJudge.reviewOutcome(from: review) == .replyRejected(reasoning: "Nothing usable."))
  }
}
