import XCTest
@testable import ObsidianModel

final class FrontMatterTests: XCTestCase {
    func testNoFrontMatter() throws {
        let text = "Hello, world!"
        let doc = try ObsidianModel.parseDocument(text)
        XCTAssertTrue(doc.metadata.isEmpty)
        XCTAssertEqual(doc.body, text)
    }

    func testFrontMatterParsing() throws {
        let yaml = """
        title: Test Note
        tags:
          - one
          - two
        """
        let body = "This is the body."
        let full = "---\n" + yaml + "---\n" + body
        let doc = try ObsidianModel.parseDocument(full)
        XCTAssertEqual(doc.metadata["title"] as? String, "Test Note")
        let tags = doc.metadata["tags"] as? [Any]
        XCTAssertEqual(tags?.count, 2)
        XCTAssertEqual(tags?[0] as? String, "one")
        XCTAssertEqual(tags?[1] as? String, "two")
        XCTAssertEqual(doc.body, body)
    }
}

// For Linux test discovery
extension FrontMatterTests {
    static var allTests = [
        ("testNoFrontMatter", testNoFrontMatter),
        ("testFrontMatterParsing", testFrontMatterParsing),
    ]
}