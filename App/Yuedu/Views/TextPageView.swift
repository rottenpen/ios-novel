import SwiftUI
import CoreText
import ReaderCore

/// 绘制分页器生成的原始文字范围，尺寸与分页时保持一致；
/// 同时绘制正文内嵌图片（由 ImageStore 提供已下载的 UIImage）。
struct TextPageView: UIViewRepresentable {
    let pagination: TextPagination
    let page: Int
    let color: Color
    var imageProvider: (String) -> UIImage?
    /// 图片就绪计数，变化时强制重绘当前页
    var imageVersion: Int = 0

    func makeUIView(context: Context) -> PageCanvas {
        let view = PageCanvas()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: PageCanvas, context: Context) {
        let textColor = UIColor(color)
        // 拖动只改变页面的位置；正文、页码、颜色或图片就绪状态没变时无需重新绘制。
        guard view.pagination !== pagination || view.page != page
            || view.textColor != textColor || view.imageVersion != imageVersion else { return }
        view.pagination = pagination
        view.page = page
        view.textColor = textColor
        view.imageVersion = imageVersion
        view.imageProvider = imageProvider
        view.setNeedsDisplay()
    }
}

final class PageCanvas: UIView {
    var pagination: TextPagination?
    var page = 0
    var textColor = UIColor.label
    var imageVersion = 0
    var imageProvider: (String) -> UIImage? = { _ in nil }

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

        // 图片绘制（翻转坐标系后图片 rect 直接可用）
        let rects = pagination.imageRects(at: page, maxWidth: pagination.layout.width)
        for (anchor, rect) in rects {
            guard let image = imageProvider(anchor.url) else { continue }
            // 按真实宽高比适配占位框，图片不拉伸
            let ratio = image.size.height / max(1, image.size.width)
            let target = CGRect(
                x: rect.origin.x,
                y: rect.origin.y + (rect.height - min(rect.width * ratio, rect.height)) / 2,
                width: rect.width,
                height: min(rect.width * ratio, rect.height)
            )
            image.draw(in: target)
        }
    }
}
