import CoreGraphics
import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// Cross-platform canvas eyedropper. It captures the displayed frame and
/// sampling context at press time so a later render cannot change the meaning
/// of the gesture.
public struct WhiteBalanceEyedropperOverlay: View {
    @ObservedObject private var editor: EditorSession
    private let imageFrame: CGRect
    private let image: CGImage
    @State private var snapshot: Snapshot?
    @State private var attempted = false

    private struct Snapshot {
        let image: CGImage
        let frame: CGRect
        let context: EditorSession.EyedropperSamplingContext
    }

    public init(editor: EditorSession, imageFrame: CGRect, image: CGImage) {
        self.editor = editor
        self.imageFrame = imageFrame
        self.image = image
    }

    public var body: some View {
        Rectangle()
            .fill(Color.clear)
            .contentShape(Rectangle())
            .frame(width: imageFrame.width, height: imageFrame.height)
            .position(x: imageFrame.midX, y: imageFrame.midY)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { sample($0.location, commit: false) }
                    .onEnded { sample($0.location, commit: true); snapshot = nil; attempted = false }
            )
            .accessibilityLabel(Text(L10n.t("White Balance Eyedropper")))
    }

    private func sample(_ location: CGPoint, commit: Bool) {
        if !attempted {
            attempted = true
            guard imageFrame.width > 0, imageFrame.height > 0,
                  let context = editor.beginEyedropperSampling(sourceImage: image) else {
                editor.rejectEyedropperSample(editor.whiteBalanceCapability == .valid ? .staleFrame : .unavailableBaseline)
                return
            }
            snapshot = Snapshot(image: image, frame: imageFrame, context: context)
        }
        guard let snapshot else { return }
        guard snapshot.frame.contains(location) else {
            editor.rejectEyedropperSample(.outOfRange, context: snapshot.context)
            return
        }
        let fractionX = (location.x - snapshot.frame.minX) / snapshot.frame.width
        let fractionY = (location.y - snapshot.frame.minY) / snapshot.frame.height
        let pixel = CGPoint(
            x: min(max(fractionX, 0), 1) * CGFloat(snapshot.image.width),
            y: min(max(fractionY, 0), 1) * CGFloat(snapshot.image.height)
        )
        guard let rgb = PixelSampler.sample(at: pixel, in: snapshot.image) else {
            editor.rejectEyedropperSample(.outOfRange, context: snapshot.context)
            return
        }
        editor.previewEyedropper(sample: .init(red: rgb.red, green: rgb.green, blue: rgb.blue),
            context: snapshot.context)
        if commit, editor.commitEyedropper(context: snapshot.context) {
            editor.setToolMode(.adjust)
        }
    }
}
