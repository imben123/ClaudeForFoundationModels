// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

import Foundation
import FoundationModels
import Network
import Synchronization
import Testing

// The session in this file is built through the shipped surface only — public
// package API, real URLSession over loopback HTTP — so the wire request and
// transcript assembly are observed end-to-end. (`@testable` is imported solely
// for the shared SSE fixture helpers.)
@testable import ClaudeForFoundationModels

@Suite struct WireLevelSessionTests {

  @Test func `sonnet5 session requests summarized thinking and surfaces reasoning text`()
    async throws
  {
    let server = try await SSEStubServer(
      body: thinkingTurnSSE(thinkingDeltas: ["Let me think. ", "Okay."])
    )
    defer { server.stop() }

    let model = ClaudeLanguageModel(
      name: .sonnet5,
      auth: .apiKey("sk-test"),
      baseURL: URL(string: "http://127.0.0.1:\(server.port)")!
    )
    let session = LanguageModelSession(model: model)

    var latest = ""
    for try await snapshot in session.streamResponse(to: "hi") {
      latest = snapshot.content
    }
    #expect(latest == "Hello!")

    // The wire request must ask for summarized thinking — without it the API
    // omits thinking text and reasoning entries have no segments (issue #7).
    let body = try #require(server.capturedBody)
    let json = try #require(
      try JSONSerialization.jsonObject(with: body) as? [String: Any]
    )
    let thinking = try #require(json["thinking"] as? [String: Any])
    #expect(thinking["type"] as? String == "adaptive")
    #expect(thinking["display"] as? String == "summarized")

    #expect(reasoningText(in: session.transcript) == "Let me think. Okay.")
  }

  // The framework checks `supportsDataAttachmentType` before it sends a data
  // attachment, and refuses the prompt if the model says no.
  @available(iOS 27.2, macOS 27.2, visionOS 27.2, watchOS 27.2, *)
  @Test func `a session sends a PDF attachment as a document block`() async throws {
    let server = try await SSEStubServer(
      body: thinkingTurnSSE(thinkingDeltas: ["Reading."])
    )
    defer { server.stop() }

    let model = ClaudeLanguageModel(
      name: .sonnet5,
      auth: .apiKey("sk-test"),
      baseURL: URL(string: "http://127.0.0.1:\(server.port)")!
    )
    let pdf = Data("%PDF-1.7 test".utf8)
    let prompt = Transcript.Prompt(segments: [
      .attachment(.init(content: .data(.init(contentType: .pdf, content: pdf)))),
      .text(.init(content: "Summarize this.")),
    ])
    let session = LanguageModelSession(model: model, transcript: Transcript(entries: [.prompt(prompt)]))
    for try await _ in session.streamResponse(to: "Go on.") {}

    let body = try #require(server.capturedBody)
    let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
    let messages = try #require(json["messages"] as? [[String: Any]])
    let content = try #require(messages.first?["content"] as? [[String: Any]])
    #expect(content.first?["type"] as? String == "document")
    let source = try #require(content.first?["source"] as? [String: Any])
    #expect(source["media_type"] as? String == "application/pdf")
    #expect(source["data"] as? String == pdf.base64EncodedString())
  }
}

/// Loopback HTTP server: answers each complete POST with a canned SSE stream
/// and records the first non-empty request body. Connections that close
/// without delivering a body (probes, retries) are ignored rather than
/// allowed to poison the capture.
private final class SSEStubServer: Sendable {
  private final class State: Sendable {
    let captured = Mutex<Data?>(nil)
    let connections = Mutex<[NWConnection]>([])
  }

  private let listener: NWListener
  private let state: State
  let port: UInt16

  /// The recorded request body. Reliable once the response has been consumed —
  /// the server only responds after the full request arrives.
  var capturedBody: Data? { state.captured.withLock { $0 } }

  init(body responseBody: Data) async throws {
    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
    let listener = try NWListener(using: parameters)
    let state = State()

    listener.newConnectionHandler = { connection in
      state.connections.withLock { $0.append(connection) }
      connection.start(queue: .global())
      Self.drainRequest(connection, accumulated: Data()) { requestBody in
        guard !requestBody.isEmpty else {
          connection.cancel()
          return
        }
        state.captured.withLock { $0 = $0 ?? requestBody }
        var response = Data(
          """
          HTTP/1.1 200 OK\r
          Content-Type: text/event-stream\r
          Content-Length: \(responseBody.count)\r
          Connection: close\r
          \r\n
          """
          .utf8
        )
        response.append(responseBody)
        connection.send(
          content: response,
          completion: .contentProcessed { _ in connection.cancel() }
        )
      }
    }

    // `.waiting` is transient (the listener can still reach `.ready`), so only
    // terminal states resume — and each state change may race another on the
    // concurrent queue, so the continuation is taken exactly once.
    let port: UInt16 = try await withCheckedThrowingContinuation { continuation in
      let pending = Mutex<CheckedContinuation<UInt16, Error>?>(continuation)
      listener.stateUpdateHandler = { state in
        let result: Result<UInt16, Error>
        switch state {
        case .ready:
          if let port = listener.port?.rawValue, port != 0 {
            result = .success(port)
          } else {
            result = .failure(NWError.posix(.EADDRNOTAVAIL))
          }
        case .failed(let error):
          result = .failure(error)
        case .cancelled:
          result = .failure(CancellationError())
        case .setup, .waiting:
          return
        @unknown default:
          return
        }
        guard
          let continuation = pending.withLock({ taken in
            defer { taken = nil }
            return taken
          })
        else { return }
        continuation.resume(with: result)
      }
      listener.start(queue: .global())
    }

    self.listener = listener
    self.state = state
    self.port = port
  }

  /// Reads until the full request (headers + Content-Length body) arrives.
  /// Completes with empty data for connections that close early or carry no
  /// parseable body.
  private static func drainRequest(
    _ connection: NWConnection,
    accumulated: Data,
    completion: @escaping @Sendable (Data) -> Void
  ) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
      data,
      _,
      isComplete,
      error in
      var buffer = accumulated
      if let data { buffer.append(data) }
      // A cancelled or reset connection errors without isComplete; re-arming
      // receive on it would error again immediately, forever.
      guard error == nil else {
        completion(Data())
        return
      }

      if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
        let headers = String(decoding: buffer[..<headerEnd.lowerBound], as: UTF8.self)
        let contentLength =
          headers
          .split(separator: "\r\n")
          .first { $0.lowercased().hasPrefix("content-length:") }
          .flatMap {
            Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces))
          }
        let body = buffer[headerEnd.upperBound...]
        if let contentLength, body.count >= contentLength {
          completion(Data(body.prefix(contentLength)))
          return
        }
      }
      guard !isComplete else {
        completion(Data())
        return
      }
      drainRequest(connection, accumulated: buffer, completion: completion)
    }
  }

  func stop() {
    listener.cancel()
    state.connections.withLock { open in
      for connection in open { connection.cancel() }
      open.removeAll()
    }
  }
}
