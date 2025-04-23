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
        let lines = text.components(separatedBy: "\n")
        guard lines.first == "---" else { return nil }
        for i in 1..<lines.count {
            if lines[i] == "---" {
                let yamlLines = lines[1..<i]
                let yaml = yamlLines.joined(separator: "\n")
                let bodyLines = lines[(i + 1)...]
                let body = bodyLines.joined(separator: "\n")
                return (yaml, body)
            }
        }
        return nil
    }
}