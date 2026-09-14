import SwiftUI
import ReaderCore

/// 网络封面图，带占位、失败兜底与圆角。
///
/// 不用 AsyncImage 的原因：部分书源封面需要携带 Referer / UA 才能取到，
/// 这里统一走 ReaderCore 的 HTTPClient，并做内存缓存。
struct BookCover: View {
    let url: String?
    var width: CGFloat = DS.Cover.listWidth
    var height: CGFloat = DS.Cover.listHeight
    /// 无封面时用书名首字兜底，避免大片空白
    var fallbackText: String = ""

    @State private var image: UIImage?
    @State private var isLoading = false

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.cover, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.cover, style: .continuous)
                .strokeBorder(DS.separator, lineWidth: 0.5)
        )
        .task(id: url) { await load() }
    }

    private var placeholder: some View {
        ZStack {
            LinearGradient(
                colors: [DS.accent.opacity(0.18), DS.accent.opacity(0.06)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            if isLoading {
                ProgressView().controlSize(.small)
            } else if let first = fallbackText.first {
                Text(String(first))
                    .font(.system(size: width * 0.4, weight: .semibold, design: .serif))
                    .foregroundStyle(DS.accent.opacity(0.65))
            } else {
                Image(systemName: "book.closed")
                    .font(.system(size: width * 0.3))
                    .foregroundStyle(DS.accent.opacity(0.5))
            }
        }
    }

    private func load() async {
        guard let url, !url.isEmpty else { return }
        if let cached = CoverCache.shared.image(for: url) {
            image = cached
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let data = try await HTTPClient.shared.data(url: url)
            guard let loaded = UIImage(data: data) else { return }
            CoverCache.shared.set(loaded, for: url)
            // 校验 url 未变，避免快速滚动时错位
            if url == self.url { image = loaded }
        } catch {
            // 封面失败不提示，静默走占位
        }
    }
}

/// 封面内存缓存，限制条目数避免无限增长
final class CoverCache: @unchecked Sendable {
    static let shared = CoverCache()
    private let cache = NSCache<NSString, UIImage>()

    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
    }

    func image(for url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    func set(_ image: UIImage, for url: String) {
        let cost = Int(image.size.width * image.size.height * 4)
        cache.setObject(image, forKey: url as NSString, cost: cost)
    }
}

/// 空状态视图：图标 + 说明 + 可选操作
struct EmptyStateView: View {
    let icon: String
    let title: String
    var message: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: DS.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(DS.accent.opacity(0.5))
            Text(title)
                .font(.headline)
            if let message {
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, DS.Spacing.xxl)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .tint(DS.accent)
                    .padding(.top, DS.Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DS.Spacing.xl)
    }
}

/// 轻量提示条（替代 Android Toast）
struct ToastView: View {
    let text: String
    var isError = false

    var body: some View {
        HStack(spacing: DS.Spacing.sm) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            Text(text).font(.subheadline)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, DS.Spacing.lg)
        .padding(.vertical, DS.Spacing.md)
        .background(
            Capsule().fill(isError ? Color.red.opacity(0.9) : Color.black.opacity(0.8))
        )
        .shadow(radius: 8, y: 4)
    }
}

/// Toast 宿主修饰器
struct ToastModifier: ViewModifier {
    @Binding var message: String?
    var isError = false

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                ToastView(text: message, isError: isError)
                    .padding(.bottom, 80)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        withAnimation(DS.Motion.gentle) { self.message = nil }
                    }
            }
        }
        .animation(DS.Motion.standard, value: message)
    }
}

extension View {
    func toast(_ message: Binding<String?>, isError: Bool = false) -> some View {
        modifier(ToastModifier(message: message, isError: isError))
    }
}
