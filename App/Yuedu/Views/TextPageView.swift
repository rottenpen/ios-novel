import SwiftUI
import CoreText
import ReaderCore

/// 绘制分页器生成的原始文字范围，尺寸与分页时保持一致。
struct TextPageView: UIViewRepresentable {
    let pagination: TextPagination
    let page: Int
    let color: Color

    func makeUIView(context: Context) -> PageCanvas {
        let view = PageCanvas()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PageCanvas, context: Context) {
        let textColor = UIColor(color)
        // 拖动只改变页面的位置；正文、页码和颜色没变时无需重新排版绘制。
        guard view.pagination !== pagination || view.page != page || view.textColor != textColor else { return }
        view.pagination = pagination
        view.page = page
        view.textColor = textColor
        view.setNeedsDisplay()
    }
}

final class PageCanvas: UIView {
    var pagination: TextPagination?
    var page = 0
    var textColor = UIColor.label

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let pagination,
              let frame = pagination.frame(at: page) else { return }
        context.saveGState()
        context.textMatrix = .identity
        context.translateBy(x: 0, y: pagination.layout.height)
        context.scaleBy(x: 1, y: -1)
        context.setFillColor(textColor.cgColor)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }
}
