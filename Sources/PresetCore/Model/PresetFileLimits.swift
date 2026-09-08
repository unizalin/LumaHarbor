/// Upper bounds for user-supplied preset containers before JSON decoding.
///
/// These limits protect every file-backed entry point from allocating based on
/// an attacker-controlled file size. The backup limit is larger because one
/// archive may contain many presets and preserved XMP packets.
public enum PresetFileLimits {
    public static let maximumNativePresetBytes = 10 * 1024 * 1024
    public static let maximumBackupArchiveBytes = 64 * 1024 * 1024
}
