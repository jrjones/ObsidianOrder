// ObsidianModel: stub package for front-matter, links, and tasks parsing
import Foundation

/// Placeholder type for the ObsidianModel module.
public enum ObsidianModel {
    /// Placeholder type for the ObsidianModel module.
}

public extension ObsidianModel {
    /// Represents an internal wiki-style link [[target|alias]] or [[target]].
    struct Link: Equatable {
        /// The linked page title.
        public let target: String
        /// Optional alias for display.
        public let alias: String?
        public init(target: String, alias: String? = nil) {
            self.target = target
            self.alias = alias
        }
    }

    /// Parses internal wiki-style links from the given text.
    /// - Parameter text: The markdown content.
    /// - Returns: An array of Link instances.
    static func parseLinks(_ text: String) -> [Link] {
        let pattern = #"\[\[([^\]\|]+)(?:\|([^\]]+))?\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }
        let nsrange = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: nsrange)
        return matches.compactMap { m in
            guard let targetRange = Range(m.range(at: 1), in: text) else { return nil }
            let target = String(text[targetRange])
            var alias: String? = nil
            if m.numberOfRanges > 2, let aliasRange = Range(m.range(at: 2), in: text) {
                alias = String(text[aliasRange])
            }
            return Link(target: target, alias: alias)
        }
    }

    /// State of a markdown task.
    enum TaskState: Equatable {
        /// Task not completed.
        case todo
        /// Task completed.
        case done
    }

    /// Represents a markdown task list item with state and content.
    struct Task: Equatable {
        /// 1-based line number in the source text.
        public let line: Int
        /// The task description text.
        public let text: String
        /// Completion state.
        public let state: TaskState
        public init(line: Int, text: String, state: TaskState) {
            self.line = line
            self.text = text
            self.state = state
        }
    }

    /// Parses markdown task list items ("- [ ]" and "- [x]") from the given text.
    /// - Parameter text: The markdown content.
    /// - Returns: An array of Task instances.
    static func parseTasks(_ text: String) -> [Task] {
        let lines = text.components(separatedBy: "\n")
        var results: [Task] = []
        for (idx, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let prefixTodo = "- [ ]"
            if trimmed.hasPrefix(prefixTodo) {
                let start = trimmed.index(trimmed.startIndex, offsetBy: prefixTodo.count)
                let content = trimmed[start...].trimmingCharacters(in: .whitespaces)
                results.append(Task(line: idx + 1, text: String(content), state: .todo))
                continue
            }
            let prefixDoneLower = "- [x]"
            let prefixDoneUpper = "- [X]"
            if trimmed.hasPrefix(prefixDoneLower) || trimmed.hasPrefix(prefixDoneUpper) {
                let prefixDone = trimmed.hasPrefix(prefixDoneLower) ? prefixDoneLower : prefixDoneUpper
                let start = trimmed.index(trimmed.startIndex, offsetBy: prefixDone.count)
                let content = trimmed[start...].trimmingCharacters(in: .whitespaces)
                results.append(Task(line: idx + 1, text: String(content), state: .done))
            }
        }
        return results
    }
}