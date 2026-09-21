import Foundation

/// 阅读正文的横向拖动规则，位移单位为屏幕点。
public enum PageTurnGesture {
    public static func offset(horizontal: Double, vertical: Double, width: Double) -> Double {
        guard width > 0, abs(horizontal) > abs(vertical) else { return 0 }
        return min(width, max(-width, horizontal))
    }

    public static func direction(horizontal: Double, vertical: Double) -> Int {
        guard abs(horizontal) > abs(vertical), abs(horizontal) > 35 else { return 0 }
        return horizontal < 0 ? 1 : -1
    }
}
