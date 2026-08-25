import Foundation
import PackagePlugin

/// Compiles the `.metal` Core Image kernels in a target into a single
/// `CoreImageKernels.metallib`, since SwiftPM's own CLI build (`swift build`/`swift
/// test`) — unlike an Xcode-driven build of the same package — does not
/// automatically compile `.metal` sources. The non-default filename avoids
/// colliding with Xcode's automatic MetalLink `default.metallib` output.
/// `-fcikernel`/`-cikernel` (not
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
        let metalFiles = metalFiles(in: module.directory.appending(subpath: "Kernels"))
        guard !metalFiles.isEmpty else { return [] }

        let workDirectory = context.pluginWorkDirectory
        let intermediatesDirectory = workDirectory.appending(subpath: "air")
        let metallibFile = workDirectory.appending(subpath: "CoreImageKernels.metallib")

        // A single shell command rather than a compile-then-link pair of
        // build commands: the intermediate .air files only need to exist
        // long enough for `metallib` to read them, and any path listed in a
        // command's `outputFiles` gets swept into the target's resource
        // bundle alongside CoreImageKernels.metallib (verified by inspecting the
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

    private func metalFiles(in directory: Path) -> [Path] {
        guard let enumerator = FileManager.default.enumerator(atPath: directory.string) else { return [] }

        return enumerator
            .compactMap { item -> Path? in
                guard let relativePath = item as? String, relativePath.hasSuffix(".metal") else { return nil }
                return directory.appending(subpath: relativePath)
            }
            .sorted { $0.string < $1.string }
    }

    private func shellQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
