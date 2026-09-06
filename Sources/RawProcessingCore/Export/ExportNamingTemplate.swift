import Foundation
import Localization

/// How an export's base filename (extension excluded -- `PhotoExporter`
/// appends that from `ExportRequest.format`) is built from what LumaHarbor
/// already knows about the photo being exported (design spec §6.11:
/// "重新命名規則:原檔名、序號、日期、preset name、virtual copy name";
/// roadmap Phase 5 Task 5.2).
///
/// Each case names one token from that list rather than offering a
/// free-form template string: every combination is a fixed, reviewable,
/// independently testable function, and the Mac export UI can offer them
/// as a plain picker without a template-syntax editor. `.originalFilename`
/// is `.default`, so exporting without touching this option reproduces
/// exactly what every export did before this option existed.
public enum ExportNamingTemplate: String, CaseIterable, Equatable, Sendable {
    case originalFilename
    case originalFilenameWithSequence
    case dateAndOriginalFilename
    case presetNameAndOriginalFilename
    case originalFilenameWithVirtualCopyName

    public static let `default`: ExportNamingTemplate = .originalFilename

    public var displayName: String {
        switch self {
        case .originalFilename:
            return L10n.t("Original Filename")
        case .originalFilenameWithSequence:
            return L10n.t("Original Filename + Sequence")
        case .dateAndOriginalFilename:
            return L10n.t("Date + Original Filename")
        case .presetNameAndOriginalFilename:
            return L10n.t("Preset Name + Original Filename")
        case .originalFilenameWithVirtualCopyName:
            return L10n.t("Original Filename + Copy Name")
        }
    }

    /// Everything a template might need. Any field a given template doesn't
    /// use is simply ignored; a field a template needs but that came back
    /// `nil`/empty (no capture date, no preset applied, not a virtual copy)
    /// falls back to the plain original filename rather than fabricating a
    /// value -- e.g. `dateAndOriginalFilename` never substitutes today's
    /// date for a missing capture date, since that would misrepresent when
    /// the photo was actually taken.
    public struct Context: Equatable, Sendable {
        public var originalFilename: String
        /// 1-based position within the export run this file is part of
        /// (always `1` for a single-photo export).
        public var sequence: Int
        public var date: Date?
        public var presetName: String?
        public var virtualCopyName: String?

        public init(
            originalFilename: String,
            sequence: Int = 1,
            date: Date? = nil,
            presetName: String? = nil,
            virtualCopyName: String? = nil
        ) {
            self.originalFilename = originalFilename
            self.sequence = sequence
            self.date = date
            self.presetName = presetName
            self.virtualCopyName = virtualCopyName
        }
    }

    public func render(_ context: Context) -> String {
        switch self {
        case .originalFilename:
            return context.originalFilename
        case .originalFilenameWithSequence:
            return "\(context.originalFilename)_\(Self.sequenceFormatter.string(for: context.sequence))"
        case .dateAndOriginalFilename:
            let datePart = context.date.map { Self.dateFormatter.string(from: $0) } ?? "NoDate"
            return "\(datePart)_\(context.originalFilename)"
        case .presetNameAndOriginalFilename:
            guard let preset = context.presetName, !preset.isEmpty else { return context.originalFilename }
            return "\(preset)_\(context.originalFilename)"
        case .originalFilenameWithVirtualCopyName:
            guard let copy = context.virtualCopyName, !copy.isEmpty else { return context.originalFilename }
            return "\(context.originalFilename)_\(copy)"
        }
    }

    /// `yyyy-MM-dd`, timezone-independent (`en_US_POSIX`, matching every
    /// other fixed-format date parser/formatter in this module -- see
    /// `ExportMetadataBuilder`'s own EXIF date formatter for the same
    /// reasoning) so the same capture instant always renders the same
    /// filename regardless of the machine's locale.
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    /// At least 3 digits, never truncated for a batch past 999 files.
    private static let sequenceFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.minimumIntegerDigits = 3
        formatter.usesGroupingSeparator = false
        return formatter
    }()
}

private extension NumberFormatter {
    func string(for value: Int) -> String {
        string(from: NSNumber(value: value)) ?? String(value)
    }
}
