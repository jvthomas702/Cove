import XCTest
@testable import Cove

final class SmokeTests: XCTestCase {
    func testHTTPParse() {
        let raw = "POST /event HTTP/1.1\r\nHost: x\r\nContent-Length: 2\r\nOrigin: chrome-extension://abc\r\n\r\n{}"
        guard case .complete(let request) = HTTPRequest.parse(Data(raw.utf8)) else { return XCTFail("not parsed") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/event")
        XCTAssertEqual(request.origin, "chrome-extension://abc")
    }
}
