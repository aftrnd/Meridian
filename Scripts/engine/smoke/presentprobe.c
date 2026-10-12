/*
 * presentprobe — D3D11 swap-chain presentation through the Mac driver.
 *
 * Opens a small window, creates a D3D11 device + swap chain on it, clears the
 * back buffer to a known colour and presents 60 frames, then copies the back
 * buffer to a staging texture and checks the pixel. This exercises the path a
 * game takes to the screen (DXMT's winemetal → Wine's winemac → CAMetalLayer),
 * which a headless device creation does not. Exit code 0 on success.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o presentprobe64.exe presentprobe.c -ld3d11 -ldxgi -luuid -lgdi32
 */
#define COBJMACROS
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <stdio.h>

static LRESULT CALLBACK wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp)
{
    return DefWindowProcA(hwnd, msg, wp, lp);
}

int main(void)
{
    WNDCLASSA wc = {0};
    wc.lpfnWndProc = wndproc;
    wc.hInstance = GetModuleHandleA(NULL);
    wc.lpszClassName = "presentprobe";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("presentprobe", "Meridian present probe", WS_OVERLAPPEDWINDOW | WS_VISIBLE,
                              100, 100, 320, 240, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) { printf("CreateWindow failed\n"); return 1; }

    DXGI_SWAP_CHAIN_DESC sd = {0};
    sd.BufferCount = 2;
    sd.BufferDesc.Width = 320;
    sd.BufferDesc.Height = 240;
    sd.BufferDesc.Format = DXGI_FORMAT_R8G8B8A8_UNORM;
    sd.BufferUsage = DXGI_USAGE_RENDER_TARGET_OUTPUT;
    sd.OutputWindow = hwnd;
    sd.SampleDesc.Count = 1;
    sd.Windowed = TRUE;
    sd.SwapEffect = DXGI_SWAP_EFFECT_FLIP_DISCARD;

    ID3D11Device *dev = NULL;
    ID3D11DeviceContext *ctx = NULL;
    IDXGISwapChain *sc = NULL;
    HRESULT hr = D3D11CreateDeviceAndSwapChain(NULL, D3D_DRIVER_TYPE_HARDWARE, NULL, 0, NULL, 0,
                                               D3D11_SDK_VERSION, &sd, &sc, &dev, NULL, &ctx);
    if (FAILED(hr)) { printf("D3D11CreateDeviceAndSwapChain failed: 0x%08lx\n", (unsigned long)hr); return 1; }

    ID3D11Texture2D *back = NULL;
    ID3D11RenderTargetView *rtv = NULL;
    IDXGISwapChain_GetBuffer(sc, 0, &IID_ID3D11Texture2D, (void **)&back);
    ID3D11Device_CreateRenderTargetView(dev, (ID3D11Resource *)back, NULL, &rtv);

    const float colour[4] = {0.0f, 0.5f, 1.0f, 1.0f};
    int presented = 0;
    for (int i = 0; i < 60; i++) {
        MSG msg;
        while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
        ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, colour);
        if (SUCCEEDED(IDXGISwapChain_Present(sc, 1, 0))) presented++;
    }

    /* Read the back buffer back after one more clear. */
    ID3D11DeviceContext_ClearRenderTargetView(ctx, rtv, colour);
    D3D11_TEXTURE2D_DESC td;
    ID3D11Texture2D_GetDesc(back, &td);
    td.Usage = D3D11_USAGE_STAGING;
    td.BindFlags = 0;
    td.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    td.MiscFlags = 0;
    ID3D11Texture2D *staging = NULL;
    ID3D11Device_CreateTexture2D(dev, &td, NULL, &staging);
    ID3D11DeviceContext_CopyResource(ctx, (ID3D11Resource *)staging, (ID3D11Resource *)back);
    D3D11_MAPPED_SUBRESOURCE m;
    unsigned px = 0;
    if (SUCCEEDED(ID3D11DeviceContext_Map(ctx, (ID3D11Resource *)staging, 0, D3D11_MAP_READ, 0, &m))) {
        px = *(unsigned *)m.pData;
        ID3D11DeviceContext_Unmap(ctx, (ID3D11Resource *)staging, 0);
    }
    printf("presented %d/60 frames, pixel=0x%08x\n", presented, px);
    DestroyWindow(hwnd);
    /* R8G8B8A8: R=0x00 G=0x80 B=0xff A=0xff → little-endian 0xffff8000 (G may round to 0x7f). */
    return presented == 60 && (px & 0xffff00ff) == 0xffff0000 ? 0 : 1;
}
