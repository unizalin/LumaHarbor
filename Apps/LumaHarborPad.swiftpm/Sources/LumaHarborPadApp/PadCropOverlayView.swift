import EditorCore
import RawProcessingCore
import SwiftUI

/// iPad's crop overlay uses the same normalized crop model as the Mac editor.
/// It is kept in this target because the iPad app intentionally does not
/// depend on the Mac-only `LumaHarborApp` target.
struct PadCropOverlayView: View {
    @ObservedObject private var editor: EditorSession
    let imageFrame: CGRect

    /// The white corner dot stays visually small, but its transparent gesture
    /// surface must meet the iPad touch-target minimum so crop handles remain
    /// usable in portrait and Split View layouts.
    private static let handleHitAreaSize: CGFloat = 44

    @State private var dragBaseCrop: NormalizedCropRect?

    init(editor: EditorSession, imageFrame: CGRect) {
        self.editor = editor
        self.imageFrame = imageFrame
    }

    private var currentAdjustments: PhotoAdjustments {
        editor.adjustments
    }

    private var aspectRatio: Double? {
        switch currentAdjustments.geometry.cropAspectRatio {
        case .freeform: return nil
        case .original: return 1
        case .square: return imageFrame.height / imageFrame.width
        case .custom(let width, let height):
            guard width.isFinite, height.isFinite, width > 0, height > 0 else { return nil }
            return (width / height) * imageFrame.height / imageFrame.width
        }
    }

    private var crop: NormalizedCropRect {
        let base = currentAdjustments.geometry.crop ?? .full
        return aspectRatio.map { base.fitting(aspectRatio: $0) } ?? base
    }

    private var cropFrame: CGRect {
        CGRect(
            x: imageFrame.minX + crop.x * imageFrame.width,
            y: imageFrame.minY + crop.y * imageFrame.height,
            width: crop.width * imageFrame.width,
            height: crop.height * imageFrame.height
        )
    }

    var body: some View {
        ZStack {
            Path { path in
                path.addRect(imageFrame)
                path.addRect(cropFrame)
            }
            .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
            .allowsHitTesting(false)

            Rectangle()
                .strokeBorder(Color.white, lineWidth: 1.5)
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .allowsHitTesting(false)

            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: cropFrame.width, height: cropFrame.height)
                .position(x: cropFrame.midX, y: cropFrame.midY)
                .gesture(dragGesture(for: .move))

            ForEach(PadCropHandle.corners, id: \.self) { handle in
                Circle()
                    .fill(Color.white)
                    .frame(width: 12, height: 12)
                    .shadow(radius: 1)
                    .frame(width: Self.handleHitAreaSize, height: Self.handleHitAreaSize)
                    .contentShape(Circle())
                    .position(handlePosition(handle))
                    .gesture(dragGesture(for: handle))
                    .accessibilityLabel(Text(handle.accessibilityLabel))
            }
        }
    }

    private func handlePosition(_ handle: PadCropHandle) -> CGPoint {
        switch handle {
        case .topLeft: return CGPoint(x: cropFrame.minX, y: cropFrame.minY)
        case .topRight: return CGPoint(x: cropFrame.maxX, y: cropFrame.minY)
        case .bottomLeft: return CGPoint(x: cropFrame.minX, y: cropFrame.maxY)
        case .bottomRight: return CGPoint(x: cropFrame.maxX, y: cropFrame.maxY)
        case .move: return CGPoint(x: cropFrame.midX, y: cropFrame.midY)
        }
    }

    private func dragGesture(for handle: PadCropHandle) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                let base = dragBaseCrop ?? crop
                if dragBaseCrop == nil { dragBaseCrop = base }
                let updated = PadCropDragMath.updatedCrop(
                    base: base,
                    handle: handle,
                    translation: value.translation,
                    imageFrameSize: imageFrame.size,
                    normalizedAspectRatio: aspectRatio
                )
                editor.updateAdjustments { $0.geometry.crop = updated.isFull ? nil : updated }
            }
            .onEnded { _ in dragBaseCrop = nil }
    }
}

enum PadCropHandle: Hashable {
    case topLeft, topRight, bottomLeft, bottomRight, move

    static let corners: [PadCropHandle] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    var accessibilityLabel: String {
        switch self {
        case .topLeft: return "Crop top left"
        case .topRight: return "Crop top right"
        case .bottomLeft: return "Crop bottom left"
        case .bottomRight: return "Crop bottom right"
        case .move: return "Move crop"
        }
    }
}

private enum PadCropDragMath {
    static func updatedCrop(
        base: NormalizedCropRect,
        handle: PadCropHandle,
        translation: CGSize,
        imageFrameSize: CGSize,
        normalizedAspectRatio: Double?
    ) -> NormalizedCropRect {
        guard imageFrameSize.width > 0, imageFrameSize.height > 0 else { return base }
        let dx = Double(translation.width / imageFrameSize.width)
        let dy = Double(translation.height / imageFrameSize.height)
        guard let ratio = normalizedAspectRatio, ratio.isFinite, ratio > 0 else {
            switch handle {
            case .topLeft: return NormalizedCropRect(x: base.x + dx, y: base.y + dy, width: base.width - dx, height: base.height - dy)
            case .topRight: return NormalizedCropRect(x: base.x, y: base.y + dy, width: base.width + dx, height: base.height - dy)
            case .bottomLeft: return NormalizedCropRect(x: base.x + dx, y: base.y, width: base.width - dx, height: base.height + dy)
            case .bottomRight: return NormalizedCropRect(x: base.x, y: base.y, width: base.width + dx, height: base.height + dy)
            case .move: return NormalizedCropRect(x: base.x + dx, y: base.y + dy, width: base.width, height: base.height)
            }
        }
        if handle == .move {
            return NormalizedCropRect(x: base.x + dx, y: base.y + dy, width: base.width, height: base.height)
        }

        let left = handle == .topLeft || handle == .bottomLeft
        let top = handle == .topLeft || handle == .topRight
        let fixedX = left ? base.x + base.width : base.x
        let fixedY = top ? base.y + base.height : base.y
        let draggedX = left ? base.x + dx : base.x + base.width + dx
        let draggedY = top ? base.y + dy : base.y + base.height + dy
        let requestedWidth = max(abs(draggedX - fixedX), NormalizedCropRect.minimumDimension)
        let requestedHeight = max(abs(draggedY - fixedY), NormalizedCropRect.minimumDimension)
        let width = max(requestedWidth, requestedHeight * ratio)
        let maxWidth = min(left ? fixedX : 1 - fixedX, (top ? fixedY : 1 - fixedY) * ratio)
        let clampedWidth = min(max(width, NormalizedCropRect.minimumDimension), max(maxWidth, NormalizedCropRect.minimumDimension))
        let height = clampedWidth / ratio
        return NormalizedCropRect(
            x: left ? fixedX - clampedWidth : fixedX,
            y: top ? fixedY - height : fixedY,
            width: clampedWidth,
            height: height
        )
    }
}
