import XCTest
@testable import QuotaCore

final class GridLayoutTests: XCTestCase {
    private func columns(_ count: Int) -> Int {
        GridLayout.balancedColumns(count: count, maxColumns: 5)
    }

    func testUpToFiveTilesStayOnOneRow() {
        XCTAssertEqual(columns(1), 1)
        XCTAssertEqual(columns(2), 2)
        XCTAssertEqual(columns(4), 4)
        XCTAssertEqual(columns(5), 5, "the overview plus four providers — the common case")
    }

    /// The whole point: no row is ever left with one tile.
    func testRowsAreBalancedNotFrontLoaded() {
        XCTAssertEqual(columns(6), 3, "3 + 3, not 4 + 2")
        XCTAssertEqual(columns(7), 4, "4 + 3")
        XCTAssertEqual(columns(8), 4, "4 + 4")
        XCTAssertEqual(columns(9), 5, "5 + 4")
        XCTAssertEqual(columns(10), 5, "5 + 5")
        XCTAssertEqual(columns(11), 4, "4 + 4 + 3, not 5 + 5 + 1")
        XCTAssertEqual(columns(12), 4, "4 + 4 + 4 — the overview plus all eleven providers")
    }

    /// The whole point: no row is ever left with one tile. Pinned over the
    /// counts the app can produce — the overview plus up to eleven providers.
    /// (Past twenty the guarantee cannot hold for every count: 21 tiles leave
    /// one over at three, four and five columns alike.)
    func testTheLastRowIsNeverASingleTile() {
        for count in 2...12 {
            let cols = columns(count)
            let lastRow = count % cols == 0 ? cols : count % cols
            XCTAssertGreaterThan(lastRow, 1, "count \(count) → \(cols) columns leaves \(lastRow) on the last row")
        }
    }

    func testDegenerateInputs() {
        XCTAssertEqual(columns(0), 1)
        XCTAssertEqual(GridLayout.balancedColumns(count: 7, maxColumns: 0), 1)
        XCTAssertEqual(GridLayout.balancedColumns(count: 7, maxColumns: 4), 4, "4 + 3 under a four-column cap")
    }
}
