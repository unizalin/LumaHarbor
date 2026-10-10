#!/usr/bin/env python3
"""Compare untimed production preview and direct R8 for the shared ABBA inputs.

Archives immutable B/O commits into fresh directories. Only the baseline
testability patch, shared test harness, and a test-only baseline byte wrapper
are injected. Never edits the source checkout or timed ABBA artifacts.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

PARITY_TEST = r'''
    func testOptInABBAOutputParity() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let output = environment["LUMAHARBOR_BRUSH_PARITY_OUTPUT"] else {
            throw XCTSkip("untimed ABBA output parity is opt-in")
        }
        let directory = URL(fileURLWithPath: output, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let extent = CGRect(x: 0, y: 0, width: 1600, height: 1067)
        var manifest = [[String: Any]]()
        for scenario in ["cold", "warm", "changed", "appended", "stress"] {
            for maskCount in [0, 1, 10] {
                for ordinal in (scenario == "changed" ? [0, 1] : [0]) {
                    let inputs = makeInputs(scenario: scenario, maskCount: maskCount, sampleOrdinal: ordinal)
                    let key = "\(scenario)-m\(maskCount)-o\(ordinal)"
                    let renderer = CoreImagePreviewRenderer(
                        decoder: SyntheticRawDecoder(pixelSize: extent.size),
                        renderService: ImageRenderService(preferMetal: true)
                    )
                    func request(_ adjustments: PhotoAdjustments) -> PreviewRequest {
                        PreviewRequest(
                            subject: PreviewSubject(UUID(uuidString: "00000000-0000-4000-8000-000000000001")!),
                            url: URL(fileURLWithPath: "/tmp/brush-abba-synthetic.raw"),
                            adjustments: adjustments, targetPixelDimension: 1600, quality: .interactive
                        )
                    }
                    if let warmup = inputs.warmup { _ = try await renderer.render(request(warmup)) }
                    let rendered = try await renderer.render(request(inputs.timed))
                    let image = rendered.cgImage
                    let width = image.width, height = image.height
                    let colorSpace = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
                    var pixels = Data(count: width * height * 4)
                    try pixels.withUnsafeMutableBytes { storage in
                        let context = try XCTUnwrap(CGContext(
                            data: storage.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
                        ))
                        context.setBlendMode(.copy)
                        context.interpolationQuality = .none
                        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
                    }
                    let previewFile = key + ".rgba8"
                    try pixels.write(to: directory.appendingPathComponent(previewFile))
                    manifest.append(["file": previewFile, "kind": "previewRGBA8", "width": width, "height": height, "channels": 4])
                    let mapping = try GeometryRenderer.brushCoordinateMapping(sourceExtent: extent, geometry: inputs.timed.geometry)
                        ?? BrushCoordinateMapping(sourceExtent: extent, geometry: .neutral)
                    for (index, mask) in inputs.timed.brushMasks.enumerated() {
                        let bytes = try BrushMaskRenderer._testRenderCoverageBytes(mask, imageExtent: extent, mapping: mapping)
                        let filename = key + "-mask\(index).r8"
                        try bytes.write(to: directory.appendingPathComponent(filename))
                        manifest.append(["file": filename, "kind": "coverageR8", "width": 1600, "height": 1067, "channels": 1])
                    }
                }
            }
        }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: directory.appendingPathComponent("manifest.json"))
        XCTAssertEqual(manifest.filter { $0["kind"] as? String == "previewRGBA8" }.count, 18)
        XCTAssertEqual(manifest.filter { $0["kind"] as? String == "coverageR8" }.count, 66)
    }
'''

def run(command, **kwargs):
    return subprocess.run(command, check=True, **kwargs)

def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def capture_summary(path):
    summaries = re.findall(
        r'Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures?',
        path.read_text(),
    )
    normalized = [(int(executed), int(skipped or 0), int(failures)) for executed, skipped, failures in summaries]
    if (1, 0, 0) not in normalized:
        raise RuntimeError(f'expected one executed parity test in {path}')
    return {'exit': 0, 'executed': 1, 'skipped': 0, 'failures': 0}

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--repo', required=True)
    ap.add_argument('--candidate', required=True)
    ap.add_argument('--baseline', default='1de07dcfeb2ed217a75d1c04978da6a5936f379a')
    ap.add_argument('--run-root', required=True)
    args = ap.parse_args()
    repo, root = Path(args.repo).resolve(), Path(args.run_root).resolve()
    def resolve_commit(ref):
        return subprocess.check_output(
            ['git', '-C', str(repo), 'rev-parse', '--verify', f'{ref}^{{commit}}'],
            text=True,
        ).strip()
    baseline_sha = resolve_commit(args.baseline)
    candidate_sha = resolve_commit(args.candidate)
    root.mkdir(parents=True, exist_ok=False)
    harness_path = 'Tests/RawProcessingCoreTests/BrushPreviewABBAHarnessTests.swift'
    renderer_path = 'Sources/RawProcessingCore/Pipeline/BrushMaskRenderer.swift'
    def source(sha, path):
        return subprocess.check_output(['git', '-C', str(repo), 'show', f'{sha}:{path}'], text=True)
    harness = source(candidate_sha, harness_path)
    harness = harness.replace('    func testOptInProductionPreviewSample()', PARITY_TEST + '\n    func testOptInProductionPreviewSample()', 1)
    assert 'func testOptInABBAOutputParity' in harness
    patch = source(candidate_sha, 'Scripts/fixtures/brush-baseline-release-testability.patch')
    metadata = {}
    capture_tests = {}
    for variant, sha in [('B', baseline_sha), ('O', candidate_sha)]:
        checkout = root / variant
        checkout.mkdir()
        archive = root / (variant + '.tar')
        with archive.open('wb') as stream:
            run(['git', '-C', str(repo), 'archive', sha], stdout=stream)
        run(['tar', '-xf', str(archive), '-C', str(checkout)])
        if variant == 'B':
            run(['patch', '-s', '-p1', '-d', str(checkout)], input=patch, text=True)
            path = checkout / renderer_path
            text = path.read_text()
            begin = text.index('    private static func renderCoverage(')
            end = text.index('    private static func sample(', begin)
            original = text[begin:end]
            wrapper = original[:original.index('        let gray = CGColorSpace')]
            wrapper = wrapper.replace('private static func renderCoverage(', 'internal static func _testRenderCoverageBytes(', 1)
            wrapper = wrapper.replace('throws -> CIImage', 'throws -> Data', 1)
            wrapper = wrapper.replace('return CIImage(color: .clear).cropped(to: imageExtent)', 'return Data()')
            wrapper += '        return Data(bytes)\n    }\n\n'
            path.write_text(text[:begin] + wrapper + text[begin:])
        (checkout / harness_path).write_text(harness)
        original = source(sha, renderer_path)
        actual = (checkout / renderer_path).read_text()
        metadata[variant] = {
            'productSHA': sha,
            'rendererModified': original != actual,
            'sharedHarnessSHA256': hashlib.sha256(harness.encode()).hexdigest(),
        }
        import difflib
        diff = ''.join(difflib.unified_diff(
            original.splitlines(True), actual.splitlines(True),
            fromfile='a/' + renderer_path, tofile='b/' + renderer_path,
            n=0,
        ))
        (root / (variant + '-renderer-observation.patch')).write_text(diff)
        output = root / (variant + '-pixels')
        module_cache = root / (variant + '-module-cache')
        env = dict(
            os.environ,
            LUMAHARBOR_BRUSH_PARITY_OUTPUT=str(output),
            CLANG_MODULE_CACHE_PATH=str(module_cache),
            SWIFTPM_MODULECACHE_OVERRIDE=str(module_cache),
        )
        log_path = root / (variant + '-test.log')
        with log_path.open('w') as log:
            run(['swift', 'test', '--disable-sandbox', '-c', 'release', '--package-path', str(checkout), '--scratch-path', str(root / (variant + '-build')), '--filter', 'BrushPreviewABBAHarnessTests/testOptInABBAOutputParity'], env=env, stdout=log, stderr=subprocess.STDOUT)
        capture_tests[variant] = capture_summary(log_path)
        print(variant + ' output capture PASS', flush=True)
    b_manifest = json.loads((root / 'B-pixels/manifest.json').read_text())
    o_manifest = json.loads((root / 'O-pixels/manifest.json').read_text())
    assert b_manifest == o_manifest, 'B/O dimensions or output manifest mismatch'
    comparisons = []
    raw_outputs = {'B': [], 'O': []}
    for item in b_manifest:
        b_path = root / 'B-pixels' / item['file']
        o_path = root / 'O-pixels' / item['file']
        b = b_path.read_bytes()
        o = o_path.read_bytes()
        assert len(b) == len(o) == item['width'] * item['height'] * item['channels']
        raw_outputs['B'].append(dict(item, sha256=sha256(b_path)))
        raw_outputs['O'].append(dict(item, sha256=sha256(o_path)))
        max_error, offset, count = 0, None, 0
        if b != o:
            for i, (bv, ov) in enumerate(zip(b, o)):
                error = abs(bv - ov)
                if error: count += 1
                if error > max_error: max_error, offset = error, i
        threshold = 0 if item['kind'] == 'coverageR8' else 1
        comparisons.append(dict(item, maxByteError=max_error, differingByteCount=count,
            maximumErrorLocation=None if offset is None else {
                'x': (offset // item['channels']) % item['width'],
                'y': (offset // item['channels']) // item['width'],
                'channel': offset % item['channels']},
            threshold=threshold, result='PASS' if max_error <= threshold else 'FAIL'))
    payload = {'schemaVersion': 1, 'variants': metadata, 'comparisons': comparisons,
        'result': 'PASS' if all(x['result'] == 'PASS' for x in comparisons) else 'FAIL',
        'scope': 'untimed shared ABBA workloads, 18 preview outputs and 66 direct R8 masks; both changed exposure parities'}
    (root / 'parity.json').write_text(json.dumps(payload, indent=2, sort_keys=True) + '\n')
    manifest = {
        'baselineSHA': baseline_sha,
        'candidateSHA': candidate_sha,
        'captureTests': capture_tests,
        'harnessSourceSHA': candidate_sha,
        'invokedCandidateRef': args.candidate,
        'rawOutputs': raw_outputs,
        'runnerSHA256': sha256(Path(__file__)),
    }
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2, sort_keys=True) + '\n')
    print(json.dumps({'result': payload['result'], 'comparisons': len(comparisons)}), flush=True)
    if payload['result'] != 'PASS': raise SystemExit(1)

if __name__ == '__main__': main()
