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
            // Decode only the fields we care about (title, tags); ignore invalid YAML
            struct FrontMatter: Decodable {
                let title: String?
                let tags: [String]?
            }
            do {
                let fm = try YAMLDecoder().decode(FrontMatter.self, from: yaml)
                var metadata: [String: Any] = [:]
                if let t = fm.title { metadata["title"] = t }
                if let tg = fm.tags  { metadata["tags"]  = tg }
                return Document(metadata: metadata, body: body)
            } catch {
                // Fallback manual parse for basic title and tags when YAML is invalid
                var metadata: [String: Any] = [:]
                let lines = yaml.components(separatedBy: .newlines)
                // Manual parse for `title: ...`
                for rawLine in lines {
                    let line = rawLine.trimmingCharacters(in: .whitespaces)
                    if let colonIdx = line.firstIndex(of: ":") {
                        let key = String(line[..<colonIdx]).trimmingCharacters(in: .whitespaces)
                        if key == "title" {
                            let rawValue = line[line.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                            let titleValue = rawValue.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                            metadata["title"] = titleValue
                            break
                        }
                    }
                }
                // Manual parse for `tags:` (inline or block list)
                var manualTags: [String] = []
                if let idx = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("tags:") }) {
                    let tagLine = lines[idx].trimmingCharacters(in: .whitespaces)
                    let afterColon = String(tagLine.dropFirst("tags:".count)).trimmingCharacters(in: .whitespaces)
                    if afterColon.hasPrefix("[") && afterColon.hasSuffix("]") {
                        // Inline list [a, b, c]
                        let inner = afterColon.dropFirst().dropLast()
                        manualTags = inner.split(separator: ",").map {
                            String($0).trimmingCharacters(in: .whitespaces)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        }
                    } else if afterColon.isEmpty {
                        // Block list:
                        var j = idx + 1
                        while j < lines.count {
                            let next = lines[j].trimmingCharacters(in: .whitespaces)
                            guard next.hasPrefix("-") else { break }
                            let tagRaw = String(next.dropFirst()).trimmingCharacters(in: .whitespaces)
                            let tagVal = tagRaw.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                            manualTags.append(tagVal)
                            j += 1
                        }
                    } else {
                        // Comma-separated inline values
                        manualTags = afterColon.split(separator: ",").map {
                            String($0).trimmingCharacters(in: .whitespaces)
                                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        }
                    }
                    if !manualTags.isEmpty {
                        metadata["tags"] = manualTags
                    }
                }
                // After manual parse, return metadata (possibly empty)
                return Document(metadata: metadata, body: body)
            }
        } else {
            // No front-matter present
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