import Foundation
import Yams

/// Represents a parsed Obsidian note with front-matter metadata and body content.
public struct Document {
    /// The front-matter metadata as a dictionary.
    public let metadata: [String: Any]
    /// The markdown body content (excluding front-matter).
    public let body: String
}

/// Errors thrown by ObsidianModel parsing.
public enum ObsidianModelError: Error {
    /// The front-matter block could not be decoded into a dictionary.
    case invalidFrontMatter
}

public extension ObsidianModel {
    /// Parses the full document text, extracting front-matter (YAML) and body.
    /// - Parameter text: The complete markdown file contents.
    /// - Returns: A Document with metadata and body.
    static func parseDocument(_ text: String) throws -> Document {
        if let (yaml, body) = split(text: text) {
            let any = try Yams.load(yaml: yaml)
            guard let dict = any as? [String: Any] else {
                throw ObsidianModelError.invalidFrontMatter
            }
            return Document(metadata: dict, body: body)
        } else {
            return Document(metadata: [:], body: text)
        }
    }

    /// Splits the document into a YAML front-matter block and the remaining body.
    /// - Parameter text: The complete markdown file contents.
    /// - Returns: Tuple of YAML string and body string, or nil if no front-matter.
    static func split(text: String) -> (yaml: String, body: String)? {
        // Look for YAML front-matter delimited by '---' at the start and end
        let delimiter = "---\n"
        // Must start with opening delimiter
        guard text.hasPrefix(delimiter) else { return nil }
        // Skip past the opening delimiter
        let contentStart = text.index(text.startIndex, offsetBy: delimiter.count)
        let remainder = text[contentStart...]
        // Find the closing delimiter
        guard let closeRange = remainder.range(of: delimiter) else { return nil }
        // Extract YAML between delimiters
        let yaml = String(remainder[..<closeRange.lowerBound])
        // Extract body after closing delimiter
        let bodyStart = closeRange.upperBound
        let body = String(remainder[bodyStart...])
        return (yaml: yaml, body: body)
    }
}