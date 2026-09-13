import XCTest
@testable import QuotaCore

final class ReleaseNotesTests: XCTestCase {
    private let body = """
    ### 2026-09-13

    #### Added

    - The menu bar icon's right-click menu is redone.

    #### Fixed

    - "Check now" did nothing
      with automatic checks off.

    ---

    ### 2026-09-13

    #### 新增

    - 菜单栏图标的右键菜单重做。

    #### 修复

    - 关闭自动检查后「立即检查」没有反应。
    """

    func testPicksTheChineseHalf() {
        let notes = ReleaseNotes.parse(body, chinese: true)
        XCTAssertEqual(notes.groups.map(\.title), ["新增", "修复"])
        XCTAssertEqual(notes.groups.map(\.kind), [.added, .fixed])
        XCTAssertEqual(notes.groups.first?.items, ["菜单栏图标的右键菜单重做。"])
    }

    func testPicksTheEnglishHalfAndJoinsWrappedBullets() {
        let notes = ReleaseNotes.parse(body, chinese: false)
        XCTAssertEqual(notes.groups.map(\.kind), [.added, .fixed])
        XCTAssertEqual(notes.groups.last?.items, [#""Check now" did nothing with automatic checks off."#])
        XCTAssertEqual(notes.itemCount, 2)
    }

    /// 0.5.0's hand-written body: an intro, then topic headings.
    func testASingleHandWrittenBody() {
        let notes = ReleaseNotes.parse("""
        0.5.0 把下拉面板请了回来。

        ## 下拉面板
        - 左键点菜单栏图标打开。
        - 顶部是花费卡片。
        """, chinese: false)
        XCTAssertEqual(notes.intro, "0.5.0 把下拉面板请了回来。")
        XCTAssertEqual(notes.groups.first?.kind, .other)
        XCTAssertEqual(notes.groups.first?.items.count, 2)
    }

    func testNoBodyIsEmpty() {
        XCTAssertTrue(ReleaseNotes.parse(nil).isEmpty)
        XCTAssertTrue(ReleaseNotes.parse("  \n").isEmpty)
    }
}
