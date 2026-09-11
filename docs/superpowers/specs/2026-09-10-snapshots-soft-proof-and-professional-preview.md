# Spec: Snapshots, Soft Proof, and Professional Preview (P6)

Date: 2026-09-11
Phase: P6
Status: In Progress

## 1. Executive Summary

Phase 6 implements professional previewing and snapshot management for LumaHarbor across macOS and iPadOS:
1. **Edit Snapshots**: Portable history milestones saved in `PhotoSidecar` (`currentSchemaVersion = 4`, per D-006). Support create, rename, duplicate, delete, and restore. Restoring a snapshot creates a single compound undo transaction.
2. **A/B Compare**: Session-level comparison between active adjustments and either the original baseline or a chosen snapshot. A/B toggling never mutates active adjustments and never writes to disk.
3. **Clipping & Gamut Overlays**: Real-time highlight clipping (red overlay for R/G/B >= 0.99), shadow clipping (blue overlay for R/G/B <= 0.01), and out-of-gamut warnings.
4. **Soft Proofing**: Color space simulation (e.g. sRGB, Display P3, AdobeRGB) with graceful fallback and clear disabled explanation if a color profile is unavailable.

## 2. Core Models & Persistence

### 2.1 EditSnapshot Model

```swift
public struct EditSnapshot: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var name: String
    public var adjustments: PhotoAdjustments
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        adjustments: PhotoAdjustments,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.adjustments = adjustments
        self.createdAt = createdAt
    }
}
```

### 2.2 PhotoSidecar Schema v4

- `PhotoSidecar.currentSchemaVersion = 4` (bumped from 3 per `DECISIONS.md` D-006).
- Added `public var snapshots: [EditSnapshot]`.
- Backward compatibility: v1, v2, v3 sidecars decode `snapshots` as empty array `[]`.
- Index rebuild and scan preserve snapshots alongside curation and adjustments.

### 2.3 Professional Preview Options

```swift
public struct ProfessionalPreviewOptions: Equatable, Sendable {
    public var showHighlightClipping: Bool = false
    public var showShadowClipping: Bool = false
    public var showGamutWarning: Bool = false
    public var softProofProfile: SoftProofProfile? = nil

    public var isActive: Bool {
        showHighlightClipping || showShadowClipping || showGamutWarning || softProofProfile != nil
    }
}

public enum SoftProofProfile: String, CaseIterable, Codable, Sendable {
    case sRGB = "sRGB"
    case displayP3 = "Display P3"
    case adobeRGB = "Adobe RGB"
}
```

## 3. Snapshot Workflow & Undo Contract

1. **Snapshot Creation**:
   - `createSnapshot(name:)` captures `history.current` adjustments.
   - Writes to sidecar without disturbing undo history.
2. **Snapshot Rename**:
   - Changes `name` in `snapshots` array.
3. **Snapshot Duplicate**:
   - Appends a copy with a new UUID and formatted name (e.g. `"Name Copy"`).
4. **Snapshot Deletion**:
   - Removes snapshot by UUID.
5. **Snapshot Restore**:
   - Restores adjustments to active editing session via single compound undo transaction (`updateAdjustments { $0 = snapshot.adjustments }`).
6. **A/B Compare**:
   - Switches preview state to render snapshot or baseline adjustments without modifying active adjustments or triggering autosave.

## 4. Professional Preview Overlay Pipeline

- Implemented via Core Image filter pipeline (`ProfessionalPreviewRenderer`):
  - **Highlight clipping**: Identifies pixels where any RGB channel exceeds 0.99; composites a pure red mask.
  - **Shadow clipping**: Identifies pixels where any RGB channel is below 0.01; composites a pure blue mask.
  - **Gamut warning**: Detects out-of-gamut saturated pixels for selected target color space; composites a pure yellow/magenta warning pattern.
  - **Soft Proof**: Applies color space conversion transform (`CIColorMatrix` or CGColorSpace transform).
- All preview overlays are transient view-state only, never baked into export files or written to sidecars.

## 5. UI Integration

- **Mac & iPad Snapshots Panel**:
  - Located in Inspector or dedicated sheet/popover.
  - Displays list of snapshots with creation dates and thumbnail/action menu (Restore, Duplicate, Rename, Delete).
  - Snapshot creation button with default timestamped name.
- **Mac & iPad Preview Toolbar / Menu**:
  - Toggles for Highlight Clipping, Shadow Clipping, Gamut Warning, and Soft Proof picker.
  - A/B Compare button (Active vs Original / Active vs Snapshot).
- **Localization**: Full 8-language support.

## 6. Verification & Test Plan

- `SnapshotModelTests`: Verify `EditSnapshot` serialization, name clamping, UUID preservation.
- `SidecarV4MigrationTests`: Verify v1, v2, v3, and v4 sidecar decoding and persistence.
- `SnapshotUndoContractTests`: Verify snapshot restoration is a single compound undo transaction.
- `ProfessionalPreviewFilterTests`: Verify highlight clipping, shadow clipping, gamut check, and soft proof output.
- `EightLanguageLocalizationGateTests`: Verify all P6 localization keys exist and pass parity checks.
