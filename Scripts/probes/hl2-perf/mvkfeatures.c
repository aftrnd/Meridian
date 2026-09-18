/*
 * mvkfeatures — native macOS dump of what a MoltenVK dylib actually advertises,
 * limited to the features DXVK 3.1.1 marks required (dxvk_device_info.cpp
 * getFeatureList). Runs outside Wine so the gap is visible in one shot.
 *
 * Build (headers from the MoltenVK release tar):
 *   clang -O1 -I/tmp/dl/mvk/MoltenVK/MoltenVK/include -o mvkfeatures mvkfeatures.c
 * Run:  ./mvkfeatures /tmp/engine-gm/lib64/libMoltenVK.real.dylib
 */
#define VK_NO_PROTOTYPES
#include <vulkan/vulkan.h>
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>

#define F(x) printf("  %-44s %s\n", #x, (x) ? "yes" : "NO")

int main(int argc, char **argv)
{
    const char *path = argc > 1 ? argv[1] : "libMoltenVK.dylib";
    void *lib = dlopen(path, RTLD_NOW);
    if (!lib) { fprintf(stderr, "dlopen %s: %s\n", path, dlerror()); return 1; }
    PFN_vkGetInstanceProcAddr gipa = (PFN_vkGetInstanceProcAddr)dlsym(lib, "vkGetInstanceProcAddr");
#define LOAD(inst, name) PFN_##name name = (PFN_##name)gipa(inst, #name)
    LOAD(NULL, vkCreateInstance);
    LOAD(NULL, vkEnumerateInstanceVersion);
    uint32_t apiVersion = 0; vkEnumerateInstanceVersion(&apiVersion);
    printf("%s\ninstance Vulkan %u.%u.%u\n", path, VK_API_VERSION_MAJOR(apiVersion), VK_API_VERSION_MINOR(apiVersion), VK_API_VERSION_PATCH(apiVersion));

    VkApplicationInfo app = { .sType = VK_STRUCTURE_TYPE_APPLICATION_INFO, .apiVersion = VK_API_VERSION_1_3 };
    VkInstanceCreateInfo ici = { .sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO, .pApplicationInfo = &app };
    VkInstance inst; if (vkCreateInstance(&ici, NULL, &inst) != VK_SUCCESS) { fprintf(stderr, "vkCreateInstance failed\n"); return 1; }
    LOAD(inst, vkEnumeratePhysicalDevices);
    LOAD(inst, vkGetPhysicalDeviceFeatures2);
    LOAD(inst, vkGetPhysicalDeviceProperties);
    LOAD(inst, vkEnumerateDeviceExtensionProperties);
    uint32_t n = 1; VkPhysicalDevice pd; vkEnumeratePhysicalDevices(inst, &n, &pd);
    VkPhysicalDeviceProperties props; vkGetPhysicalDeviceProperties(pd, &props);
    printf("device %s  apiVersion %u.%u.%u\n", props.deviceName, VK_API_VERSION_MAJOR(props.apiVersion), VK_API_VERSION_MINOR(props.apiVersion), VK_API_VERSION_PATCH(props.apiVersion));

    VkPhysicalDeviceVulkan11Features v11 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_1_FEATURES };
    VkPhysicalDeviceVulkan12Features v12 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_2_FEATURES, .pNext = &v11 };
    VkPhysicalDeviceVulkan13Features v13 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_VULKAN_1_3_FEATURES, .pNext = &v12 };
    VkPhysicalDeviceDepthClipEnableFeaturesEXT dce = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_DEPTH_CLIP_ENABLE_FEATURES_EXT, .pNext = &v13 };
    VkPhysicalDeviceRobustness2FeaturesEXT rob = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_ROBUSTNESS_2_FEATURES_EXT, .pNext = &dce };
    VkPhysicalDeviceMaintenance5FeaturesKHR m5 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_5_FEATURES_KHR, .pNext = &rob };
    VkPhysicalDeviceMaintenance6FeaturesKHR m6 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_MAINTENANCE_6_FEATURES_KHR, .pNext = &m5 };
    VkPhysicalDeviceFeatures2 f2 = { .sType = VK_STRUCTURE_TYPE_PHYSICAL_DEVICE_FEATURES_2, .pNext = &m6 };
    vkGetPhysicalDeviceFeatures2(pd, &f2);
    VkPhysicalDeviceFeatures *c = &f2.features;

    printf("core (DXVK 3.1.1 required):\n");
    F(c->depthBiasClamp); F(c->depthClamp); F(c->dualSrcBlend); F(c->fillModeNonSolid); F(c->fragmentStoresAndAtomics);
    F(c->fullDrawIndexUint32); F(c->geometryShader); F(c->imageCubeArray); F(c->independentBlend); F(c->multiDrawIndirect);
    F(c->multiViewport); F(c->occlusionQueryPrecise); F(c->robustBufferAccess); F(c->sampleRateShading); F(c->samplerAnisotropy);
    F(c->shaderClipDistance); F(c->shaderCullDistance); F(c->shaderImageGatherExtended); F(c->shaderInt16); F(c->shaderInt64);
    F(c->shaderSampledImageArrayDynamicIndexing); F(c->textureCompressionBC);
    printf("vk11:\n"); F(v11.shaderDrawParameters); F(v11.storageBuffer16BitAccess);
    printf("vk12:\n"); F(v12.bufferDeviceAddress); F(v12.descriptorIndexing); F(v12.storageBuffer8BitAccess);
    F(v12.descriptorBindingSampledImageUpdateAfterBind); F(v12.descriptorBindingUpdateUnusedWhilePending); F(v12.descriptorBindingPartiallyBound);
    F(v12.hostQueryReset); F(v12.runtimeDescriptorArray); F(v12.samplerMirrorClampToEdge); F(v12.scalarBlockLayout); F(v12.shaderInt8);
    F(v12.timelineSemaphore); F(v12.uniformBufferStandardLayout); F(v12.vulkanMemoryModel);
    printf("vk13:\n"); F(v13.inlineUniformBlock); F(v13.computeFullSubgroups); F(v13.dynamicRendering); F(v13.maintenance4);
    F(v13.shaderDemoteToHelperInvocation); F(v13.shaderZeroInitializeWorkgroupMemory); F(v13.subgroupSizeControl); F(v13.synchronization2);
    printf("ext features:\n"); F(dce.depthClipEnable); F(rob.robustBufferAccess2); F(rob.nullDescriptor); F(m5.maintenance5); F(m6.maintenance6);

    uint32_t en = 0; vkEnumerateDeviceExtensionProperties(pd, NULL, &en, NULL);
    VkExtensionProperties ext[512]; if (en > 512) en = 512; vkEnumerateDeviceExtensionProperties(pd, NULL, &en, ext);
    const char *want[] = { "VK_EXT_depth_clip_enable", "VK_EXT_robustness2", "VK_KHR_load_store_op_none", "VK_KHR_maintenance5", "VK_KHR_maintenance6", "VK_KHR_swapchain",
                           "VK_EXT_transform_feedback", "VK_EXT_custom_border_color", "VK_EXT_extended_dynamic_state3", "VK_EXT_graphics_pipeline_library", "VK_EXT_descriptor_buffer", "VK_EXT_descriptor_heap", "VK_EXT_non_seamless_cube_map", "VK_EXT_vertex_attribute_divisor", "VK_KHR_incremental_present", "VK_EXT_memory_budget", "VK_EXT_shader_stencil_export" };
    printf("device extensions (%u total):\n", en);
    for (size_t i = 0; i < sizeof want / sizeof *want; ++i) {
        int have = 0; for (uint32_t j = 0; j < en; ++j) if (!strcmp(ext[j].extensionName, want[i])) have = 1;
        printf("  %-44s %s\n", want[i], have ? "yes" : "NO");
    }
    return 0;
}
