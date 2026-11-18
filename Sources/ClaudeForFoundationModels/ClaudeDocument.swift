// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

// Data attachments, and the types that name them, are only in Apple's framework.
#if canImport(UniformTypeIdentifiers)
import ClaudeAPI
import Foundation
import FoundationModels
import UniformTypeIdentifiers

/// A file for a Claude `document` content block.
///
/// Only PDFs are taken, sent as base64 just as they're given, so that the same attachment
/// is always the same bytes, which the prompt cache depends on. The API reads each page's
/// text and an image of it.
struct ClaudeDocument: Sendable, Hashable {
  let data: Data

  /// The types ``ClaudeLanguageModel`` accepts as data attachments.
  static let supportedTypes: [UTType] = [.pdf]

  static func supports(_ type: UTType) -> Bool {
    supportedTypes.contains { type.conforms(to: $0) }
  }

  enum Error: LocalizedError, Sendable {
    /// The attachment isn't a type the API reads as a document.
    case unsupportedType(String)

    var errorDescription: String? {
      switch self {
      case .unsupportedType(let type):
        "Attachments of type \(type) can't be sent. Claude takes PDFs."
      }
    }
  }

  @available(iOS 27.2, macOS 27.2, visionOS 27.2, watchOS 27.2, *)
  init(_ attachment: Transcript.DataAttachment) throws {
    guard Self.supports(attachment.contentType) else {
      throw Error.unsupportedType(
        attachment.contentType.preferredMIMEType ?? attachment.contentType.identifier
      )
    }
    data = attachment.content
  }

  var contentBlock: ContentBlock {
    .document(ImageSource(mediaType: "application/pdf", data: data))
  }
}
#endif
