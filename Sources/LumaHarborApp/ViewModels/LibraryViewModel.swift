import AppKit
import Foundation
import PhotoLibraryCore
import RawProcessingCore
import SwiftUI

struct ScanProgress: Equatable {
    var libraryID: LibraryID
    var indexedCount: Int
    var failedCount: Int
    var isFinished: Bool

    var summary: String {
        if isFinished {
            return failedCount == 0
                ? "\(indexedCount) photos"
                : "\(indexedCount) photos, \(failedCount) skipped"
        }
        return "Scanning — \(indexedCount) found"
    }
}

struct ExportState: Equatable {
    var photoID: PhotoID
    var filename: String
    var isFinished: Bool
    var resultPath: String?
}

/// Owns library-level state: which folders exist, which photos are in them, and
/// which photo is open.
@MainActor
public final class LibraryViewModel: ObservableObject {
    @Published private(set) var libraries: [LibraryFolder] = []
    @Published var selectedLibraryID: LibraryID? {
        didSet {
            guard oldValue != selectedLibraryID else { return }
            handleLibrarySelectionChange()
        }
    }
    @Published private(set) var photos: [PhotoAsset] = []
    @Published var selectedPhotoID: PhotoID? {
        didSet {
            guard oldValue != selectedPhotoID else { return }
            handlePhotoSelectionChange()
        }
    }
    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var exportState: ExportState?
    @Published private(set) var startupFailure: String?
    @Published var alert: UserAlert?
    @Published var isShowingExportSheet = false

    let editor = EditorViewModel()

    private var services: AppServices?
    private var scanTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var hasBootstrapped = false

    public init() {}

    var selectedLibrary: LibraryFolder? {
        guard let selectedLibraryID else { return nil }
        return libraries.first { $0.id == selectedLibraryID }
    }

    var selectedPhoto: PhotoAsset? {
        guard let selectedPhotoID else { return nil }
        return photos.first { $0.id == selectedPhotoID }
    }

    var isExporting: Bool {
        guard let exportState else { return false }
        return !exportState.isFinished
    }

    var thumbnailProvider: ThumbnailProvider? { services?.thumbnailProvider }

    // MARK: - Startup

    func bootstrap() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true

        do {
            let services = try AppServices.makeDefault()
            self.services = services
            editor.attach(services: services)
            // Spec §7: resolve every saved bookmark and re-take its scope.
            libraries = try await services.libraryService.restoreLibraries()
            if selectedLibraryID == nil {
                selectedLibraryID = libraries.first(where: { $0.isOnline })?.id ?? libraries.first?.id
            }
        } catch {
            startupFailure = (error as? LocalizedError)?.errorDescription
                ?? (error as NSError).localizedDescription
            alert = UserAlert(title: "LumaHarbor couldn't start up", error: error)
        }
    }

    // MARK: - Libraries

    func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = "Choose a photo folder"
        panel.message = "Pick the folder on your drive that holds your RAW files."
        panel.prompt = "Add Folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await addLibrary(at: url) }
    }

    func addLibrary(at url: URL) async {
        guard let services else { return }
        do {
            let folder = try await services.libraryService.addLibrary(at: url)
            libraries = await services.libraryService.knownLibraries()
            selectedLibraryID = folder.id
            startScan(libraryID: folder.id)
        } catch {
            alert = UserAlert(title: "Couldn't add that folder", error: error)
        }
    }

    /// Spec §7: when a bookmark no longer resolves, the user re-picks the folder
    /// and the library keeps its identity — and therefore its edits.
    func presentRelinkPanel(for libraryID: LibraryID) {
        guard let library = libraries.first(where: { $0.id == libraryID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "Reconnect \(library.displayName)"
        panel.message = "Choose the folder again to restore access to your photos."
        panel.prompt = "Reconnect"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await relink(libraryID: libraryID, to: url) }
    }

    func relink(libraryID: LibraryID, to url: URL) async {
        guard let services else { return }
        do {
            _ = try await services.libraryService.relink(libraryID: libraryID, to: url)
            libraries = await services.libraryService.knownLibraries()
            await reloadPhotos()
            startScan(libraryID: libraryID)
            editor.retrySaveAfterReconnect(
                isReadOnly: !(libraries.first { $0.id == libraryID }?.isWritable ?? false)
            )
        } catch {
            alert = UserAlert(title: "Couldn't reconnect that folder", error: error)
        }
    }

    func removeLibrary(_ libraryID: LibraryID) async {
        guard let services else { return }
        do {
            try await services.libraryService.removeLibrary(id: libraryID)
            libraries = await services.libraryService.knownLibraries()
            if selectedLibraryID == libraryID {
                selectedLibraryID = libraries.first?.id
            }
        } catch {
            alert = UserAlert(title: "Couldn't remove that folder", error: error)
        }
    }

    /// Re-checks whether the drive is still mounted. Called on window focus and
    /// after a failed operation, which is how "SSD unplugged" surfaces.
    func refreshAvailability() async {
        guard let services, let selectedLibraryID else { return }
        guard let updated = try? await services.libraryService
            .refreshAvailability(libraryID: selectedLibraryID) else { return }
        if let index = libraries.firstIndex(where: { $0.id == updated.id }) {
            libraries[index] = updated
        }
        editor.retrySaveAfterReconnect(isReadOnly: !updated.isWritable)
    }

    private func handleLibrarySelectionChange() {
        selectedPhotoID = nil
        editor.close()
        scanTask?.cancel()
        scanProgress = nil
        Task {
            await reloadPhotos()
            if let selectedLibraryID,
               let library = libraries.first(where: { $0.id == selectedLibraryID }),
               library.isOnline,
               library.lastScanAt == nil {
                startScan(libraryID: selectedLibraryID)
            }
        }
    }

    // MARK: - Scanning

    func startScan(libraryID: LibraryID? = nil) {
        guard let services else { return }
        guard let target = libraryID ?? selectedLibraryID else { return }

        scanTask?.cancel()
        scanProgress = ScanProgress(
            libraryID: target, indexedCount: 0, failedCount: 0, isFinished: false
        )

        scanTask = Task { [weak self] in
            for await event in services.libraryService.scan(libraryID: target) {
                guard !Task.isCancelled else { return }
                guard let self else { return }

                switch event {
                case .started:
                    continue

                case .photosIndexed(let batch):
                    // Spec §6.1: grow the grid as results arrive rather than
                    // blocking on the whole folder.
                    self.mergePhotos(batch)
                    self.scanProgress?.indexedCount += batch.count

                case .photoFailed:
                    self.scanProgress?.failedCount += 1

                case .finished(let result):
                    self.scanProgress?.indexedCount = result.indexedCount
                    self.scanProgress?.failedCount = result.failedCount
                    self.scanProgress?.isFinished = true
                    self.libraries = await services.libraryService.knownLibraries()
                    await self.reloadPhotos()
                    if let failure = result.manifestWriteFailure {
                        self.alert = UserAlert(
                            title: "Scanned, but couldn't update the library file",
                            message: failure,
                            nextStep: "Your photos are still browsable. "
                                + "Unlock the drive to save changes back to it."
                        )
                    }

                case .failed(let error):
                    self.alert = UserAlert(title: "Scan problem", error: error)
                }
            }
        }
    }

    func cancelScan() {
        scanTask?.cancel()
        scanTask = nil
        scanProgress?.isFinished = true
    }

    private func mergePhotos(_ batch: [PhotoAsset]) {
        var byID = Dictionary(uniqueKeysWithValues: photos.map { ($0.id, $0) })
        for photo in batch {
            byID[photo.id] = photo
        }
        photos = byID.values.sorted(by: Self.displayOrder)
    }

    private func reloadPhotos() async {
        guard let services, let selectedLibraryID else {
            photos = []
            return
        }
        do {
            photos = try await services.libraryService
                .photos(inLibrary: selectedLibraryID)
                .sorted(by: Self.displayOrder)
        } catch {
            photos = []
            alert = UserAlert(title: "Couldn't read the local index", error: error)
        }
    }

    /// Capture time when known, filename otherwise, so a folder of files with no
    /// EXIF still has a stable order.
    private static func displayOrder(_ lhs: PhotoAsset, _ rhs: PhotoAsset) -> Bool {
        switch (lhs.metadata.captureDate, rhs.metadata.captureDate) {
        case let (left?, right?) where left != right:
            return left < right
        default:
            return lhs.relativePath.localizedStandardCompare(rhs.relativePath) == .orderedAscending
        }
    }

    // MARK: - Photo selection

    private func handlePhotoSelectionChange() {
        guard let selectedPhotoID else {
            editor.close()
            return
        }
        guard let photo = photos.first(where: { $0.id == selectedPhotoID }),
              let library = selectedLibrary else { return }

        guard library.isOnline else {
            // Spec §10: offline libraries stay browsable, but the editor needs
            // the original file.
            editor.close()
            alert = UserAlert(
                title: "This drive isn't connected",
                message: "LumaHarbor can show cached thumbnails, but editing needs the original file.",
                nextStep: "Reconnect the drive, then try again."
            )
            return
        }

        Task { [weak self] in
            guard let self, let services else { return }
            let url = photo.url(inLibraryRootedAt: library.rootURL)
            do {
                let adjustments = try await services.libraryService.adjustments(for: photo)
                self.editor.open(
                    photo: photo,
                    sourceURL: url,
                    adjustments: adjustments,
                    isReadOnly: !library.isWritable
                )
            } catch {
                // Spec §10: a damaged sidecar is reported, never silently
                // replaced. Open at neutral so the photo is still viewable.
                self.editor.open(
                    photo: photo,
                    sourceURL: url,
                    adjustments: .neutral,
                    isReadOnly: !library.isWritable
                )
                self.alert = UserAlert(title: "Couldn't read saved edits", error: error)
            }
        }
    }

    func selectNextPhoto() {
        movePhotoSelection(by: 1)
    }

    func selectPreviousPhoto() {
        movePhotoSelection(by: -1)
    }

    private func movePhotoSelection(by offset: Int) {
        guard !photos.isEmpty else { return }
        guard let current = selectedPhotoID,
              let index = photos.firstIndex(where: { $0.id == current }) else {
            selectedPhotoID = photos.first?.id
            return
        }
        let next = index + offset
        guard photos.indices.contains(next) else { return }
        selectedPhotoID = photos[next].id
    }

    // MARK: - Export

    func presentExportPanel(quality: Double) {
        guard let photo = selectedPhoto else { return }
        let panel = NSOpenPanel()
        panel.title = "Export JPEG"
        panel.message = "Choose where to save the exported photo."
        panel.prompt = "Export Here"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let directory = panel.url else { return }
        export(photo: photo, to: directory, quality: quality)
    }

    func export(photo: PhotoAsset, to directory: URL, quality: Double) {
        guard let services, let library = selectedLibrary else { return }

        exportTask?.cancel()
        exportState = ExportState(
            photoID: photo.id,
            filename: photo.baseFilename,
            isFinished: false,
            resultPath: nil
        )

        let request = ExportRequest(
            sourceURL: photo.url(inLibraryRootedAt: library.rootURL),
            adjustments: editor.adjustments,
            destinationDirectory: directory,
            baseFilename: photo.baseFilename,
            jpegQuality: quality
        )

        exportTask = Task { [weak self] in
            do {
                let outcome = try await services.exporter.export(request)
                guard !Task.isCancelled else { return }
                self?.exportState = ExportState(
                    photoID: photo.id,
                    filename: outcome.url.lastPathComponent,
                    isFinished: true,
                    resultPath: outcome.url.path
                )
            } catch is CancellationError {
                self?.exportState = nil
            } catch {
                guard !Task.isCancelled else { return }
                self?.exportState = nil
                self?.alert = UserAlert(title: "Export failed", error: error)
            }
        }
    }

    /// Spec §6.3: a cancelled export removes its partial output.
    func cancelExport() {
        exportTask?.cancel()
        exportTask = nil
        exportState = nil
    }

    func revealExportInFinder() {
        guard let path = exportState?.resultPath else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
