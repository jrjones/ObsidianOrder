import XCTest
@testable import ObsidianModel

final class LinkTests: XCTestCase {
    func testNoLinks() throws {
        let text = "No links here"
        let links = ObsidianModel.parseLinks(text)
        XCTAssertTrue(links.isEmpty)
    }

    func testSingleLink() throws {
        let text = "Link to [[Page]] in text"
        let links = ObsidianModel.parseLinks(text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].target, "Page")
        XCTAssertNil(links[0].alias)
    }

    func testLinkWithAlias() throws {
        let text = "Alias to [[Page|Alias]] here"
        let links = ObsidianModel.parseLinks(text)
        XCTAssertEqual(links.count, 1)
        XCTAssertEqual(links[0].target, "Page")
        XCTAssertEqual(links[0].alias, "Alias")
    }

    func testMultipleLinks() throws {
        let text = "[[One]] and [[Two|Second]]"
        let links = ObsidianModel.parseLinks(text)
        XCTAssertEqual(links.count, 2)
        XCTAssertEqual(links[0], ObsidianModel.Link(target: "One", alias: nil))
        XCTAssertEqual(links[1], ObsidianModel.Link(target: "Two", alias: "Second"))
    }
}

// For Linux test discovery
extension LinkTests {
    static var allTests = [
        ("testNoLinks", testNoLinks),
        ("testSingleLink", testSingleLink),
        ("testLinkWithAlias", testLinkWithAlias),
        ("testMultipleLinks", testMultipleLinks),
    ]
}