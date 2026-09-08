import CoreGraphics
import Foundation

/// UI-only viewport state for the Mac editor canvas. It never enters the
/// photo adjustment sidecar or the editor undo history.
enum CanvasViewportMode: Equatable {
    case fit
    case oneToOne
    case custom
}

struct CanvasViewportState: Equatable {
    static let minimumScale: CGFloat = 0.1
    static let maximumScale: CGFloat = 8

    var scale: CGFloat
    var offset: CGSize
    var mode: CanvasViewportMode

    mutating func setFit(imageSize: CGSize, viewportSize: CGSize) {
        scale = Self.fitScale(imageSize: imageSize, viewportSize: viewportSize)
        offset = .zero
        mode = .fit
    }

    mutating func zoom(
        to requestedScale: CGFloat,
        anchor: CGPoint,
        imageSize: CGSize,
        viewportSize: CGSize
    ) {
        let nextScale = min(max(requestedScale, Self.minimumScale), Self.maximumScale)
        let ratio = nextScale / max(scale, Self.minimumScale)
        let anchorFromCenter = CGSize(
            width: anchor.x - viewportSize.width / 2,
            height: anchor.y - viewportSize.height / 2
        )
        offset = CGSize(
            width: anchorFromCenter.width - (anchorFromCenter.width - offset.width) * ratio,
            height: anchorFromCenter.height - (anchorFromCenter.height - offset.height) * ratio
        )
        scale = nextScale
        mode = nextScale == 1 ? .oneToOne : .custom
        clampOffset(imageSize: imageSize, viewportSize: viewportSize)
    }

    mutating func pan(by translation: CGSize, imageSize: CGSize, viewportSize: CGSize) {
        offset.width += translation.width
        offset.height += translation.height
        clampOffset(imageSize: imageSize, viewportSize: viewportSize)
    }

    mutating func clampOffset(imageSize: CGSize, viewportSize: CGSize) {
        let scaledSize = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        let maxX = max(0, (scaledSize.width - viewportSize.width) / 2)
        let maxY = max(0, (scaledSize.height - viewportSize.height) / 2)
        offset.width = min(max(offset.width, -maxX), maxX)
        offset.height = min(max(offset.height, -maxY), maxY)
    }

    private static func fitScale(imageSize: CGSize, viewportSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewportSize.width > 0, viewportSize.height > 0 else { return 1 }
        return min(
            viewportSize.width / imageSize.width,
            viewportSize.height / imageSize.height
        )
    }

    /// Fixed step ladder for `Command +`/`Command -` (spec §5.2.1): 10%,
    /// 25%, 50%, 100%, 200%, 400%, 800% -- the same values the toolbar's
    /// percentage menu offers, plus the two extremes `minimumScale`/
    /// `maximumScale` already clamp to.
    static let zoomSteps: [CGFloat] = [0.1, 0.25, 0.5, 1, 2, 4, 8]

    /// The next ladder value strictly above (`direction > 0`) or below
    /// (`direction < 0`) `scale`, clamped to the ladder's own ends. A scale
    /// that isn't exactly on a step (e.g. left over from a pinch) moves to
    /// the nearest neighbour in the requested direction rather than
    /// skipping past it.
    static func steppedScale(from scale: CGFloat, direction: Int) -> CGFloat {
        guard direction != 0 else { return scale }
        if direction > 0 {
            return zoomSteps.first(where: { $0 > scale }) ?? zoomSteps.last!
        }
        return zoomSteps.last(where: { $0 < scale }) ?? zoomSteps.first!
    }
}
