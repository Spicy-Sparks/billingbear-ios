import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

#if canImport(UIKit)
import UIKit
#endif

// MARK: - Best-effort asset prewarm
//
// ASSETS NEVER BLOCK first paint. During prefetch we optionally warm the images / posters referenced
// by a paywall document so that when the layout paints from cache the hero/logo are already in
// URLCache (and decoded into the in-memory image cache where UIKit is available). This is strictly
// best-effort: every task is detached, failures are ignored, and nothing here is ever awaited on the
// present hot path. Disabling it (the default-on flag lives on the SDK) costs nothing.

/// Extracts the asset URLs a v1 document or a v2 tree references, and warms them via URLSession data
/// tasks. Pure URL extraction is exposed for unit testing without any network.
public enum PaywallAssetPrewarmer {

    /// Collect the remote image/poster URLs worth prewarming from a v1 document. Lottie/video are
    /// intentionally excluded — they stream and would waste bandwidth; only first-paint raster
    /// assets (hero, logo, background image, testimonial avatars) are returned.
    public static func assetURLs(in doc: PaywallDocument) -> [URL] {
        var raw: [String?] = []
        raw.append(doc.header.logoUrl)
        raw.append(doc.header.heroImageUrl)
        raw.append(doc.theme.backgroundImage?.url)
        raw.append(doc.theme.backgroundVideo?.posterUrl)
        raw.append(doc.theme.backgroundLottie?.posterUrl)
        if let testimonials = doc.socialProof?.testimonials {
            raw.append(contentsOf: testimonials.map { $0.avatarUrl })
        }
        // Page-scoped headers can reference their own hero/logo.
        for page in doc.pages ?? [] {
            raw.append(page.header?.logoUrl)
            raw.append(page.header?.heroImageUrl)
        }
        return dedupedURLs(raw)
    }

    /// Collect first-paint asset URLs from a v2 tree: theme background image/posters plus any image
    /// node sources discovered by walking the node graph.
    public static func assetURLs(in tree: PaywallTree) -> [URL] {
        var raw: [String?] = []
        raw.append(tree.theme.backgroundImage?.url)
        raw.append(tree.theme.backgroundVideo?.posterUrl)
        raw.append(tree.theme.backgroundLottie?.posterUrl)
        collectNodeImageSources(tree.root, into: &raw)
        for page in tree.pages ?? [] {
            collectNodeImageSources(page.root, into: &raw)
        }
        return dedupedURLs(raw)
    }

    private static func collectNodeImageSources(_ node: PaywallNode, into raw: inout [String?]) {
        // image / video / lottie nodes carry their source in `url`; video/lottie posters in
        // `posterUrl`; testimonial nodes carry an `avatarUrl`. Only warm raster first-paint assets.
        switch node.kind {
        case .image:
            raw.append(node.url)
        case .video, .lottie:
            raw.append(node.posterUrl)
        case .testimonial:
            raw.append(node.avatarUrl)
        default:
            break
        }
        for child in node.children {
            collectNodeImageSources(child, into: &raw)
        }
        // A productSelector's item template can itself reference images.
        if let template = node.itemTemplate?.node {
            collectNodeImageSources(template, into: &raw)
        }
    }

    private static func dedupedURLs(_ raw: [String?]) -> [URL] {
        var seen = Set<String>()
        var out: [URL] = []
        for case let s? in raw where !s.isEmpty {
            guard !seen.contains(s), let url = URL(string: s), url.scheme?.hasPrefix("http") == true else { continue }
            seen.insert(s)
            out.append(url)
        }
        return out
    }

    /// Fire best-effort GETs for each URL so the bytes land in `session`'s URLCache. Returns
    /// immediately; the warming happens on detached tasks. Never throws, never blocks first paint.
    public static func prewarm(_ urls: [URL], session: URLSession = .shared) {
        guard !urls.isEmpty else { return }
        for url in urls {
            var req = URLRequest(url: url)
            req.cachePolicy = .returnCacheDataElseLoad
            let task = session.dataTask(with: req) { data, _, _ in
                #if canImport(UIKit)
                // Decode into UIKit's image cache too, so the first render skips the decode cost.
                if let data, let image = UIImage(data: data) {
                    PaywallImageMemoryCache.shared.store(image, for: url)
                }
                #endif
            }
            task.resume()
        }
    }
}

#if canImport(UIKit)
/// Tiny in-memory decoded-image cache the prewarmer fills and the renderer can consult, so a
/// prewarmed hero/logo paints with no decode on first frame. Bounded by NSCache eviction.
public final class PaywallImageMemoryCache: @unchecked Sendable {
    public static let shared = PaywallImageMemoryCache()
    private let cache = NSCache<NSURL, UIImage>()

    private init() { cache.countLimit = 64 }

    public func store(_ image: UIImage, for url: URL) {
        cache.setObject(image, forKey: url as NSURL)
    }

    public func image(for url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }
}
#endif
