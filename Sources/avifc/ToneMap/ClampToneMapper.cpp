//
//  ClampToneMapper.cpp
//  
//
//  Created by Radzivon Bartoshyk on 09/10/2023.
//

#include "ClampToneMapper.hpp"
#include <algorithm>
#include "../NEMath.h"

#if defined(__clang__)
#pragma clang fp contract(fast) exceptions(ignore) reassociate(on)
#endif

using namespace std;

float ClampToneMapper::Luma(const float r, const float g, const float b) {
    return r * lumaVec[0] + g * lumaVec[1] + b * lumaVec[2];
}

void ClampToneMapper::Execute(float& r, float& g, float &b) {
    r *= exposure;
    g *= exposure;
    b *= exposure;
    const float Lin = Luma(r, g, b);
    if (Lin == 0) {
        return;
    }
    const float Lmax_ = LMax*exposure;
    const float Lout = clamp(Lin / Lmax_, 0.f, 1.f);
    const float scale = Lout / Lin;
    if (scale == 1) {
        return;
    }
    r *= scale;
    g *= scale;
    b *= scale;
}

#if __arm64__

float32x4_t ClampToneMapper::Execute(const float32x4_t m) {
    const float32x4_t v = vmulq_n_f32(m, exposure);
    const float Lin = vsumq_f32(vmulq_f32(v, vLumaVec));
    if (Lin == 0) {
        return v;
    }
    const float Lmax_ = LMax*exposure;
    const float Lout = clamp(Lin / Lmax_, 0.f, 1.f);
    const float scale = Lout / Lin;
    if (scale == 1) {
        return v;
    }
    return vmulq_n_f32(v, scale);
}

float32x4x4_t ClampToneMapper::Execute(const float32x4x4_t m) {
    float32x4x4_t r = {
        this->Execute(m.val[0]),
        this->Execute(m.val[1]),
        this->Execute(m.val[2]),
        this->Execute(m.val[3]),
    };
    return r;
}
#endif
