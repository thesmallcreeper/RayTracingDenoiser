/*
Copyright (c) 2022, NVIDIA CORPORATION. All rights reserved.

NVIDIA CORPORATION and its licensors retain all intellectual property
and proprietary rights in and to this software, related documentation
and any modifications thereto. Any use, reproduction, disclosure or
distribution of this software and related documentation without an express
license agreement from NVIDIA CORPORATION is strictly prohibited.
*/

#include "NRD.h"
#include "DenoiserImpl.h"
#include "../Resources/Version.h"

#include <array>

static_assert(VERSION_MAJOR == NRD_VERSION_MAJOR, "VERSION_MAJOR & NRD_VERSION_MAJOR don't match!");
static_assert(VERSION_MINOR == NRD_VERSION_MINOR, "VERSION_MINOR & NRD_VERSION_MINOR don't match!");
static_assert(VERSION_BUILD == NRD_VERSION_BUILD, "VERSION_BUILD & NRD_VERSION_BUILD don't match!");

constexpr std::array<nrd::Method, (size_t)nrd::Method::MAX_NUM> g_NrdSupportedMethods =
{
    nrd::Method::REBLUR_DIFFUSE,
    nrd::Method::REBLUR_DIFFUSE_OCCLUSION,
    nrd::Method::REBLUR_SPECULAR,
    nrd::Method::REBLUR_SPECULAR_OCCLUSION,
    nrd::Method::REBLUR_DIFFUSE_SPECULAR,
    nrd::Method::REBLUR_DIFFUSE_SPECULAR_OCCLUSION,
    nrd::Method::REBLUR_DIFFUSE_DIRECTIONAL_OCCLUSION,
    nrd::Method::SIGMA_SHADOW,
    nrd::Method::SIGMA_SHADOW_TRANSLUCENCY,
    nrd::Method::RELAX_DIFFUSE,
    nrd::Method::RELAX_SPECULAR,
    nrd::Method::RELAX_DIFFUSE_SPECULAR,
    nrd::Method::REFERENCE,
    nrd::Method::SPECULAR_REFLECTION_MV,
    nrd::Method::SPECULAR_DELTA_MV
};

constexpr nrd::LibraryDesc g_NrdLibraryDesc =
{
    { 100, 200, 300, 400 }, // IMPORTANT: since NRD is compiled via "CompileHLSLToSPIRV" these should match the BAT file!
    g_NrdSupportedMethods.data(),
    (uint32_t)g_NrdSupportedMethods.size(),
    VERSION_MAJOR,
    VERSION_MINOR,
    VERSION_BUILD,
#ifdef NRD_USE_OCT_NORMAL_ENCODING
    2, true
#else
    0, false
#endif
};

constexpr std::array<const char*, (size_t)nrd::ResourceType::MAX_NUM> g_NrdResourceTypeNames =
{
    "IN_MV ",
    "IN_NORMAL_ROUGHNESS ",
    "IN_VIEWZ ",
    "IN_DIFF_RADIANCE_HITDIST ",
    "IN_SPEC_RADIANCE_HITDIST ",
    "IN_DIFF_HITDIST ",
    "IN_SPEC_HITDIST ",
    "IN_DIFF_DIRECTION_HITDIST ",
    "IN_DIFF_DIRECTION_PDF ",
    "IN_SPEC_DIRECTION_PDF ",
    "IN_DIFF_CONFIDENCE ",
    "IN_SPEC_CONFIDENCE ",
    "IN_SHADOWDATA ",
    "IN_SHADOW_TRANSLUCENCY ",
    "IN_RADIANCE ",
    "IN_DELTA_PRIMARY_POS ",
    "IN_DELTA_SECONDARY_POS ",

    "OUT_DIFF_RADIANCE_HITDIST ",
    "OUT_SPEC_RADIANCE_HITDIST ",
    "OUT_DIFF_HITDIST ",
    "OUT_SPEC_HITDIST ",
    "OUT_DIFF_DIRECTION_HITDIST ",
    "OUT_SHADOW_TRANSLUCENCY ",
    "OUT_RADIANCE ",
    "OUT_REFLECTION_MV ",
    "OUT_DELTA_MV ",

    "TRANSIENT_POOL",
    "PERMANENT_POOL",
};

NRD_API const nrd::LibraryDesc& NRD_CALL nrd::GetLibraryDesc()
{
    return g_NrdLibraryDesc;
}

NRD_API nrd::Result NRD_CALL nrd::CreateDenoiser(const DenoiserCreationDesc& denoiserCreationDesc, Denoiser*& denoiser)
{
    DenoiserCreationDesc modifiedDenoiserCreationDesc = denoiserCreationDesc;
    CheckAndSetDefaultAllocator(modifiedDenoiserCreationDesc.memoryAllocatorInterface);

    StdAllocator<uint8_t> memoryAllocator(modifiedDenoiserCreationDesc.memoryAllocatorInterface);

    DenoiserImpl* implementation = Allocate<DenoiserImpl>(memoryAllocator, memoryAllocator);
    const Result result = implementation->Create(modifiedDenoiserCreationDesc);

    if (result == Result::SUCCESS)
    {
        denoiser = (Denoiser*)implementation;
        return Result::SUCCESS;
    }

    Deallocate(memoryAllocator, implementation);
    return result;
}

NRD_API const nrd::DenoiserDesc& NRD_CALL nrd::GetDenoiserDesc(const nrd::Denoiser& denoiser)
{
    return ((const DenoiserImpl&)denoiser).GetDesc();
}

NRD_API nrd::Result NRD_CALL nrd::SetMethodSettings(nrd::Denoiser& denoiser, nrd::Method method, const void* methodSettings)
{
    return ((DenoiserImpl&)denoiser).SetMethodSettings(method, methodSettings);
}

NRD_API nrd::Result NRD_CALL nrd::GetComputeDispatches(nrd::Denoiser& denoiser, const nrd::CommonSettings& commonSettings, const nrd::DispatchDesc*& dispatchDescs, uint32_t& dispatchDescNum)
{
    return ((DenoiserImpl&)denoiser).GetComputeDispatches(commonSettings, dispatchDescs, dispatchDescNum);
}

NRD_API void NRD_CALL nrd::DestroyDenoiser(nrd::Denoiser& denoiser)
{
    StdAllocator<uint8_t> memoryAllocator = ((DenoiserImpl&)denoiser).GetStdAllocator();
    Deallocate(memoryAllocator, (DenoiserImpl*)&denoiser);
}

NRD_API const char* NRD_CALL nrd::GetResourceTypeString(nrd::ResourceType resourceType)
{
    return g_NrdResourceTypeNames[(size_t)resourceType];
}
