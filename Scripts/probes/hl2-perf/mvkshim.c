/*
 * mvkshim — libMoltenVK.dylib wrapper that advertises the five features DXVK
 * 3.x requires but upstream MoltenVK 1.4.2 honestly reports missing (measured
 * with mvkfeatures.c, Sep 17 2026):
 *
 *   core   geometryShader, shaderCullDistance     (CX's patched MoltenVK fakes both)
 *   ext    VK_EXT_depth_clip_enable / depthClipEnable
 *   ext    VK_EXT_robustness2 / robustBufferAccess2, nullDescriptor
 *
 * D3D9 never creates geometry-shader pipelines; Metal clips depth by default
 * (so ignoring the depth-clip struct matches D3D9); the robustness flags only
 * change out-of-bounds/unbound-resource semantics. The shim returns the
 * patched feature bits and injects the extension in the enumeration, then in
 * vkCreateDevice strips those same bits/extension before forwarding so
 * MoltenVK does not answer VK_ERROR_FEATURE_NOT_PRESENT.
 *
 * win32u.so dlopens "libMoltenVK.dylib" and dlsym's only vkGetInstanceProcAddr,
 * vkGetDeviceProcAddr, vkCreateInstance, vkEnumerateInstanceExtensionProperties;
 * everything else is fetched through vkGetInstanceProcAddr, which is where the
 * shim substitutes its wrappers. The real library is loaded from
 * "libMoltenVK.real.dylib" beside this file.
 *
 * Build (headers from the MoltenVK release tar):
 *   clang -dynamiclib -arch x86_64 -arch arm64 -O2 \
 *     -I/tmp/dl/mvk/MoltenVK/MoltenVK/include -o libMoltenVK.dylib mvkshim.c
 *   codesign -fs - libMoltenVK.dylib
 * MVKSHIM_LOG=1 logs each patched call to stderr (lands in the game log).
 */
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void *real;
static PFN_vkGetInstanceProcAddr real_gipa;
static PFN_vkGetDeviceProcAddr real_gdpa;
static PFN_vkGetPhysicalDeviceFeatures real_features;
static PFN_vkGetPhysicalDeviceFeatures2 real_features2, real_features2khr;
static PFN_vkEnumerateDeviceExtensionProperties real_enum_ext;
static PFN_vkCreateDevice real_create_device;
static int verbose;

static const char *const injected_ext = VK_EXT_DEPTH_CLIP_ENABLE_EXTENSION_NAME;

static void logf_(const char *fmt, ...)
{
    if (!verbose) return;
    va_list ap; va_start(ap, fmt);
    fputs("[mvkshim] ", stderr); vfprintf(stderr, fmt, ap); fputc('\n', stderr);
    va_end(ap);
}

static void load_real(void)
{
    if (real) return;
    verbose = getenv("MVKSHIM_LOG") != NULL;
    Dl_info info;
    if (!dladdr((void *)&load_real, &info) || !info.dli_fname) { fprintf(stderr, "[mvkshim] dladdr failed\n"); abort(); }
    char path[4096];
    strlcpy(path, info.dli_fname, sizeof path);
    char *slash = strrchr(path, '/');
    if (slash) slash[1] = 0; else path[0] = 0;
    strlcat(path, "libMoltenVK.real.dylib", sizeof path);
    real = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!real) { fprintf(stderr, "[mvkshim] dlopen %s failed: %s\n", path, dlerror()); abort(); }
    real_gipa = (PFN_vkGetInstanceProcAddr)dlsym(real, "vkGetInstanceProcAddr");
    real_gdpa = (PFN_vkGetDeviceProcAddr)dlsym(real, "vkGetDeviceProcAddr");
    if (!real_gipa || !real_gdpa) { fprintf(stderr, "[mvkshim] real MoltenVK lacks proc-addr entry points\n"); abort(); }
    logf_("wrapping %s", path);
}

/* ---- feature reporting ------------------------------------------------- */

static void patch_core(VkPhysicalDeviceFeatures *f)
{
    f->geometryShader = VK_TRUE;
    f->shaderCullDistance = VK_TRUE;
}

static void patch_chain(void *chain)
{
    for (VkBaseOutStructure *s = chain; s; s = s->pNext) {
        if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT)
            ((VkPhysicalDeviceDepthClipEnableFeaturesEXT *)s)->depthClipEnable = VK_TRUE;
        else if (s->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT) {
            ((VkPhysicalDeviceRobustness2FeaturesEXT *)s)->robustBufferAccess2 = VK_TRUE;
            ((VkPhysicalDeviceRobustness2FeaturesEXT *)s)->nullDescriptor = VK_TRUE;
        }
    }
}

static void VKAPI_CALL shim_features(VkPhysicalDevice pd, VkPhysicalDeviceFeatures *f)
{
    real_features(pd, f);
    patch_core(f);
    logf_("vkGetPhysicalDeviceFeatures patched");
}

static void VKAPI_CALL shim_features2(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f2)
{
    real_features2(pd, f2);
    patch_core(&f2->features);
    patch_chain(f2->pNext);
    logf_("vkGetPhysicalDeviceFeatures2 patched");
}

static void VKAPI_CALL shim_features2khr(VkPhysicalDevice pd, VkPhysicalDeviceFeatures2 *f2)
{
    real_features2khr(pd, f2);
    patch_core(&f2->features);
    patch_chain(f2->pNext);
    logf_("vkGetPhysicalDeviceFeatures2KHR patched");
}

/* ---- extension enumeration: append VK_EXT_depth_clip_enable ------------ */

static VkResult VKAPI_CALL shim_enum_ext(VkPhysicalDevice pd, const char *layer, uint32_t *count, VkExtensionProperties *props)
{
    if (layer) return real_enum_ext(pd, layer, count, props);
    uint32_t n = 0;
    VkResult r = real_enum_ext(pd, NULL, &n, NULL);
    if (r != VK_SUCCESS) return r;
    if (!props) { *count = n + 1; return VK_SUCCESS; }
    uint32_t cap = *count;
    uint32_t got = cap < n ? cap : n;
    r = real_enum_ext(pd, NULL, &got, props);
    if (r != VK_SUCCESS && r != VK_INCOMPLETE) return r;
    if (got < cap) {
        memset(&props[got], 0, sizeof props[got]);
        strlcpy(props[got].extensionName, injected_ext, sizeof props[got].extensionName);
        props[got].specVersion = 1;
        *count = got + 1;
        logf_("injected %s into device extension list (%u total)", injected_ext, *count);
        return VK_SUCCESS;
    }
    *count = got;
    return VK_INCOMPLETE;
}

/* ---- device creation: strip what MoltenVK would reject ------------------ */

static VkResult VKAPI_CALL shim_create_device(VkPhysicalDevice pd, const VkDeviceCreateInfo *in, const VkAllocationCallbacks *alloc, VkDevice *out)
{
    VkDeviceCreateInfo ci = *in;

    const char *exts[256];
    uint32_t ne = 0;
    for (uint32_t i = 0; i < in->enabledExtensionCount && ne < 256; ++i)
        if (strcmp(in->ppEnabledExtensionNames[i], injected_ext) != 0)
            exts[ne++] = in->ppEnabledExtensionNames[i];
    ci.enabledExtensionCount = ne;
    ci.ppEnabledExtensionNames = exts;

    VkPhysicalDeviceFeatures legacy;
    if (in->pEnabledFeatures) {
        legacy = *in->pEnabledFeatures;
        legacy.geometryShader = VK_FALSE;
        legacy.shaderCullDistance = VK_FALSE;
        ci.pEnabledFeatures = &legacy;
    }

    /* Copy the structs we edit so the caller's chain stays untouched; unlink the depth-clip one. */
    VkPhysicalDeviceFeatures2 f2copy;
    VkPhysicalDeviceRobustness2FeaturesEXT robcopy;
    VkBaseOutStructure head = { .pNext = (VkBaseOutStructure *)in->pNext };
    for (VkBaseOutStructure *prev = &head; prev->pNext; ) {
        VkBaseOutStructure *cur = prev->pNext;
        if (cur->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2) {
            f2copy = *(VkPhysicalDeviceFeatures2 *)cur;
            f2copy.features.geometryShader = VK_FALSE;
            f2copy.features.shaderCullDistance = VK_FALSE;
            prev->pNext = (VkBaseOutStructure *)&f2copy;
            prev = (VkBaseOutStructure *)&f2copy;
        } else if (cur->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT) {
            robcopy = *(VkPhysicalDeviceRobustness2FeaturesEXT *)cur;
            robcopy.robustBufferAccess2 = VK_FALSE;
            robcopy.nullDescriptor = VK_FALSE;
            prev->pNext = (VkBaseOutStructure *)&robcopy;
            prev = (VkBaseOutStructure *)&robcopy;
        } else if (cur->sType == VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT) {
            prev->pNext = cur->pNext;
        } else {
            prev = cur;
        }
    }
    ci.pNext = head.pNext;

    VkResult r = real_create_device(pd, &ci, alloc, out);
    logf_("vkCreateDevice -> %d (extensions %u -> %u)", r, in->enabledExtensionCount, ne);
    return r;
}

/* ---- exported entry points --------------------------------------------- */

__attribute__((visibility("default")))
PFN_vkVoidFunction VKAPI_CALL vkGetDeviceProcAddr(VkDevice device, const char *name)
{
    load_real();
    return real_gdpa(device, name);
}

__attribute__((visibility("default")))
PFN_vkVoidFunction VKAPI_CALL vkGetInstanceProcAddr(VkInstance instance, const char *name)
{
    load_real();
    PFN_vkVoidFunction p = real_gipa(instance, name);
    if (!p || !name) return p;
    if (!strcmp(name, "vkGetInstanceProcAddr")) return (PFN_vkVoidFunction)vkGetInstanceProcAddr;
    if (!strcmp(name, "vkGetDeviceProcAddr"))   return (PFN_vkVoidFunction)vkGetDeviceProcAddr;
    if (!strcmp(name, "vkGetPhysicalDeviceFeatures"))          { real_features      = (PFN_vkGetPhysicalDeviceFeatures)p;           return (PFN_vkVoidFunction)shim_features; }
    if (!strcmp(name, "vkGetPhysicalDeviceFeatures2"))         { real_features2     = (PFN_vkGetPhysicalDeviceFeatures2)p;          return (PFN_vkVoidFunction)shim_features2; }
    if (!strcmp(name, "vkGetPhysicalDeviceFeatures2KHR"))      { real_features2khr  = (PFN_vkGetPhysicalDeviceFeatures2)p;          return (PFN_vkVoidFunction)shim_features2khr; }
    if (!strcmp(name, "vkEnumerateDeviceExtensionProperties")) { real_enum_ext      = (PFN_vkEnumerateDeviceExtensionProperties)p;  return (PFN_vkVoidFunction)shim_enum_ext; }
    if (!strcmp(name, "vkCreateDevice"))                       { real_create_device = (PFN_vkCreateDevice)p;                        return (PFN_vkVoidFunction)shim_create_device; }
    return p;
}

__attribute__((visibility("default")))
VkResult VKAPI_CALL vkCreateInstance(const VkInstanceCreateInfo *ci, const VkAllocationCallbacks *alloc, VkInstance *out)
{
    load_real();
    return ((PFN_vkCreateInstance)dlsym(real, "vkCreateInstance"))(ci, alloc, out);
}

__attribute__((visibility("default")))
VkResult VKAPI_CALL vkEnumerateInstanceExtensionProperties(const char *layer, uint32_t *count, VkExtensionProperties *props)
{
    load_real();
    return ((PFN_vkEnumerateInstanceExtensionProperties)dlsym(real, "vkEnumerateInstanceExtensionProperties"))(layer, count, props);
}

__attribute__((visibility("default")))
VkResult VKAPI_CALL vkEnumerateInstanceVersion(uint32_t *version)
{
    load_real();
    return ((PFN_vkEnumerateInstanceVersion)dlsym(real, "vkEnumerateInstanceVersion"))(version);
}

__attribute__((visibility("default")))
VkResult VKAPI_CALL vkEnumerateInstanceLayerProperties(uint32_t *count, VkLayerProperties *props)
{
    load_real();
    return ((PFN_vkEnumerateInstanceLayerProperties)dlsym(real, "vkEnumerateInstanceLayerProperties"))(count, props);
}
