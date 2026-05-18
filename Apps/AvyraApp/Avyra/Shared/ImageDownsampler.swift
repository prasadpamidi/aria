import Foundation
import ImageIO
import UniformTypeIdentifiers

// MARK: - ImageDownsampler

/// Shrinks picker-supplied image bytes to a sane upper bound before we
/// keep them in memory, persist them in the chat history, or hand them
/// to a vision model.
///
/// **Why.** A modern iPhone delivers ~12 MP HEIC frames from
/// `PhotosPicker`. A single full-frame UIImage decodes to ~48 MB of
/// pixel data (4032×3024 × 4 bytes). With the multi-image chat flow we
/// previously stored these full-resolution bytes in:
///
///   - `pendingImages` (up to 6 attachments per turn)
///   - the user `TranscriptItem`'s `attachedImages` (kept for the
///     lifetime of the session so the user can see what they sent)
///   - `Message.user(images:)` → `HistoryMiddleware` → GRDB row
///
/// Multiplied across copies plus repeated `UIImage(data:)` re-decodes
/// on every text-delta re-render, a single 6-image turn pushed the
/// process well past iOS's per-app memory limit and got us jetsam'd —
/// even with the `increased-memory-limit` entitlement, which only
/// adds ~50% headroom.
///
/// **How.** `CGImageSourceCreateThumbnailAtIndex` with
/// `kCGImageSourceThumbnailMaxPixelSize` tells ImageIO to scale the
/// frame as it decodes, so the full-resolution pixel buffer is never
/// materialized. We re-encode as JPEG q=0.8, which is small enough to
/// be cheap to re-decode for thumbnails and still ample fidelity for
/// vision-model inference.
/// `nonisolated` so the static method can be invoked from a
/// `Task.detached` background context. The work is pure — bytes in,
/// bytes out — and has no need to bounce through the MainActor.
nonisolated enum ImageDownsampler {
    /// Target max edge in pixels. Big enough for the bubble's
    /// 180×180 thumbnail at 3× retina (540 pt) and for vision models
    /// (Apple-Intelligence / typical MLX VLMs accept ≤1024–2048 in
    /// the longest dimension). Bumping much higher costs memory
    /// quadratically with negligible inference quality gain.
    static let maxPixelSize: CGFloat = 1280

    /// JPEG re-encode quality. 0.8 gives a 5–10× size reduction over
    /// the source with no visible difference at the sizes the chat
    /// renders.
    static let jpegQuality: CGFloat = 0.8

    /// Downsample to `maxPixelSize` and re-encode as JPEG. Returns the
    /// original bytes unchanged on any failure (e.g., unrecognized
    /// format) — the caller can still try to render it; worst case
    /// the bubble shows a placeholder.
    static func downsample(_ data: Data, maxPixelSize: CGFloat = Self.maxPixelSize) -> Data {
        let sourceOptions: [CFString: Any] = [
            kCGImageSourceShouldCache: false,
        ]
        guard let source = CGImageSourceCreateWithData(
            data as CFData,
            sourceOptions as CFDictionary
        ) else {
            return data
        }

        let scale: CGFloat = 1.0
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize * scale,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(
            source, 0, thumbnailOptions as CFDictionary
        ) else {
            return data
        }

        let out = NSMutableData()
        let utType = UTType.jpeg.identifier as CFString
        guard let destination = CGImageDestinationCreateWithData(
            out as CFMutableData, utType, 1, nil
        ) else {
            return data
        }
        let destOptions: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: jpegQuality,
        ]
        CGImageDestinationAddImage(destination, cgImage, destOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            return data
        }
        return out as Data
    }
}
