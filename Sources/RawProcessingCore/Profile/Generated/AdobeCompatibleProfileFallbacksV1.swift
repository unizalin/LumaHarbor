import Foundation

/// Generated coefficients are intentionally empty until a legal paired
/// Lightroom reference corpus passes the v1 hold-out gate. Keeping the lookup
/// explicit prevents a preserved profile name from silently becoming a fake
/// Adobe render.
public enum AdobeCompatibleProfileFallbacksV1 {
    public static let all: [CameraProfileFallback] = []

    public static func fallback(for id: String) -> CameraProfileFallback? {
        all.first { $0.id == id }
    }
}
