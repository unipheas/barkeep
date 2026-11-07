import XCTest
@testable import BarKeep

final class CanvasTests: XCTestCase {
    func testStrokesStayConnectedInEveryDirection() {
        let center = CanvasCell(x: 36, y: 8)
        for end in [CanvasCell(x: 0, y: 0), .init(x: 71, y: 0), .init(x: 0, y: 15),
                    .init(x: 71, y: 15), .init(x: 36, y: 0), .init(x: 36, y: 15),
                    .init(x: 0, y: 8), .init(x: 71, y: 8), center] {
            for (start, finish) in [(center, end), (end, center)] {
                let cells = CanvasCell.line(from: start, to: finish)
                XCTAssertEqual(cells.first, start)
                XCTAssertEqual(cells.last, finish)
                XCTAssertEqual(cells.count, max(abs(finish.x-start.x), abs(finish.y-start.y))+1)
                for (a,b) in zip(cells,cells.dropFirst()) {
                    XCTAssertLessThanOrEqual(abs(a.x-b.x),1)
                    XCTAssertLessThanOrEqual(abs(a.y-b.y),1)
                    XCTAssertNotEqual(a,b)
                }
            }
        }
    }
}
