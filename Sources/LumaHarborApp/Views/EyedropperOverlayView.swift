import EditorCore
import Localization
import RawProcessingCore
import SwiftUI

/// The white balance eyedropper's on-canvas hit area, drawn on top of the
/// photo while `EditorSession.toolMode == .whiteBalance` (design spec
/// §6.4). A press-and-hold previews the sampled point live
/// (`EditorSession.previewEyedropper(sample:)`, which never touches
/// `history`/`saveState`); releasing commits it
/// (`EditorSession.commitEyedropper()`) and returns to `.adjust`. The ring
/// marker is purely visual feedback for where the last sample was taken --
/// it carries no state of its own that affects the actual white balance.
struct EyedropperOverlayView: View {
    @ObservedObject var editor: EditorSession
    /// The fitted image rect from `AspectFitRect.fitting(...)` -- the same
    /// rectangle `CropOverlayView` (Task 2.3) draws and hit-tests against,
    /// so a click here lines up with the photo pixel for pixel regardless
    /// of window size or aspect ratio.
    let imageFrame: CGRect
    /// The currently displayed `CGImage` -- what the sample actually reads,
    /// via `PixelSampler`. Passed in rather than read from `editor
    /// .displayedImage` at gesture time, so what's sampled during a drag is
    /// always the frame the overlay itself was laid out against.
    let image: CGImage

    @State private var lastSampleLocation: CGPoint?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.clear)
                .contentShape(Rectangle())
                .frame(width: imageFrame.width, height: imageFrame.height)
                .position(x: imageFrame.midX, y: imageFrame.midY)
                .gesture(sampleGesture)

            if let lastSampleLocation {
                Circle()
                    .strokeBorder(Color.white, lineWidth: 1.5)
                    .frame(width: 20, height: 20)
                    .shadow(radius: 1)
                    .position(lastSampleLocation)
                    .allowsHitTesting(false)
            }
        }
        .help(L10n.t("Click a point that should be neutral gray"))
    }

    private var sampleGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                sample(at: value.location, commit: false)
            }
            .onEnded { value in
                sample(at: value.location, commit: true)
            }
    }

    private func sample(at location: CGPoint, commit: Bool) {
        let pixel = AspectFitRect.imagePixel(
            at: location,
            imageFrame: imageFrame,
            imageSize: CGSize(width: image.width, height: image.height)
        )
        guard let rgb = PixelSampler.sample(at: pixel, in: image) else { return }
        lastSampleLocation = location
        editor.previewEyedropper(sample: WhiteBalanceEyedropper.Sample(red: rgb.red, green: rgb.green, blue: rgb.blue))
        if commit {
            editor.commitEyedropper()
            editor.setToolMode(.adjust)
        }
    }
}
