import Testing

@testable import fairness_bot

@Suite("Fairness verdict parsing")
struct FairnessJudgeTests {
  @Test
  func `Plain JSON content parses directly`() throws {
    let content = #"{"fair": true, "reasoning": "Engaged with the evidence.", "reply": null}"#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.fair == true)
    #expect(verdict.reasoning == "Engaged with the evidence.")
    #expect(verdict.reply == nil)
  }

  @Test
  func `An unfair verdict carries a non-null reply`() throws {
    let content =
      #"{"fair": false, "reasoning": "Ad hominem, no counter-argument.", "reply": "This response focused on..."}"#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.fair == false)
    #expect(verdict.reply == "This response focused on...")
  }

  @Test
  func `JSON wrapped in a markdown code fence still parses`() throws {
    let content = """
      Here's my verdict:
      ```json
      {"fair": false, "reasoning": "Strawmans the original point.", "reply": "A quick note..."}
      ```
      """
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.fair == false)
    #expect(verdict.reasoning == "Strawmans the original point.")
  }

  @Test
  func `JSON preceded and followed by stray prose still parses`() throws {
    let content = #"Sure! {"fair": true, "reasoning": "Fine.", "reply": null} Hope that helps."#
    let verdict = try FairnessJudge.parseVerdict(from: content)

    #expect(verdict.fair == true)
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
    arguments: ["", "not json at all", "{\"fair\": \"not-a-bool\"}", "{"],
  )
  func `Unparsable content throws`(content: String) {
    #expect(throws: FairnessJudgeError.self) {
      try FairnessJudge.parseVerdict(from: content)
    }
  }
}
