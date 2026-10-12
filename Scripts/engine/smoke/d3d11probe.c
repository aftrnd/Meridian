/*
 * d3d11probe — headless check of which D3D11 implementation Wine loads.
 *
 * Creates a hardware D3D11 device (no window, no swap chain), then prints the
 * path of the d3d11.dll that was mapped and the DXGI adapter description.
 * Exit code 0 when a device was created.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o d3d11probe64.exe d3d11probe.c -ld3d11 -ldxgi -luuid
 *        i686-w64-mingw32-gcc   -O2 -o d3d11probe32.exe d3d11probe.c -ld3d11 -ldxgi -luuid
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

int main(void)
{
    ID3D11Device *device = NULL;
    D3D_FEATURE_LEVEL level = 0;
    HRESULT hr = D3D11CreateDevice(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                   D3D11_SDK_VERSION, &device, &level, NULL);
    char path[MAX_PATH] = "";
    GetModuleFileNameA(GetModuleHandleA("d3d11.dll"), path, sizeof(path));
    printf("d3d11.dll: %s\n", path);
    if (FAILED(hr)) {
        printf("D3D11CreateDevice failed: 0x%08lx\n", (unsigned long)hr);
        return 1;
    }
    printf("feature level: 0x%x\n", (unsigned)level);

    IDXGIDevice *dxgi = NULL;
    IDXGIAdapter *adapter = NULL;
    DXGI_ADAPTER_DESC desc;
    if (SUCCEEDED(ID3D11Device_QueryInterface(device, &IID_IDXGIDevice, (void **)&dxgi)) &&
        SUCCEEDED(IDXGIDevice_GetAdapter(dxgi, &adapter)) &&
        SUCCEEDED(IDXGIAdapter_GetDesc(adapter, &desc))) {
        printf("adapter: %ls (vendor 0x%04x)\n", desc.Description, desc.VendorId);
    }
    GetModuleFileNameA(GetModuleHandleA("dxgi.dll"), path, sizeof(path));
    printf("dxgi.dll: %s\n", path);
    return 0;
}
