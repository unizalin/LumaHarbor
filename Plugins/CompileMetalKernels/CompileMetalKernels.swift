import Foundation
import PackagePlugin

/// Compiles the `.metal` Core Image kernels in a target into a single
/// `default.metallib`, since SwiftPM's own CLI build (`swift build`/`swift
/// test`) — unlike an Xcode-driven build of the same package — does not
/// automatically compile `.metal` sources. `-fcikernel`/`-cikernel` (not
/// `[[stitchable]]`) is what actually produces a metallib whose functions
/// `CIKernel(functionName:fromMetalLibraryData:)` can find: verified by
/// hand, `[[stitchable]]` alone compiles but the linker treats every
/// coreimage kernel function as dead code and strips it, and dropping
/// `-cikernel` on the link step leaves `coreimage::sampler`'s methods
/// unresolved since Core Image supplies them at runtime, not at link time.
@main
struct CompileMetalKernelsPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        guard let module = target as? SourceModuleTarget else { return [] }
        let metalFiles = module.sourceFiles(withSuffix: "metal").map(\.path)
        guard !metalFiles.isEmpty else { return [] }

        let workDirectory = context.pluginWorkDirectory
        let intermediatesDirectory = workDirectory.appending(subpath: "air")
        let metallibFile = workDirectory.appending(subpath: "default.metallib")

        // A single shell command rather than a compile-then-link pair of
        // build commands: the intermediate .air files only need to exist
        // long enough for `metallib` to read them, and any path listed in a
        // command's `outputFiles` gets swept into the target's resource
        // bundle alongside default.metallib (verified by inspecting the
        // built .bundle) -- keeping them out of `outputFiles` keeps the air
        // intermediates out of the shipped resource bundle.
        let script = """
        set -e
        mkdir -p \(shellQuote(intermediatesDirectory.string))
        AIR_FILES=""
        for f in \(metalFiles.map { shellQuote($0.string) }.joined(separator: " ")); do
            base=$(basename "$f" .metal)
            air=\(shellQuote(intermediatesDirectory.string))/"$base".air
            xcrun metal -fcikernel -c "$f" -o "$air"
            AIR_FILES="$AIR_FILES $air"
        done
        xcrun metallib -cikernel $AIR_FILES -o \(shellQuote(metallibFile.string))
        """

        return [
            .buildCommand(
                displayName: "Compile and link Core Image Metal kernels for \(module.name)",
                executable: Path("/bin/sh"),
                arguments: ["-c", script],
                inputFiles: metalFiles,
                outputFiles: [metallibFile]
            )
        ]
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
