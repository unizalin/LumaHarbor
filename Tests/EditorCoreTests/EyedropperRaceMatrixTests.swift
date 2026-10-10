import Foundation
import XCTest
@testable import EditorCore
import PhotoLibraryCore
import PresetCore
import RawProcessingCore

@MainActor
final class EyedropperRaceMatrixTests: XCTestCase {
    func testAuthoritativeRaceMatrixRejectsDelayedRelease() {
        let preset = PresetDocument(
            name: "Race preset",
            patch: AdjustmentPatch(basic: BasicAdjustmentPatch(exposure: 1))
        )
        let snapshot = EditSnapshot(name: "Race snapshot", adjustments: .neutral)
        let mutations: [(String, (EditorSession) -> Void)] = [
            ("A→B→A", { editor in
                editor.setAdjustment(.exposure, to: 1)
                editor.setAdjustment(.exposure, to: 0)
            }),
            ("reset", { $0.resetAdjustment(.exposure) }),
            ("preset", { $0.previewPreset(preset, mode: .merge) }),
            ("undo", { editor in
                editor.setAdjustment(.exposure, to: 1)
                editor.undo()
            }),
            ("redo", { editor in
                editor.setAdjustment(.exposure, to: 1)
                editor.undo()
                editor.redo()
            }),
            ("geometry", { editor in
                editor.updateAdjustments { $0.geometry.rotationDegrees = 90 }
            }),
            ("snapshot", { $0.createSnapshot(name: "new snapshot") }),
            ("preview options", { $0.setPreviewOptions(.init(showHighlightClipping: true)) }),
            ("comparison", { $0.setComparisonSnapshot(snapshot) }),
            ("valid to invalid baseline", { editor in
                editor.setWhiteBalanceBaselineForTesting(
                    RawWhiteBalanceBaseline(temperatureKelvin: .nan, tint: 0)
                )
            })
        ]

        for (label, mutation) in mutations {
            let editor = makeCandidate()
            mutation(editor)
            XCTAssertFalse(editor.commitEyedropper(), "delayed release must be rejected after \(label)")
            editor.close()
        }
    }

    private func makeCandidate() -> EditorSession {
        let editor = EditorSession()
        let photo = PhotoAsset(
            id: PhotoID(), libraryID: LibraryID(), relativePath: "fixture.ARW",
            fingerprint: FileFingerprint(fileSize: 4, edgeDigest: "fixture"), status: .ready
        )
        editor.open(
            photo: photo, sourceURL: URL(fileURLWithPath: "/tmp/fixture.ARW"),
            adjustments: .neutral, isReadOnly: false
        )
        editor.setWhiteBalanceBaselineForTesting(
            RawWhiteBalanceBaseline(temperatureKelvin: 5500, tint: 0)
        )
        editor.beginEyedropperForTesting()
        editor.previewEyedropper(sample: .init(red: 0.6, green: 0.5, blue: 0.4))
        XCTAssertTrue(editor.hasEyedropperPreview)
        return editor
    }
}
