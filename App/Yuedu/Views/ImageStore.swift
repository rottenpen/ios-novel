import SwiftUI
import UIKit

/// 正文图片加载器：内存缓存 + 并发去重 + 完成通知。
/// `loadedCount` 变化时驱动阅读页重绘已就绪的图片。
@MainActor
final class ImageStore: ObservableObject {
    @Published private(set) var loadedCount = 0

    private let cache = NSCache<NSString, UIImage>()
    private var inflight: [String: Task<Void, Never>] = [:]

    func image(for url: String) -> UIImage? {
        cache.object(forKey: url as NSString)
    }

    /// 预加载一批图片 URL；已在缓存或加载中会跳过。
    func load(urls: [String]) {
        for url in urls where cache.object(forKey: url as NSString) == nil && inflight[url] == nil {
            inflight[url] = Task { [weak self] in
                guard let image = await Self.download(url) else { return }
                guard let self, !Task.isCancelled else { return }
                self.cache.setObject(image, forKey: url as NSString)
                self.inflight[url] = nil
                self.loadedCount += 1
            }
        }
    }

    private static func download(_ url: String) async -> UIImage? {
        guard let url = URL(string: url) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else {
                return nil
            }
            return image
        } catch {
            return nil
        }
    }
}
