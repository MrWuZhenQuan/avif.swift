//
//  PerceptualQuantinizer.mm
//  avif.swift [https://github.com/awxkee/avif.swift]
//
//  Created by Radzivon Bartoshyk on 06/09/2022.
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in
//  all copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
//  THE SOFTWARE.
//

// https://review.mlplatform.org/plugins/gitiles/ml/ComputeLibrary/+/6ff3b19ee6120edf015fad8caab2991faa3070af/arm_compute/core/NEON/NEMath.inl
// https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2446-2019-PDF-E.pdf
// https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.2100-2-201807-I!!PDF-E.pdf
// https://www.itu.int/dms_pub/itu-r/opb/rep/R-REP-BT.2446-2019-PDF-E.pdf

#import <Foundation/Foundation.h>
#import "HDRColorTransfer.h"
#import "Accelerate/Accelerate.h"

#if __has_include(<Metal/Metal.h>)
#import <Metal/Metal.h>
#endif
#import "TargetConditionals.h"

#ifdef __arm64__
#include <arm_neon.h>
#endif

#import "NEMath.h"
#import "Color/Colorspace.h"
#import "ToneMap/Rec2408ToneMapper.hpp"
#import "ToneMap/LogarithmicToneMapper.hpp"
#import "ToneMap/ReinhardToneMapper.hpp"
#import "ToneMap/ClampToneMapper.hpp"
#import "ToneMap/ReinhardJodieToneMapper.hpp"
#import "ToneMap/HableToneMapper.hpp"
#import "ToneMap/DragoToneMapper.hpp"
#import "half.hpp"
#import "Color/Gamma.hpp"
#import "Color/PQ.hpp"
#import "Color/HLG.hpp"
#import "Color/SMPTE428.hpp"
#include "concurrency.hpp"
#include <thread>

using namespace std;
using namespace half_float;

constexpr float sdrReferencePoint = 203.0f;

struct TriStim {
    float r;
    float g;
    float b;
};

TriStim ClipToWhite(TriStim* c);

inline float Luma(TriStim &stim, const float* primaries) {
    return stim.r * primaries[0] + stim.g * primaries[1] + stim.b * primaries[2];
}

inline half loadHalf(uint16_t t) {
    half f;
    f.data_ = t;
    return f;
}

void TransferROW_U16HFloats(uint16_t *data, const ColorGammaCorrection gammaCorrection,
                            const float* primaries,
                            ToneMapper* toneMapper, const TransferFunction transfer, ColorSpaceMatrix* matrix) {
    float r = (float) loadHalf(data[0]);
    float g = (float) loadHalf(data[1]);
    float b = (float) loadHalf(data[2]);
    TriStim smpte;
    if (transfer == PQ) {
        smpte = {ToLinearPQ(r, sdrReferencePoint), ToLinearPQ(g, sdrReferencePoint), ToLinearPQ(b, sdrReferencePoint)};
    } else if (transfer == HLG) {
        smpte = {HLGToLinear(r), HLGToLinear(g), HLGToLinear(b)};
    } else {
        smpte = {SMPTE428ToLinear(r), SMPTE428ToLinear(g), SMPTE428ToLinear(b)};
    }

    r = smpte.r;
    g = smpte.g;
    b = smpte.b;

    toneMapper->Execute(r, g, b);

    if (matrix) {
        matrix->convert(r, g, b);
    }

    if (gammaCorrection == Rec2020) {
        data[0] = half(clamp(LinearRec2020ToRec2020(r), 0.0f, 1.0f)).data_;
        data[1] = half(clamp(LinearRec2020ToRec2020(g), 0.0f, 1.0f)).data_;
        data[2] = half(clamp(LinearRec2020ToRec2020(b), 0.0f, 1.0f)).data_;
    } else if (gammaCorrection == DisplayP3) {
        data[0] = half(clamp(LinearSRGBToSRGB(r), 0.0f, 1.0f)).data_;
        data[1] = half(clamp(LinearSRGBToSRGB(g), 0.0f, 1.0f)).data_;
        data[2] = half(clamp(LinearSRGBToSRGB(b), 0.0f, 1.0f)).data_;
    } else if (gammaCorrection == Rec709) {
        data[0] = half(clamp(LinearITUR709ToITUR709(r), 0.0f, 1.0f)).data_;
        data[1] = half(clamp(LinearITUR709ToITUR709(g), 0.0f, 1.0f)).data_;
        data[2] = half(clamp(LinearITUR709ToITUR709(b), 0.0f, 1.0f)).data_;
    } else {
        data[0] = half(clamp(r, 0.0f, 1.0f)).data_;
        data[1] = half(clamp(g, 0.0f, 1.0f)).data_;
        data[2] = half(clamp(b, 0.0f, 1.0f)).data_;
    }
}

#if __arm64__

__attribute__((flatten))
inline void SetPixelsRGB(float16x4_t rgb, uint16_t *vector, int components) {
    uint16x4_t t = vreinterpret_u16_f16(rgb);
    vst1_u16(vector, t);
}

__attribute__((flatten))
inline void SetPixelsRGBU8(const float32x4_t rgb, uint8_t *vector, const float32x4_t maxColors) {
    const float32x4_t zeros = vdupq_n_f32(0);
    const float32x4_t v = vminq_f32(vmaxq_f32(vrndq_f32(vmulq_f32(rgb, maxColors)), zeros), maxColors);
}

__attribute__((flatten))
inline float32x4_t GetPixelsRGBU8(const float32x4_t rgb, const float32x4_t maxColors) {
    const float32x4_t zeros = vdupq_n_f32(0);
    const float32x4_t v = vminq_f32(vmaxq_f32(vrndq_f32(vmulq_f32(rgb, maxColors)), zeros), maxColors);
    return v;
}

__attribute__((flatten))
inline float32x4x4_t Transfer(float32x4_t rChan, float32x4_t gChan,
                              float32x4_t bChan,
                              const ColorGammaCorrection gammaCorrection,
                              ToneMapper* toneMapper,
                              const TransferFunction transfer,
                              ColorSpaceMatrix* matrix) {
    float32x4x4_t m;
    if (transfer == PQ) {
        float32x4_t pqR = ToLinearPQ(rChan, sdrReferencePoint);
        float32x4_t pqG = ToLinearPQ(gChan, sdrReferencePoint);
        float32x4_t pqB = ToLinearPQ(bChan, sdrReferencePoint);

        m = {
            pqR, pqG, pqB, vdupq_n_f32(0.0f)
        };
    } else if (transfer == HLG) {
        float32x4_t pqR = HLGToLinear(rChan);
        float32x4_t pqG = HLGToLinear(gChan);
        float32x4_t pqB = HLGToLinear(bChan);

        m = {
            pqR, pqG, pqB, vdupq_n_f32(0.0f)
        };
    } else {
        float32x4_t pqR = SMPTE428ToLinear(rChan);
        float32x4_t pqG = SMPTE428ToLinear(gChan);
        float32x4_t pqB = SMPTE428ToLinear(bChan);

        m = {
            pqR, pqG, pqB, vdupq_n_f32(0.0f)
        };
    }
    m = vtransposeq_f32(m);

    float32x4x4_t r = toneMapper->Execute(m);

    if (matrix) {
        r = (*matrix) * r;
    }

    if (gammaCorrection == Rec2020) {
        r.val[0] = vclampq_n_f32(LinearRec2020ToRec2020(r.val[0]), 0.0f, 1.0f);
        r.val[1] = vclampq_n_f32(LinearRec2020ToRec2020(r.val[1]), 0.0f, 1.0f);
        r.val[2] = vclampq_n_f32(LinearRec2020ToRec2020(r.val[2]), 0.0f, 1.0f);
        r.val[3] = vclampq_n_f32(LinearRec2020ToRec2020(r.val[3]), 0.0f, 1.0f);
    } else if (gammaCorrection == DisplayP3) {
        r.val[0] = vclampq_n_f32(LinearSRGBToSRGB(r.val[0]), 0.0f, 1.0f);
        r.val[1] = vclampq_n_f32(LinearSRGBToSRGB(r.val[1]), 0.0f, 1.0f);
        r.val[2] = vclampq_n_f32(LinearSRGBToSRGB(r.val[2]), 0.0f, 1.0f);
        r.val[3] = vclampq_n_f32(LinearSRGBToSRGB(r.val[3]), 0.0f, 1.0f);
    } else if (gammaCorrection == Rec709) {
        r.val[0] = vclampq_n_f32(LinearITUR709ToITUR709(r.val[0]), 0.0f, 1.0f);
        r.val[1] = vclampq_n_f32(LinearITUR709ToITUR709(r.val[1]), 0.0f, 1.0f);
        r.val[2] = vclampq_n_f32(LinearITUR709ToITUR709(r.val[2]), 0.0f, 1.0f);
        r.val[3] = vclampq_n_f32(LinearITUR709ToITUR709(r.val[3]), 0.0f, 1.0f);
    } else {
        r.val[0] = vclampq_n_f32(r.val[0], 0.0f, 1.0f);
        r.val[1] = vclampq_n_f32(r.val[1], 0.0f, 1.0f);
        r.val[2] = vclampq_n_f32(r.val[2], 0.0f, 1.0f);
        r.val[3] = vclampq_n_f32(r.val[3], 0.0f, 1.0f);
    }

    return r;
}

#endif

void TransferROWUnsigned8(uint8_t *data, float maxColors,
                    const ColorGammaCorrection gammaCorrection,
                    ToneMapper* toneMapper,
                    const TransferFunction transfer,
                    ColorSpaceMatrix* matrix) {
    auto r = (float) data[0] / (float) maxColors;
    auto g = (float) data[1] / (float) maxColors;
    auto b = (float) data[2] / (float) maxColors;
    TriStim smpte;
    if (transfer == PQ) {
        smpte = {ToLinearPQ(r, sdrReferencePoint), ToLinearPQ(g, sdrReferencePoint), ToLinearPQ(b, sdrReferencePoint)};
    } else if (transfer == HLG) {
        smpte = {HLGToLinear(r), HLGToLinear(g), HLGToLinear(b)};
    } else {
        smpte = {SMPTE428ToLinear(r), SMPTE428ToLinear(g), SMPTE428ToLinear(b)};
    }

    r = smpte.r;
    g = smpte.g;
    b = smpte.b;

    toneMapper->Execute(r, g, b);

    if (matrix) {
        matrix->convert(r, g, b);
    }

    if (gammaCorrection == Rec2020) {
        r = LinearRec2020ToRec2020(r);
        g = LinearRec2020ToRec2020(g);
        b = LinearRec2020ToRec2020(b);
    } else if (gammaCorrection == DisplayP3) {
        r = LinearSRGBToSRGB(r);
        g = LinearSRGBToSRGB(g);
        b = LinearSRGBToSRGB(b);
    } else if (gammaCorrection == Rec709) {
        r = LinearITUR709ToITUR709(r);
        g = LinearITUR709ToITUR709(g);
        b = LinearITUR709ToITUR709(b);
    }

    data[0] = (uint8_t) clamp((float) round(r * maxColors), 0.0f, maxColors);
    data[1] = (uint8_t) clamp((float) round(g * maxColors), 0.0f, maxColors);
    data[2] = (uint8_t) clamp((float) round(b * maxColors), 0.0f, maxColors);
}

@implementation HDRColorTransfer : NSObject

#if __arm64__

+(void)transferNEONF16:(nonnull uint8_t*)data stride:(const int)stride width:(const int)width height:(const int)height
                 depth:(const int)depth primaries:(float*)primaries
                 space:(ColorGammaCorrection)space
            components:(const int)components
            toneMapper:(ToneMapper*)toneMapper
              function:(const TransferFunction)function
                matrix:(ColorSpaceMatrix*)matrix {
    auto ptr = reinterpret_cast<uint8_t *>(data);

    int threadCount = clamp(min(static_cast<int>(thread::hardware_concurrency()), height * width / (256*256)), 1, 12);
    vector<thread> workers;
    int segmentHeight = height / threadCount;

    for (int i = 0; i < threadCount; i++) {
        int start = i * segmentHeight;
        int end = (i + 1) * segmentHeight;
        if (i == threadCount - 1) {
            end = height;
        }
        workers.emplace_back([start, end, ptr, stride, space, toneMapper, function, matrix, components, width, primaries]() {
            for (int y = start; y < end; ++y) {
                auto ptr16 = reinterpret_cast<uint16_t *>(ptr + y * stride);
                int x;
                const int pixels = 8;
                for (x = 0; x + pixels < width; x += pixels) {
                    if (components == 4) {
                        float16x8x4_t rgbVector = vld4q_f16(reinterpret_cast<const float16_t *>(ptr16));

                        float32x4_t rChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[0]));
                        float32x4_t rChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[0]));
                        float32x4_t gChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[1]));
                        float32x4_t gChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[1]));
                        float32x4_t bChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[2]));
                        float32x4_t bChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[2]));
                        float16x8_t aChannels = rgbVector.val[3];

                        float32x4x4_t low = Transfer(rChannelsLow, gChannelsLow, bChannelsLow, space, toneMapper, function, matrix);
                        float32x4x4_t high = Transfer(rChannelsHigh, gChannelsHigh, bChannelsHigh, space, toneMapper, function, matrix);

                        float16x8x4_t m = {
                            vcombine_f16(vcvt_f16_f32(low.val[0]), vcvt_f16_f32(high.val[0])),
                            vcombine_f16(vcvt_f16_f32(low.val[1]), vcvt_f16_f32(high.val[1])),
                            vcombine_f16(vcvt_f16_f32(low.val[2]), vcvt_f16_f32(high.val[2])),
                            vcombine_f16(vcvt_f16_f32(low.val[3]), vcvt_f16_f32(high.val[3])),
                        };
                        m = vtransposeq_f16(m);

                        float16x8x4_t rw = { m.val[0], m.val[1], m.val[2], aChannels };
                        vst4q_f16(reinterpret_cast<float16_t*>(ptr16), rw);
                    } else {
                        float16x8x3_t rgbVector = vld3q_f16(reinterpret_cast<const float16_t *>(ptr16));

                        float32x4_t rChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[0]));
                        float32x4_t rChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[0]));
                        float32x4_t gChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[1]));
                        float32x4_t gChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[1]));
                        float32x4_t bChannelsLow = vcvt_f32_f16(vget_low_f16(rgbVector.val[2]));
                        float32x4_t bChannelsHigh = vcvt_f32_f16(vget_high_f16(rgbVector.val[2]));

                        float32x4x4_t low = Transfer(rChannelsLow, gChannelsLow, bChannelsLow, space, toneMapper, function, matrix);

                        float32x4x4_t high = Transfer(rChannelsHigh, gChannelsHigh, bChannelsHigh, space, toneMapper, function, matrix);

                        float16x8x4_t m = {
                            vcombine_f16(vcvt_f16_f32(low.val[0]), vcvt_f16_f32(high.val[0])),
                            vcombine_f16(vcvt_f16_f32(low.val[1]), vcvt_f16_f32(high.val[1])),
                            vcombine_f16(vcvt_f16_f32(low.val[2]), vcvt_f16_f32(high.val[2])),
                            vcombine_f16(vcvt_f16_f32(low.val[3]), vcvt_f16_f32(high.val[3])),
                        };
                        m = vtransposeq_f16(m);
                        float16x8x3_t merged = { m.val[0], m.val[1], m.val[2] };
                        vst3q_f16(reinterpret_cast<float16_t*>(ptr16), merged);
                    }

                    ptr16 += components*pixels;
                }

                for (; x < width; ++x) {
                    TransferROW_U16HFloats(ptr16, space, primaries, toneMapper, function, matrix);
                    ptr16 += components;
                }
            }
        });
    }

    for (std::thread& thread : workers) {
        thread.join();
    }
}

+(void)transferNEONU8:(nonnull uint8_t*)data
               stride:(int)stride width:(int)width height:(int)height depth:(int)depth
            primaries:(float*)primaries space:(ColorGammaCorrection)space components:(int)components
           toneMapper:(ToneMapper*)toneMapper
             function:(const TransferFunction)function
               matrix:(ColorSpaceMatrix*)matrix {
    auto ptr = reinterpret_cast<uint8_t *>(data);

    const auto maxColors = std::pow(2, (float) depth) - 1;

    const float colorScale = 1.0f / float((1 << depth) - 1);

    const int threadCount = std::clamp(std::min(static_cast<int>(thread::hardware_concurrency()), height * width / (256*256)), 1, 12);
     
    concurrency::parallel_for(threadCount, height, [&](int y) {
        const float32x4_t vMaxColors = vdupq_n_f32(maxColors);
        const float32x4_t mask = {1.0f, 1.0f, 1.0f, 0.0};
        const auto mColors = vdupq_n_f32(maxColors);
        auto ptr16 = reinterpret_cast<uint8_t *>(ptr + y * stride);
        int x = 0;
        const int pixels = 16;
        for (x = 0; x + pixels < width; x += pixels) {
            if (components == 4) {
                uint8x16x4_t rgbChannels = vld4q_u8(ptr16);

                uint8x8_t rChannelsLow = vget_low_u8(rgbChannels.val[0]);
                uint8x8_t rChannelsHigh = vget_high_f16(rgbChannels.val[0]);
                uint8x8_t gChannelsLow = vget_low_u8(rgbChannels.val[1]);
                uint8x8_t gChannelsHigh = vget_high_f16(rgbChannels.val[1]);
                uint8x8_t bChannelsLow = vget_low_u8(rgbChannels.val[2]);
                uint8x8_t bChannelsHigh = vget_high_f16(rgbChannels.val[2]);

                uint16x8_t rLowU16 = vmovl_u8(rChannelsLow);
                uint16x8_t gLowU16 = vmovl_u8(gChannelsLow);
                uint16x8_t bLowU16 = vmovl_u8(bChannelsLow);
                uint16x8_t rHighU16 = vmovl_u8(rChannelsHigh);
                uint16x8_t gHighU16 = vmovl_u8(gChannelsHigh);
                uint16x8_t bHighU16 = vmovl_u8(bChannelsHigh);

                float32x4_t rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(rLowU16))), colorScale);
                float32x4_t gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(gLowU16))), colorScale);
                float32x4_t bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(bLowU16))), colorScale);

                float32x4x4_t low = Transfer(rLow, gLow, bLow, space, toneMapper, function, matrix);
                float32x4_t rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                float32x4_t rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                float32x4_t rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                float32x4_t rw4 = GetPixelsRGBU8(low.val[3], vMaxColors);

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(rLowU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(gLowU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(bLowU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper, function, matrix);
                float32x4_t rcw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                float32x4_t rcw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                float32x4_t rcw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                float32x4_t rcw4 = GetPixelsRGBU8(low.val[3], vMaxColors);

                uint8x8_t lRow1u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw1)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw1))));
                uint8x8_t lRow2u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw2)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw2))));
                uint8x8_t lRow3u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw3)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw3))));
                uint8x8_t lRow4u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw4)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw4))));

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(rHighU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(gHighU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(bHighU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper, function, matrix);
                rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(rHighU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(gHighU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(bHighU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper, function, matrix);
                rcw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                rcw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                rcw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                rcw4 = GetPixelsRGBU8(low.val[3], vMaxColors);

                uint8x8_t hRow1u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw1)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw1))));
                uint8x8_t hRow2u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw2)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw2))));
                uint8x8_t hRow3u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw3)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw3))));
                uint8x8_t hRow4u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw4)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw4))));

                uint8x8x4_t lResult = {lRow1u16, lRow2u16, lRow3u16, lRow4u16};
                uint8x8x4_t hResult = {hRow1u16, hRow2u16, hRow3u16, hRow4u16};
                lResult = vtranspose_u8(lResult);
                hResult = vtranspose_u8(hResult);
                uint8x16x4_t result = {
                    vcombine_u8(lResult.val[0], hResult.val[0]),
                    vcombine_u8(lResult.val[1], hResult.val[1]),
                    vcombine_u8(lResult.val[2], hResult.val[2]),
                    rgbChannels.val[3]
                };
                vst4q_u8(ptr16, result);
            } else {

                uint8x16x3_t rgbChannels = vld3q_u8(ptr16);

                uint8x8_t rChannelsLow = vget_low_u8(rgbChannels.val[0]);
                uint8x8_t rChannelsHigh = vget_high_f16(rgbChannels.val[0]);
                uint8x8_t gChannelsLow = vget_low_u8(rgbChannels.val[1]);
                uint8x8_t gChannelsHigh = vget_high_f16(rgbChannels.val[1]);
                uint8x8_t bChannelsLow = vget_low_u8(rgbChannels.val[2]);
                uint8x8_t bChannelsHigh = vget_high_f16(rgbChannels.val[2]);

                uint16x8_t rLowU16 = vmovl_u8(rChannelsLow);
                uint16x8_t gLowU16 = vmovl_u8(gChannelsLow);
                uint16x8_t bLowU16 = vmovl_u8(bChannelsLow);
                uint16x8_t rHighU16 = vmovl_u8(rChannelsHigh);
                uint16x8_t gHighU16 = vmovl_u8(gChannelsHigh);
                uint16x8_t bHighU16 = vmovl_u8(bChannelsHigh);

                float32x4_t rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(rLowU16))), colorScale);
                float32x4_t gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(gLowU16))), colorScale);
                float32x4_t bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(bLowU16))), colorScale);

                float32x4x4_t low = Transfer(rLow, gLow, bLow, space, toneMapper, function, matrix);
                float32x4_t rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                float32x4_t rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                float32x4_t rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                float32x4_t rw4 = GetPixelsRGBU8(low.val[3], vMaxColors);

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(rLowU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(gLowU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(bLowU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper, function, matrix);
                float32x4_t rcw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                float32x4_t rcw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                float32x4_t rcw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                float32x4_t rcw4 = GetPixelsRGBU8(low.val[3], vMaxColors);

                uint8x8_t lRow1u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw1)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw1))));
                uint8x8_t lRow2u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw2)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw2))));
                uint8x8_t lRow3u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw3)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw3))));
                uint8x8_t lRow4u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw4)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw4))));

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(rHighU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(gHighU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_low_u16(bHighU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper, function, matrix);
                rw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                rw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                rw3 = GetPixelsRGBU8(low.val[2], vMaxColors);

                rLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(rHighU16))), colorScale);
                gLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(gHighU16))), colorScale);
                bLow = vmulq_n_f32(vcvtq_f32_u32(vmovl_u16(vget_high_u16(bHighU16))), colorScale);

                low = Transfer(rLow, gLow, bLow, space, toneMapper, function, matrix);
                rcw1 = GetPixelsRGBU8(low.val[0], vMaxColors);
                rcw2 = GetPixelsRGBU8(low.val[1], vMaxColors);
                rcw3 = GetPixelsRGBU8(low.val[2], vMaxColors);
                rcw4 = GetPixelsRGBU8(low.val[3], vMaxColors);

                uint8x8_t hRow1u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw1)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw1))));
                uint8x8_t hRow2u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw2)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw2))));
                uint8x8_t hRow3u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw3)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw3))));
                uint8x8_t hRow4u16 = vqmovn_u16(vcombine_u16(vqmovn_u32(vcvtq_u32_f32(rw4)),
                                                             vqmovn_u32(vcvtq_u32_f32(rcw4))));

                uint8x8x4_t lResult = {lRow1u16, lRow2u16, lRow3u16, lRow4u16};
                uint8x8x4_t hResult = {hRow1u16, hRow2u16, hRow3u16, hRow4u16};
                lResult = vtranspose_u8(lResult);
                hResult = vtranspose_u8(hResult);
                uint8x16x3_t result = {
                    vcombine_u8(lResult.val[0], hResult.val[0]),
                    vcombine_u8(lResult.val[1], hResult.val[1]),
                    vcombine_u8(lResult.val[2], hResult.val[2])
                };
                vst3q_u8(ptr16, result);
            }

            ptr16 += components*pixels;
        }

        for (; x < width; ++x) {
            TransferROWUnsigned8(ptr16, maxColors, space, toneMapper, function, matrix);
            ptr16 += components;
        }
    });
}
#endif

+(void)transfer:(nonnull uint8_t*)data stride:(const int)stride width:(const int)width height:(const int)height
            U16:(bool)U16 depth:(const int)depth half:(const bool)half primaries:(float*)primaries
     components:(const int)components gammaCorrection:(const ColorGammaCorrection)gammaCorrection
       function:(const TransferFunction)function matrix:(ColorSpaceMatrix*)matrix
        profile:(ColorSpaceProfile*)profile {
    auto ptr = reinterpret_cast<uint8_t *>(data);
    ToneMapper* toneMapper = new Rec2408ToneMapper(1000.0f, profile->whitePointNits, profile->whitePointNits, profile->lumaCoefficients);
#if __arm64__
    if (U16 && half) {
        [self transferNEONF16:reinterpret_cast<uint8_t*>(data) stride:stride width:width height:height
                        depth:depth primaries:primaries space:gammaCorrection
                   components:components toneMapper:toneMapper function:function matrix:matrix];
        delete toneMapper;
        return;
    }
    if (!U16) {
        [self transferNEONU8:reinterpret_cast<uint8_t*>(data) stride:stride width:width height:height
                       depth:depth primaries:primaries space:gammaCorrection
                  components:components toneMapper:toneMapper function:function matrix:matrix];
        delete toneMapper;
        return;
    }
#endif
    auto maxColors = std::powf(2, (float) depth) - 1;

    const int threadCount = clamp(min(static_cast<int>(thread::hardware_concurrency()), height * width / (256*256)), 1, 12);
    concurrency::parallel_for(threadCount, height, [&](int y) {
        if (U16) {
            auto ptr16 = reinterpret_cast<uint16_t *>(ptr + y * stride);
            for (int x = 0; x < width; ++x) {
                if (half) {
                    TransferROW_U16HFloats(ptr16, gammaCorrection, primaries, toneMapper, function, matrix);
                }
                ptr16 += components;
            }
        } else {
            auto ptr16 = reinterpret_cast<uint8_t *>(ptr + y * stride);
            for (int x = 0; x < width; ++x) {
                TransferROWUnsigned8(ptr16, maxColors, gammaCorrection, toneMapper, function, matrix);
                ptr16 += components;
            }
        }
    });
    
    delete toneMapper;
}
@end
