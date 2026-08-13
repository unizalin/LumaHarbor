import Foundation
import PhotoLibraryCore
import RawProcessingCore

/// Everything the UI layer needs, wired once at launch.
///
/// The app target owns composition but not behaviour: it never builds a
/// `CIRAWFilter`, never parses a sidecar and never touches SQLite directly
/// (spec §5.1).
struct AppServices {
    let locations: ApplicationSupportLocations
    let libraryService: PhotoLibraryService
    let thumbnailProvider: ThumbnailProvider
    let previewScheduler: PreviewScheduler
    let exporter: JPEGExporter
    let decoder: any RawDecoding
    let renderService: ImageRenderService
    let previewRenderer: CoreImagePreviewRenderer

    static func makeDefault() throws -> AppServices {
        let locations = try ApplicationSupportLocations.standard()
        try locations.createDirectories()

        let decoder = CoreImageRawDecoder()
        let renderService = ImageRenderService()
        let pipeline = AdjustmentPipeline()

        let thumbnailCache = try DiskCache(
            directoryURL: locations.thumbnailCacheURL,
            byteBudget: CacheBudget.thumbnails
        )
        let previewRenderer = CoreImagePreviewRenderer(
            decoder: decoder,
            pipeline: pipeline,
            renderService: renderService
        )

        return AppServices(
            locations: locations,
            libraryService: try PhotoLibraryService(locations: locations, decoder: decoder),
            thumbnailProvider: ThumbnailProvider(
                cache: thumbnailCache,
                decoder: decoder,
                pipeline: pipeline,
                renderService: renderService
            ),
            previewScheduler: PreviewScheduler(renderer: previewRenderer),
            exporter: JPEGExporter(
                decoder: decoder,
                pipeline: pipeline,
                renderService: renderService
            ),
            decoder: decoder,
            renderService: renderService,
            previewRenderer: previewRenderer
        )
    }
}

/// Spec §8.3 sets a 10 GiB default ceiling for the whole cache directory; this
/// is how it is divided.
enum CacheBudget {
    static let total = LRUEvictionPlanner.defaultByteBudget
    static let thumbnails = total / 4
    static let previews = total - thumbnails
}

/// An error shaped for presentation: what happened, and what to do next.
///
/// Spec §10 requires every user-actionable error to carry its next step, so the
/// UI can't display one without one.
struct UserAlert: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var message: String
    var nextStep: String?

    init(title: String, message: String, nextStep: String? = nil) {
        self.title = title
        self.message = message
        self.nextStep = nextStep
    }

    init(title: String, error: Error) {
        self.title = title
        if let localized = error as? LocalizedError {
            self.message = localized.errorDescription ?? String(describing: error)
            self.nextStep = localized.recoverySuggestion
        } else {
            self.message = (error as NSError).localizedDescription
            self.nextStep = nil
        }
    }
}
