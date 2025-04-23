import XCTest
@testable import ObsidianModel

final class TaskTests: XCTestCase {
    func testNoTasks() throws {
        let text = "No tasks here"
        let tasks = ObsidianModel.parseTasks(text)
        XCTAssertTrue(tasks.isEmpty)
    }

    func testSingleTaskIncomplete() throws {
        let text = "- [ ] Do something"
        let tasks = ObsidianModel.parseTasks(text)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].line, 1)
        XCTAssertEqual(tasks[0].text, "Do something")
        XCTAssertEqual(tasks[0].state, .todo)
    }

    func testSingleTaskComplete() throws {
        let text = "- [x] Done"
        let tasks = ObsidianModel.parseTasks(text)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].line, 1)
        XCTAssertEqual(tasks[0].text, "Done")
        XCTAssertEqual(tasks[0].state, .done)
    }

    func testTasksWithMultipleLines() throws {
        let text = """
        Some text
        - [ ] Task 1
        - [x] Task 2
        Other
        """
        let tasks = ObsidianModel.parseTasks(text)
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks[0], ObsidianModel.Task(line: 2, text: "Task 1", state: .todo))
        XCTAssertEqual(tasks[1], ObsidianModel.Task(line: 3, text: "Task 2", state: .done))
    }

    func testTasksWithLeadingSpaces() throws {
        let text = "  - [ ] indented task"
        let tasks = ObsidianModel.parseTasks(text)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].text, "indented task")
    }

    func testTaskUppercaseX() throws {
        let text = "- [X] Completed"
        let tasks = ObsidianModel.parseTasks(text)
        XCTAssertEqual(tasks.count, 1)
        XCTAssertEqual(tasks[0].state, .done)
    }
}

// For Linux test discovery
extension TaskTests {
    static var allTests = [
        ("testNoTasks", testNoTasks),
        ("testSingleTaskIncomplete", testSingleTaskIncomplete),
        ("testSingleTaskComplete", testSingleTaskComplete),
        ("testTasksWithMultipleLines", testTasksWithMultipleLines),
        ("testTasksWithLeadingSpaces", testTasksWithLeadingSpaces),
        ("testTaskUppercaseX", testTaskUppercaseX),
    ]
}