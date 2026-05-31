import SwiftUI
import UIKit
import ImageIO

/// Why this file exists: poster cells live in `LazyVGrid`s that recycle hard
/// (scrolling, focus-wrap top↔bottom, popping back to Home). A bare
/// `AsyncImage` issues a fresh network load every time a cell materializes and
/// surfaces the `NSURLErrorCancelled` (-999) that recycling produces as a
/// permanent `.failure` — so a cell that keeps getting cancelled stays on the
/// fallback glyph even though the server served the bytes fine. Caching decoded
/// images lets a re-appearing cell render instantly with *no* network call
/// (which is what defuses the cancellation storm), and treating cancellation as
/// "not done yet" lets a settled cell finish loading on its own.

/// Bounded, process-wide cache of decoded poster images. Keyed by the full
/// request URL (which includes the Refresh `&r=N` nonce). Bounded three ways so
/// it can't exhaust tvOS memory: a `countLimit`, a hard `totalCostLimit` summed
/// over each entry's decoded byte size, and `NSCache`'s own eviction under
/// memory pressure.
final class PosterImageCache {
    static let shared = PosterImageCache()

    /// Longest edge we ever keep in memory. Posters render in a ~180pt-wide box;
    /// 480px stays crisp on a 4K panel (and through the 1.05× focus zoom) while
    /// keeping each entry near ~0.5 MB instead of a full ~3.6 MB source decode.
    static let maxPixel: CGFloat = 480

    private let cache: NSCache<NSURL, UIImage> = {
        let c = NSCache<NSURL, UIImage>()
        c.countLimit = 96             // a few screens of posters
        c.totalCostLimit = 64 << 20   // 64 MB hard ceiling on decoded pixels
        return c
    }()

    func image(for url: URL) -> UIImage? { cache.object(forKey: url as NSURL) }

    func store(_ image: UIImage, cost: Int, for url: URL) {
        cache.setObject(image, forKey: url as NSURL, cost: cost)
    }

    /// Drop everything — called from the Home "Refresh" action so the user can
    /// force every poster to re-pull from the server.
    func clear() { cache.removeAllObjects() }
}

/// Downsample `data` to at most `maxPixel` on its longest edge, decoding eagerly
/// so the work happens here (off the main thread, inside the loader's task)
/// rather than at draw time. Returns the decoded image and its in-memory byte
/// cost. Falls back to a plain decode if ImageIO can't make a thumbnail.
func decodePoster(_ data: Data, maxPixel: CGFloat) -> (image: UIImage, cost: Int)? {
    let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else {
        guard let img = UIImage(data: data) else { return nil }
        return (img, data.count)
    }
    let thumbOpts = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceShouldCacheImmediately: true,
        kCGImageSourceThumbnailMaxPixelSize: maxPixel,
    ] as CFDictionary
    guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts) else {
        guard let img = UIImage(data: data) else { return nil }
        return (img, data.count)
    }
    let cost = cg.bytesPerRow * cg.height
    return (UIImage(cgImage: cg), cost)
}

/// Backs every poster cell. Loads through `PosterImageCache`: a cache hit paints
/// immediately with no network; a miss fetches, downsamples, caches, and shows
/// it. Crucially it does *not* fall back to the glyph on a cancellation — that's
/// just recycling, and `.task(id:)` re-runs when the cell reappears or the URL
/// (nonce) changes, so a settled cell always gets to finish.
struct PosterImageView<Fallback: View>: View {
    let url: URL
    @ViewBuilder let fallback: () -> Fallback

    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit()
            } else if failed {
                fallback()
            } else {
                // Loading (or recycled mid-flight): let the black box show.
                Color.clear
            }
        }
        .animation(.easeOut(duration: 0.18), value: image != nil)
        .task(id: url) { await load() }
    }

    private func load() async {
        if let cached = PosterImageCache.shared.image(for: url) {
            image = cached
            return
        }
        failed = false
        do {
            let (data, resp) = try await URLSession.shared.data(from: url)
            if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                failed = true
                return
            }
            guard let decoded = decodePoster(data, maxPixel: PosterImageCache.maxPixel) else {
                failed = true
                return
            }
            PosterImageCache.shared.store(decoded.image, cost: decoded.cost, for: url)
            image = decoded.image
        } catch is CancellationError {
            // Recycling, not a real failure — leave it clear; `.task(id:)`
            // retries on the next appearance.
        } catch let err as URLError where err.code == .cancelled {
            // Same: a cancelled request is recycling, not a load failure.
        } catch {
            failed = true
        }
    }
}
