/*
Copyright (c) 2021, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "BindingBridge.hlsl"

NRI_RESOURCE(cbuffer, globalConstants, b, 0, 0)
{
    int2 gResolution;
    float gColorBoxSigmaScale;
    float gSpecularAntiLagSigmaScale;
    float gSpecularAntiLagPower;
    float gDiffuseAntiLagSigmaScale;
    float gDiffuseAntiLagPower;

}

#include "RELAX_Common.hlsl"

// Inputs
NRI_RESOURCE(Texture2D<uint2>, gSpecularAndDiffuseIlluminationLogLuv, t, 0, 0);
NRI_RESOURCE(Texture2D<uint2>, gSpecularAndDiffuseIlluminationResponsiveLogLuv, t, 1, 0);
NRI_RESOURCE(Texture2D<float2>, gSpecularAndDiffuseHistoryLength, t, 2, 0);

// Outputs
NRI_RESOURCE(RWTexture2D<uint2>, gOutSpecularAndDiffuseIlluminationLogLuv, u, 0, 0);
NRI_RESOURCE(RWTexture2D<float2>, gOutSpecularAndDiffuseHistoryLength, u, 1, 0);

groupshared uint4 sharedPackedResponsiveIlluminationYCoCg[16 + 2][16 + 2];

// Helper functions
uint4 packIllumination(float3 specularIllum, float3 diffuseIllum)
{
    uint4 result;
    result.r = f32tof16(specularIllum.r) | f32tof16(specularIllum.g) << 16;
    result.g = f32tof16(specularIllum.b);
    result.b = f32tof16(diffuseIllum.r) | f32tof16(diffuseIllum.g) << 16;
    result.a = f32tof16(diffuseIllum.b);
    return result;
}

void unpackIllumination(uint4 packed, out float3 specularIllum, out float3 diffuseIllum)
{
    specularIllum.r = f16tof32(packed.r);
    specularIllum.g = f16tof32(packed.r >> 16);
    specularIllum.b = f16tof32(packed.g);
    diffuseIllum.r = f16tof32(packed.b);
    diffuseIllum.g = f16tof32(packed.b >> 16);
    diffuseIllum.b = f16tof32(packed.a);
}

[numthreads(16, 16, 1)]
void main(uint3 dispatchThreadId : SV_DispatchThreadID, uint3 groupThreadId : SV_GroupThreadID, uint3 groupId : SV_GroupID)
{

    // Populating shared memory
    //
    // Renumerating threads to load 18x18 (16+2 x 16+2) block of data to shared memory
    //
    // The preloading will be done in two stages:
    // at the first stage the group will load 16x16 / 18 = 14.2 rows of the shared memory,
    // and all threads in the group will be following the same path.
    // At the second stage, the rest 18x18 - 16x16 = 68 threads = 2.125 warps will load the rest of data

    uint linearThreadIndex = groupThreadId.y * 16 + groupThreadId.x;
    uint newIdxX = linearThreadIndex % 18;
    uint newIdxY = linearThreadIndex / 18;

    uint blockXStart = groupId.x * 16;
    uint blockYStart = groupId.y * 16;

    // First stage
    uint ox = newIdxX;
    uint oy = newIdxY;
    int xx = blockXStart + newIdxX - 1;
    int yy = blockYStart + newIdxY - 1;

    float3 specularResponsiveIllumination = 0;
    float3 diffuseResponsiveIllumination = 0;

    if (xx >= 0 && yy >= 0 && xx < gResolution.x && yy < gResolution.y)
    {
        UnpackSpecularAndDiffuseFromLogLuvUint2(specularResponsiveIllumination, diffuseResponsiveIllumination, gSpecularAndDiffuseIlluminationResponsiveLogLuv[int2(xx,yy)]);
    }
    sharedPackedResponsiveIlluminationYCoCg[oy][ox] = packIllumination(_NRD_LinearToYCoCg(specularResponsiveIllumination), _NRD_LinearToYCoCg(diffuseResponsiveIllumination));

    // Second stage
    linearThreadIndex += 16 * 16;
    newIdxX = linearThreadIndex % 18;
    newIdxY = linearThreadIndex / 18;

    ox = newIdxX;
    oy = newIdxY;
    xx = blockXStart + newIdxX - 1;
    yy = blockYStart + newIdxY - 1;

    specularResponsiveIllumination = 0;
    diffuseResponsiveIllumination = 0;

    if (linearThreadIndex < 18 * 18)
    {
        if (xx >= 0 && yy >= 0 && xx < (int)gResolution.x && yy < (int)gResolution.y)
        {
            UnpackSpecularAndDiffuseFromLogLuvUint2(specularResponsiveIllumination, diffuseResponsiveIllumination, gSpecularAndDiffuseIlluminationResponsiveLogLuv[int2(xx,yy)]);
        }
        sharedPackedResponsiveIlluminationYCoCg[oy][ox] = packIllumination(_NRD_LinearToYCoCg(specularResponsiveIllumination), _NRD_LinearToYCoCg(diffuseResponsiveIllumination));
    }

    // Ensuring all the writes to shared memory are done by now
    GroupMemoryBarrierWithGroupSync();

    //
    // Shared memory is populated now and can be used for filtering
    //

    if (any(int2(dispatchThreadId.xy) >= gResolution)) return;

    float2 historyLength = 255.0 * gSpecularAndDiffuseHistoryLength[dispatchThreadId.xy];

    uint2 sharedMemoryIndex = groupThreadId.xy + int2(1, 1);

    float3 specularIllumination;
    float3 diffuseIllumination;
    UnpackSpecularAndDiffuseFromLogLuvUint2(specularIllumination, diffuseIllumination, gSpecularAndDiffuseIlluminationLogLuv[dispatchThreadId.xy]);
    float3 specularIlluminationYCoCg = _NRD_LinearToYCoCg(specularIllumination);
    float3 diffuseIlluminationYCoCg = _NRD_LinearToYCoCg(diffuseIllumination);

    float3 specularFirstMoment = 0;
    float3 specularSecondMoment = 0;
    float3 diffuseFirstMoment = 0;
    float3 diffuseSecondMoment = 0;

    [unroll]
    for (int dy = -1; dy <= 1; dy++)
    {
        [unroll]
        for (int dx = -1; dx <= 1; dx++)
        {
            uint2 sharedMemoryIndexP = sharedMemoryIndex + int2(dx, dy);
            int2 p = dispatchThreadId.xy + int2(dx,dy);
            if (p.x <= 0 || p.y <= 0 || p.x >= gResolution.x || p.y >= gResolution.y) sharedMemoryIndexP = sharedMemoryIndex;

            float3 specularIlluminationP;
            float3 diffuseIlluminationP;
            unpackIllumination(sharedPackedResponsiveIlluminationYCoCg[sharedMemoryIndexP.y][sharedMemoryIndexP.x], specularIlluminationP, diffuseIlluminationP);

            specularFirstMoment += specularIlluminationP;
            specularSecondMoment += specularIlluminationP * specularIlluminationP;

            diffuseFirstMoment += diffuseIlluminationP;
            diffuseSecondMoment += diffuseIlluminationP * diffuseIlluminationP;
        }
    }

    specularFirstMoment /= 9.0;
    specularSecondMoment /= 9.0;

    diffuseFirstMoment /= 9.0;
    diffuseSecondMoment /= 9.0;

    // Calculating color boxes for specular and diffuse signals
    float3 specularSigma = sqrt(max(0.0f, specularSecondMoment - specularFirstMoment * specularFirstMoment));
    float3 specularColorMin = specularFirstMoment - gColorBoxSigmaScale * specularSigma;
    float3 specularColorMax = specularFirstMoment + gColorBoxSigmaScale * specularSigma;

    float3 diffuseSigma = sqrt(max(0.0f, diffuseSecondMoment - diffuseFirstMoment * diffuseFirstMoment));
    float3 diffuseColorMin = diffuseFirstMoment - gColorBoxSigmaScale * diffuseSigma;
    float3 diffuseColorMax = diffuseFirstMoment + gColorBoxSigmaScale * diffuseSigma;

    // Expanding specular and diffuse color boxes with color of the center pixel for specular and diffuse signals
    // to avoid introducing bias
    float3 specularIlluminationCenter;
    float3 diffuseIlluminationCenter;
    unpackIllumination(sharedPackedResponsiveIlluminationYCoCg[sharedMemoryIndex.y][sharedMemoryIndex.x], specularIlluminationCenter, diffuseIlluminationCenter);

    specularColorMin = min(specularColorMin, specularIlluminationCenter);
    specularColorMax = max(specularColorMax, specularIlluminationCenter);
    diffuseColorMin = min(diffuseColorMin, diffuseIlluminationCenter);
    diffuseColorMax = max(diffuseColorMax, diffuseIlluminationCenter);

    // Calculating color boxes for antilag 
    float3 specularColorMinForAntilag = specularFirstMoment - gSpecularAntiLagSigmaScale * specularSigma;
    float3 specularColorMaxForAntilag = specularFirstMoment + gSpecularAntiLagSigmaScale * specularSigma;
    float3 diffuseColorMinForAntilag = diffuseFirstMoment - gDiffuseAntiLagSigmaScale * diffuseSigma;
    float3 diffuseColorMaxForAntilag = diffuseFirstMoment + gDiffuseAntiLagSigmaScale * diffuseSigma;

    float3 specularIlluminationYCoCgClampedForAntilag = clamp(specularIlluminationYCoCg, specularColorMinForAntilag, specularColorMaxForAntilag);
    float3 diffuseIlluminationYCoCgClampedForAntilag = clamp(diffuseIlluminationYCoCg, diffuseColorMinForAntilag, diffuseColorMaxForAntilag);

    float3 specularDiffYCoCg = abs(specularIlluminationYCoCgClampedForAntilag - specularIlluminationYCoCg);
    float3 specularDiffYCoCgScaled = (specularIlluminationYCoCg.r != 0) ? specularDiffYCoCg / (specularIlluminationYCoCg.r) : 0;
    float specularAntilagAmount = gSpecularAntiLagPower * sqrt(dot(specularDiffYCoCgScaled, specularDiffYCoCgScaled));

    float3 diffuseDiffYCoCg = abs(diffuseIlluminationYCoCgClampedForAntilag - diffuseIlluminationYCoCg);
    float3 diffuseDiffYCoCgScaled = (diffuseIlluminationYCoCg.r != 0) ? diffuseDiffYCoCg / (diffuseIlluminationYCoCg.r) : 0;
    float diffuseAntilagAmount = gDiffuseAntiLagPower * sqrt(dot(diffuseDiffYCoCgScaled, diffuseDiffYCoCgScaled));

    float2 adjustedHistoryLength = historyLength;
    adjustedHistoryLength.x = historyLength.x / (1.0 + specularAntilagAmount);
    adjustedHistoryLength.y = historyLength.y / (1.0 + diffuseAntilagAmount);
    adjustedHistoryLength = max(adjustedHistoryLength, 1.0);


    // Color clamping
    specularIlluminationYCoCg = clamp(specularIlluminationYCoCg, specularColorMin, specularColorMax);
    specularIllumination = _NRD_YCoCgToLinear(specularIlluminationYCoCg);

    diffuseIlluminationYCoCg = clamp(diffuseIlluminationYCoCg, diffuseColorMin, diffuseColorMax);
    diffuseIllumination = _NRD_YCoCgToLinear(diffuseIlluminationYCoCg);

    // Writing out the results
    gOutSpecularAndDiffuseIlluminationLogLuv[dispatchThreadId.xy] = PackSpecularAndDiffuseToLogLuvUint2(specularIllumination, diffuseIllumination);
    gOutSpecularAndDiffuseHistoryLength[dispatchThreadId.xy] = adjustedHistoryLength / 255.0;
}