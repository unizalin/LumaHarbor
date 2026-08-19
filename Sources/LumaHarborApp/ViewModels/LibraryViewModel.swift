import AppKit
import Localization
import Combine
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
        let photosPart = indexedCount == 1
            ? L10n.t("1 photo")
            : "\(indexedCount) " + L10n.t("photos")
        if isFinished {
            return failedCount == 0
                ? photosPart
                : "\(photosPart), \(failedCount) " + L10n.t("skipped")
        }
        return "\(L10n.t("Scanning —")) \(indexedCount) " + L10n.t("found")
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
    @Published private(set) var photos: [PhotoAsset] = []

    /// Selection is read-only from the outside.
    ///
    /// Addendum §3.1: moving away from a photo has to flush its edits first,
    /// and that is asynchronous — a plain `didSet` can't hold the UI back until
    /// the sidecar is actually written. Views go through
    /// `requestSelectPhoto(_:)` / `requestSelectLibrary(_:)` (or the bindings
    /// below) instead, and the selection only changes once the write lands.
    @Published private(set) var selectedLibraryID: LibraryID?
    @Published private(set) var selectedPhotoID: PhotoID?
    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var exportState: ExportState?
    @Published private(set) var startupFailure: String?
    @Published var alert: UserAlert?
    @Published var isShowingExportSheet = false

    let editor = EditorViewModel()

    /// Views only ever hold `@EnvironmentObject var model: LibraryViewModel`
    /// and read `model.editor.*` through it — `editor` is never injected as its
    /// own environment object. Without this, `editor`'s own `@Published`
    /// mutations (a new photo opening, its preview arriving) never republish
    /// through `self`, so SwiftUI has nothing telling it to redraw: the
    /// inspector and preview pane show whatever editor state existed at the
    /// last unrelated `LibraryViewModel` publish, one selection behind.
    private var editorForwarding: AnyCancellable?

    private var services: AppServices?
    private var scanTask: Task<Void, Never>?
    private var exportTask: Task<Void, Never>?
    private var hasBootstrapped = false

    /// Only ever holds the most recent request: clicking three thumbnails
    /// quickly should land on the third, not walk through all of them.
    private var pendingSelection: SelectionRequest?
    private var isApplyingSelection = false

    /// Reading a sidecar is asynchronous, so a fast A→B can land B's selection
    /// while A's read is still out. The token is what lets a late read tell
    /// that it is answering a question nobody is asking any more.
    private var openTask: Task<Void, Never>?
    private var selectionGeneration: UInt64 = 0

    private enum SelectionRequest: Equatable {
        case photo(PhotoID?)
        case library(LibraryID?)
    }

    public init() {
        editorForwarding = editor.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }
    }

    private func install(services: AppServices) {
        self.services = services
        editor.attach(services: services)
        editor.onSaved = { [weak self] photoID, hasEdits in
            self?.updateEditBadge(photoID: photoID, hasEdits: hasEdits)
        }
    }

    /// Test seam: wires already-built services and reads current state from
    /// them, skipping the Application Support discovery `bootstrap()` does.
    ///
    /// Everything downstream — the flush-before-transition rule, the selection
    /// token, the edit badge — is the production code path; only where the
    /// services come from differs.
    func attachForTesting(services: AppServices) async {
        hasBootstrapped = true
        install(services: services)
        libraries = await services.libraryService.knownLibraries()
    }

    /// Test seam: loads the photo list for a library without going through a
    /// selection transition, so a test can set up state before exercising one.
    func selectForTesting(libraryID: LibraryID?) async {
        selectedLibraryID = libraryID
        selectedPhotoID = nil
        await reloadPhotos()
    }

    // MARK: - Selection

    /// Asks to open a photo. The change lands once the current photo's edits
    /// are safely on disk; if that write fails, the selection stays put.
    func requestSelectPhoto(_ photoID: PhotoID?) {
        guard photoID != selectedPhotoID else { return }
        enqueue(.photo(photoID))
    }

    func requestSelectLibrary(_ libraryID: LibraryID?) {
        guard libraryID != selectedLibraryID else { return }
        enqueue(.library(libraryID))
    }

    /// For `List(selection:)` and anything else that needs a two-way binding.
    var photoSelection: Binding<PhotoID?> {
        Binding(
            get: { [weak self] in self?.selectedPhotoID ?? nil },
            set: { [weak self] in self?.requestSelectPhoto($0) }
        )
    }

    var librarySelection: Binding<LibraryID?> {
        Binding(
            get: { [weak self] in self?.selectedLibraryID ?? nil },
            set: { [weak self] in self?.requestSelectLibrary($0) }
        )
    }

    private func enqueue(_ request: SelectionRequest) {
        pendingSelection = request
        guard !isApplyingSelection else { return }
        isApplyingSelection = true
        Task { [weak self] in
            await self?.applyPendingSelections()
        }
    }

    /// Serialised on purpose: two overlapping transitions could each flush the
    /// same dirty edit, or worse, commit out of order.
    private func applyPendingSelections() async {
        defer { isApplyingSelection = false }

        while let request = pendingSelection {
            pendingSelection = nil

            // Addendum §3.1: the edit reaches the sidecar before the UI moves on.
            guard await editor.flushPendingEdits() else {
                // The editor has already raised an actionable error. Stay
                // exactly where we are — including dropping queued requests,
                // since the user needs to deal with this before navigating.
                pendingSelection = nil
                return
            }

            switch request {
            case .photo(let photoID):
                commitPhotoSelection(photoID)
            case .library(let libraryID):
                commitLibrarySelection(libraryID)
            }
        }
    }

    /// Keeps the grid badge in step with what was just written. Resetting a
    /// photo back to neutral clears it again, which is why this takes the flag
    /// rather than only ever setting it.
    private func updateEditBadge(photoID: PhotoID, hasEdits: Bool) {
        guard let index = photos.firstIndex(where: { $0.id == photoID }),
              photos[index].hasEdits != hasEdits else { return }
        photos[index].hasEdits = hasEdits
    }

    private func commitPhotoSelection(_ photoID: PhotoID?) {
        guard photoID != selectedPhotoID else { return }
        selectedPhotoID = photoID
        handlePhotoSelectionChange()
    }

    private func commitLibrarySelection(_ libraryID: LibraryID?) {
        guard libraryID != selectedLibraryID else { return }
        selectedLibraryID = libraryID
        selectedPhotoID = nil
        handleLibrarySelectionChange()
    }

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
            install(services: services)
            // Spec §7: resolve every saved bookmark and re-take its scope.
            libraries = try await services.libraryService.restoreLibraries()
            if selectedLibraryID == nil {
                // Nothing is open yet, so there is no edit to flush.
                commitLibrarySelection(
                    libraries.first(where: { $0.isOnline })?.id ?? libraries.first?.id
                )
            }
        } catch {
            startupFailure = (error as? LocalizedError)?.errorDescription
                ?? (error as NSError).localizedDescription
            alert = UserAlert(title: L10n.t("LumaHarbor couldn't start up"), error: error)
        }
    }

    // MARK: - Libraries

    func presentAddFolderPanel() {
        let panel = NSOpenPanel()
        panel.title = L10n.t("Choose a photo folder")
        panel.message = L10n.t("Pick the folder on your drive that holds your RAW files.")
        panel.prompt = L10n.t("Add Folder")
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
            requestSelectLibrary(folder.id)
            startScan(libraryID: folder.id)
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't add that folder"), error: error)
        }
    }

    /// Spec §7: when a bookmark no longer resolves, the user re-picks the folder
    /// and the library keeps its identity — and therefore its edits.
    func presentRelinkPanel(for libraryID: LibraryID) {
        guard let library = libraries.first(where: { $0.id == libraryID }) else { return }
        let panel = NSOpenPanel()
        panel.title = "\(L10n.t("Reconnect")) \(library.displayName)"
        panel.message = L10n.t("Choose the folder again to restore access to your photos.")
        panel.prompt = L10n.t("Reconnect")
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
            alert = UserAlert(title: L10n.t("Couldn't reconnect that folder"), error: error)
        }
    }

    func removeLibrary(_ libraryID: LibraryID) async {
        guard let services else { return }

        // Removing the folder the user is editing in takes the sidecar's
        // destination with it, so a pending edit has to land first. A failed
        // flush cancels the removal outright: losing the edit is far worse than
        // leaving the folder in the list, and the editor has already put an
        // actionable error on screen.
        if selectedLibraryID == libraryID {
            guard await editor.flushPendingEdits() else { return }
        }

        do {
            try await services.libraryService.removeLibrary(id: libraryID)
            libraries = await services.libraryService.knownLibraries()
            if selectedLibraryID == libraryID {
                // Safe to drop history now — it is already on disk.
                editor.close()
                commitLibrarySelection(libraries.first?.id)
            }
        } catch {
            alert = UserAlert(title: L10n.t("Couldn't remove that folder"), error: error)
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

    /// Runs after `commitLibrarySelection` has already cleared the photo
    /// selection — by this point any dirty edit has been flushed.
    private func handleLibrarySelectionChange() {
        // A pending open belongs to the folder we just left.
        invalidateOpenTask()
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
                            title: L10n.t("Scanned, but couldn't update the library file"),
                            message: failure,
                            nextStep: L10n.t("Your photos are still browsable.")
                                + " " + L10n.t("Unlock the drive to save changes back to it.")
                        )
                    }

                case .failed(let error):
                    self.alert = UserAlert(title: L10n.t("Scan problem"), error: error)
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
            alert = UserAlert(title: L10n.t("Couldn't read the local index"), error: error)
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

    /// Invalidates any in-flight photo open and hands back the token the next
    /// one should carry.
    @discardableResult
    private func invalidateOpenTask() -> UInt64 {
        openTask?.cancel()
        openTask = nil
        selectionGeneration += 1
        return selectionGeneration
    }

    private func handlePhotoSelectionChange() {
        let generation = invalidateOpenTask()

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
                title: L10n.t("This drive isn't connected"),
                message: L10n.t("LumaHarbor can show cached thumbnails, but editing needs the original file."),
                nextStep: L10n.t("Reconnect the drive, then try again.")
            )
            return
        }

        openTask = Task { [weak self] in
            guard let self, let services else { return }
            let url = photo.url(inLibraryRootedAt: library.rootURL)

            let loaded: Result<PhotoAdjustments, Error>
            do {
                loaded = .success(try await services.loadAdjustments(photo))
            } catch {
                loaded = .failure(error)
            }

            // The user may have moved on while the sidecar was being read. The
            // token *and* the current selection are both checked: a late read
            // must not open the photo they left, and must not drop its error
            // on top of the one they're looking at now either.
            guard !Task.isCancelled,
                  self.selectionGeneration == generation,
                  self.selectedPhotoID == photo.id,
                  self.selectedLibraryID == library.id else { return }

            switch loaded {
            case .success(let adjustments):
                self.editor.open(
                    photo: photo,
                    sourceURL: url,
                    adjustments: adjustments,
                    isReadOnly: !library.isWritable
                )
            case .failure(let error):
                // Spec §10: a damaged sidecar is reported, never silently
                // replaced. Open at neutral so the photo is still viewable.
                self.editor.open(
                    photo: photo,
                    sourceURL: url,
                    adjustments: .neutral,
                    isReadOnly: !library.isWritable
                )
                self.alert = UserAlert(title: L10n.t("Couldn't read saved edits"), error: error)
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
            requestSelectPhoto(photos.first?.id)
            return
        }
        let next = index + offset
        guard photos.indices.contains(next) else { return }
        requestSelectPhoto(photos[next].id)
    }

    // MARK: - Export

    func presentExportPanel(quality: Double) {
        guard let photo = selectedPhoto else { return }
        let panel = NSOpenPanel()
        panel.title = L10n.t("Export JPEG")
        panel.message = L10n.t("Choose where to save the exported photo.")
        panel.prompt = L10n.t("Export Here")
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
                self?.alert = UserAlert(title: L10n.t("Export failed"), error: error)
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
