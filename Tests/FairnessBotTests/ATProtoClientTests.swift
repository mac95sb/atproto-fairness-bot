import Foundation
import Testing

@testable import FairnessBot

@Suite("ATProto response handling")
struct ATProtoClientTests {
  @Test
  func `A 400 ExpiredToken response requests a session refresh`() throws {
    let response = try #require(
      HTTPURLResponse(
        url: URL(string: "https://pds.example/xrpc/test")!, statusCode: 400,
        httpVersion: nil, headerFields: nil))
    let data = Data(#"{"error":"ExpiredToken","message":"Token has expired"}"#.utf8)

    do {
      try ATProtoClient.checkStatus(response, data: data)
      Issue.record("Expected an unauthorized error")
    } catch ATProtoError.unauthorized {
      // Expected: sendWithRefresh will refresh the session and retry the request.
    }
  }

  @Test
  func `An ordinary 400 response remains a request failure`() throws {
    let response = try #require(
      HTTPURLResponse(
        url: URL(string: "https://pds.example/xrpc/test")!, statusCode: 400,
        httpVersion: nil, headerFields: nil))
    let data = Data(#"{"error":"InvalidRequest","message":"Bad input"}"#.utf8)

    do {
      try ATProtoClient.checkStatus(response, data: data)
      Issue.record("Expected a request failure")
    } catch ATProtoError.requestFailed(let status, let message) {
      #expect(status == 400)
      #expect(message == "Bad input")
    }
  }
}
