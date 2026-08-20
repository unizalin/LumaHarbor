// Core Image kernels for AdjustmentPipeline (spec §7 Gate B1), replacing the
// deprecated CIKL `CIKernel(source:)`/`CIColorKernel(source:)` string kernels
// that used to live inline in AdjustmentPipeline.swift.
//
// Compiled into a `default.metallib` resource by the `CompileMetalKernels`
// SwiftPM build plugin, which invokes `xcrun metal -fcikernel` /
// `xcrun metallib -cikernel` on this file -- NOT the `[[stitchable]]`
// attribute some newer Core Image Metal kernel examples use. Both were tried
// by hand: `[[stitchable]]` alone compiles, but a plain `metallib` link then
// treats every kernel function as dead code with nothing calling it and
// strips it, leaving `CIKernel.kernelNames(fromMetalLibraryData:)` empty.
// `-fcikernel`/`-cikernel` is what actually keeps the coreimage-namespaced
// functions in the library and resolvable by name at load time.
//
// Both `advancedToneCurve` and `hslAdjust` are declared `CIKernel`, not
// `CIColorKernel`, in AdjustmentPipeline.swift despite the latter originally
// (in its CIKL incarnation) being built via `CIColorKernel(source:)`: both
// kernels need a dependent texture read (a LUT lookup; a per-band weighted
// sample), which only a general kernel's `sampler` argument -- with
// `.sample()`/`.coord()`/`.transform()` -- supports. The CIKL predecessor's
// `CIColorKernel(source:)` apparently tolerated the same restriction it
// documents against, likely because `AdjustmentPipeline.applyHSL` always
// called the inherited `CIKernel.apply(extent:roiCallback:arguments:)`, not
// `CIColorKernel`'s own `apply(extent:arguments:)` overload -- an
// undocumented quirk not worth relying on again.
//
// Migrating this file: pixel-output equivalence against the CIKL originals
// was verified by hand (both kernels, 8 HSL bands, positive/negative
// hue/sat/lum, extended-range and achromatic pixels) before this file
// replaced them; see the AdjustmentPipelineTests/HSLAdjustmentsTests suites
// for the regression coverage that keeps it that way.

#include <CoreImage/CoreImage.h>
using namespace metal;

namespace {
    // GLSL-style floored modulo (what Core Image Kernel Language's `mod` did),
    // as opposed to Metal's `fmod`, which truncates toward zero and can return
    // negative values. The hue-wrap math below depends on the floored,
    // same-sign-as-divisor behaviour.
    inline float ci_mod(float x, float y) {
        return x - y * floor(x / y);
    }
}

extern "C" {
namespace coreimage {

/// Per-pixel 1D LUT lookup, run once per RGB channel with the same table
/// (spec §4.3: colour is not touched, only tone).
float4 advancedToneCurve(sampler image, sampler lut, float lutWidth) {
    float4 pixel = image.sample(image.coord());
    float lastIndex = lutWidth - 1.0;
    float2 lutSize = lut.size();
    // Only the table index is clamped -- it has to stay inside the 256-texel
    // texture -- while any extended-range excess is carried around the
    // lookup and added back afterwards. The pipeline works in extended-range
    // linear space, so a highlight at 1.5 must still read 1.5 after an
    // identity curve instead of being crushed into the LUT's own 0...1
    // domain.
    float rIn = clamp(pixel.r, 0.0, 1.0);
    float gIn = clamp(pixel.g, 0.0, 1.0);
    float bIn = clamp(pixel.b, 0.0, 1.0);
    float r = lut.sample(lut.transform(float2(rIn * lastIndex + 0.5, lutSize.y * 0.5))).r + (pixel.r - rIn);
    float g = lut.sample(lut.transform(float2(gIn * lastIndex + 0.5, lutSize.y * 0.5))).r + (pixel.g - gIn);
    float b = lut.sample(lut.transform(float2(bIn * lastIndex + 0.5, lutSize.y * 0.5))).r + (pixel.b - bIn);
    return float4(r, g, b, pixel.a);
}

/// One pass over all 8 bands per pixel, blending each band's hue/sat/lum
/// adjustment by `HSLKernelWeights`-equivalent triangular falloff (spec
/// §4.3). The falloff math is duplicated here rather than calling into
/// `HSLKernelWeights` -- the GPU kernel can't call Swift -- so any change to
/// the falloff shape must be made in both places; the unit tests on
/// `HSLKernelWeights` exist specifically to keep this constant correct even
/// though the kernel body itself can't be unit tested.
float4 hslAdjust(
    sampler image,
    float centers0, float centers1, float centers2, float centers3,
    float centers4, float centers5, float centers6, float centers7,
    float hues0, float hues1, float hues2, float hues3,
    float hues4, float hues5, float hues6, float hues7,
    float sats0, float sats1, float sats2, float sats3,
    float sats4, float sats5, float sats6, float sats7,
    float lums0, float lums1, float lums2, float lums3,
    float lums4, float lums5, float lums6, float lums7,
    float halfWidth
) {
    float4 pixel = image.sample(image.coord());
    float maxC = max(pixel.r, max(pixel.g, pixel.b));
    float minC = min(pixel.r, min(pixel.g, pixel.b));
    float delta = maxC - minC;
    float luma = (maxC + minC) * 0.5;

    // Achromatic pixels have no hue, and hue becomes numerically unstable
    // when chroma is below this same epsilon. Treating that fallback hue as
    // 0 incorrectly let the red/orange/magenta bands change neutral greys,
    // especially through the luminance control.
    if (delta <= 0.0001) { return pixel; }

    float hueDeg = 0.0;
    if (maxC == pixel.r) {
        hueDeg = 60.0 * ci_mod((pixel.g - pixel.b) / delta, 6.0);
    } else if (maxC == pixel.g) {
        hueDeg = 60.0 * (((pixel.b - pixel.r) / delta) + 2.0);
    } else {
        hueDeg = 60.0 * (((pixel.r - pixel.g) / delta) + 4.0);
    }
    if (hueDeg < 0.0) { hueDeg = hueDeg + 360.0; }

    float centers[8] = { centers0, centers1, centers2, centers3, centers4, centers5, centers6, centers7 };
    float hues[8] = { hues0, hues1, hues2, hues3, hues4, hues5, hues6, hues7 };
    float sats[8] = { sats0, sats1, sats2, sats3, sats4, sats5, sats6, sats7 };
    float lums[8] = { lums0, lums1, lums2, lums3, lums4, lums5, lums6, lums7 };

    float hueShift = 0.0;
    float satShift = 0.0;
    float lumShift = 0.0;
    float totalWeight = 0.0;
    for (int i = 0; i < 8; i++) {
        float rawDistance = abs(ci_mod(hueDeg, 360.0) - ci_mod(centers[i], 360.0));
        float distance = min(rawDistance, 360.0 - rawDistance);
        float weight = max(0.0, 1.0 - distance / halfWidth);
        hueShift += weight * hues[i];
        satShift += weight * sats[i];
        lumShift += weight * lums[i];
        totalWeight += weight;
    }

    // halfWidth is wide enough that no hue falls in a dead zone
    // (HSLKernelWeights.halfWidthDegrees), which means the 30-degree-apart
    // bands now overlap by more than 1.0 near their shared midpoints.
    // Renormalise there so the blend never amplifies past what a single band
    // at full strength would do; below 1.0 the weights are left alone, so a
    // lone band still falls off toward zero at its edge instead of being
    // stretched back up to full strength.
    if (totalWeight > 1.0) {
        hueShift /= totalWeight;
        satShift /= totalWeight;
        lumShift /= totalWeight;
    }

    // hue in degrees/100 keeps the shift in the same -1...1-ish order of
    // magnitude as sat/lum before they're applied as fractional adjustments
    // -- a 100-degree slider maps to roughly a 27-degree hue rotation,
    // consistent with the ±100 UI range meaning "full strength", not "spin
    // the hue wheel".
    float shiftedHue = ci_mod(hueDeg + hueShift * 0.27, 360.0);
    float newSat = clamp(1.0 + satShift / 100.0, 0.0, 2.0);
    float newLum = luma + (lumShift / 100.0) * 0.25;

    float c = delta * newSat;
    float x = c * (1.0 - abs(ci_mod(shiftedHue / 60.0, 2.0) - 1.0));
    float m = newLum - c * 0.5;
    float3 rgbPrime;
    if (shiftedHue < 60.0) { rgbPrime = float3(c, x, 0.0); }
    else if (shiftedHue < 120.0) { rgbPrime = float3(x, c, 0.0); }
    else if (shiftedHue < 180.0) { rgbPrime = float3(0.0, c, x); }
    else if (shiftedHue < 240.0) { rgbPrime = float3(0.0, x, c); }
    else if (shiftedHue < 300.0) { rgbPrime = float3(x, 0.0, c); }
    else { rgbPrime = float3(c, 0.0, x); }

    // Deliberately unclamped: the working space is extended-range linear,
    // and clamping here destroyed highlight headroom that later stages --
    // vignette darkening, the final output transform -- are supposed to be
    // able to pull back. For a neutral band this reconstruction is an exact
    // round-trip, so an input channel above 1.0 comes back out above 1.0.
    return float4(rgbPrime + m, pixel.a);
}

} // namespace coreimage
} // extern "C"
