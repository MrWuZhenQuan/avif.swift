//
//  HejlBurgessToneMapper.cpp
//  avif.swift [https://github.com/awxkee/avif.swift]
//
//  Created by Radzivon Bartoshyk on 10/10/2023.
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

#include "HejlBurgessToneMapper.hpp"
#include <algorithm>

using namespace std;

#if defined(__clang__)
#pragma clang fp contract(fast) exceptions(ignore) reassociate(on)
#endif

float HejlBurgessToneMapper::hejlBurgess(const float v, const float exposure) {
    const float Cin = v * exposure;
    float x    = max(float(0.f), Cin - 0.004f),
    Cout = (x * (6.2f * x + 0.5f)) / (x * (6.2f * x + 1.7f) + 0.06f);
    return pow(Cout, 2.4f);
}

void HejlBurgessToneMapper::Execute(float& r, float& g, float &b) {
    r = hejlBurgess(r, exposure);
    g = hejlBurgess(g, exposure);
    b = hejlBurgess(b, exposure);
}

#if __arm64__

float32x4_t HejlBurgessToneMapper::Execute(const float32x4_t m) {
    float r = vgetq_lane_f32(m, 0);
    float g = vgetq_lane_f32(m, 1);
    float b = vgetq_lane_f32(m, 2);
    Execute(r, g, b);
    const float32x4_t v = {
        r, g, b, 0.0f
    };
    return v;
}

float32x4x4_t HejlBurgessToneMapper::Execute(const float32x4x4_t m) {
    float32x4x4_t r = {
        this->Execute(m.val[0]),
        this->Execute(m.val[1]),
        this->Execute(m.val[2]),
        this->Execute(m.val[3]),
    };
    return r;
}
#endif
