import Testing
import ReaderCore

@Suite("翻页手势")
struct PageTurnGestureTests {
    @Test("尚未达到翻页阈值时，页面也应跟随手指")
    func followsFingerBeforeRelease() {
        #expect(PageTurnGesture.offset(horizontal: -24, vertical: 2, width: 350) == -24)
        #expect(PageTurnGesture.offset(horizontal: 18, vertical: -3, width: 350) == 18)
        #expect(PageTurnGesture.direction(horizontal: -24, vertical: 2) == 0)
    }

    @Test("只有横向超过阈值才翻一页", arguments: [
        (-80.0, 10.0, 1), (80.0, -10.0, -1),
        (-35.0, 0.0, 0), (12.0, 0.0, 0),
        (40.0, 90.0, 0), (0.0, 0.0, 0)
    ])
    func direction(sample: (Double, Double, Int)) {
        #expect(PageTurnGesture.direction(horizontal: sample.0, vertical: sample.1) == sample.2)
    }

    @Test("纵向动作不移动页面，横向拖动最多显示相邻一页")
    func bounds() {
        #expect(PageTurnGesture.offset(horizontal: 20, vertical: 70, width: 350) == 0)
        #expect(PageTurnGesture.offset(horizontal: -800, vertical: 0, width: 350) == -350)
        #expect(PageTurnGesture.offset(horizontal: 800, vertical: 0, width: 350) == 350)
    }
}
