/*
 * d3d9probe — headless Direct3D 9 render-path discriminator (Sep 2026).
 *
 * Draws a full-screen quad through a vs_2_0/ps_2_0 pair that samples a texture
 * and multiplies by a constant (so DXVK emits its cbuffer + render-state +
 * sampler bindings, the layout that fails MSL compile under 32-bit DXVK on the
 * CX engine — Pattern 27). Reads the back buffer back with GetRenderTargetData
 * and prints the centre pixel, so PASS/FAIL needs no screenshot and works on a
 * captured display. Also prints what the runtime reports as the adapter and
 * available texture memory — what Source's dxsupport.cfg logic sees.
 *
 * Build (mingw-w64, both bitnesses):
 *   x86_64-w64-mingw32-gcc -O1 -o d3d9probe64.exe d3d9probe.c -ld3d9 -lgdi32 -luser32
 *   i686-w64-mingw32-gcc   -O1 -o d3d9probe32.exe d3d9probe.c -ld3d9 -lgdi32 -luser32
 * Run: d3d9probe.sh <gl|dxvk> <32|64>
 */
#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <d3d9.h>
#include <d3dcommon.h>
#include <stdio.h>
#include <string.h>

typedef HRESULT (WINAPI *PFN_D3DCompile)(LPCVOID, SIZE_T, LPCSTR, const void *, void *,
                                         LPCSTR, LPCSTR, UINT, UINT, void **, void **);

static const char *VS =
    "struct VSIn { float3 pos : POSITION; float2 uv : TEXCOORD0; };\n"
    "struct VSOut { float4 pos : POSITION; float2 uv : TEXCOORD0; };\n"
    "VSOut main(VSIn i) { VSOut o; o.pos = float4(i.pos, 1.0); o.uv = i.uv; return o; }\n";

static const char *PS =
    "sampler2D s0 : register(s0);\n"
    "float4 tint : register(c0);\n"
    "float4 main(float2 uv : TEXCOORD0) : COLOR { return tex2D(s0, uv) * tint; }\n";

struct Vertex { float x, y, z, u, v; };

static LRESULT CALLBACK wndproc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    if (m == WM_DESTROY) { PostQuitMessage(0); return 0; }
    return DefWindowProcA(h, m, w, l);
}

static void pump(void)
{
    MSG msg;
    while (PeekMessageA(&msg, NULL, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageA(&msg); }
}

static int fail(const char *what, HRESULT hr)
{
    printf("FAIL %s hr=0x%08lx\n", what, (unsigned long)hr);
    fflush(stdout);
    return 1;
}

int main(void)
{
    printf("d3d9probe %u-bit\n", (unsigned)(sizeof(void *) * 8));
    fflush(stdout);

    WNDCLASSA wc = {0};
    wc.lpfnWndProc = wndproc; wc.hInstance = GetModuleHandleA(NULL); wc.lpszClassName = "d3d9probe";
    RegisterClassA(&wc);
    HWND hwnd = CreateWindowA("d3d9probe", "d3d9probe", WS_OVERLAPPEDWINDOW,
                              64, 64, 256, 256, NULL, NULL, wc.hInstance, NULL);
    if (!hwnd) return fail("CreateWindow", 0);

    IDirect3D9 *d3d = Direct3DCreate9(D3D_SDK_VERSION);
    if (!d3d) return fail("Direct3DCreate9", 0);

    D3DADAPTER_IDENTIFIER9 id;
    if (SUCCEEDED(IDirect3D9_GetAdapterIdentifier(d3d, 0, 0, &id)))
        printf("ADAPTER desc=\"%s\" driver=\"%s\" vendor=0x%04lx device=0x%04lx driverver=%lu.%lu.%lu.%lu\n",
               id.Description, id.Driver, (unsigned long)id.VendorId, (unsigned long)id.DeviceId,
               (unsigned long)HIWORD(id.DriverVersion.HighPart), (unsigned long)LOWORD(id.DriverVersion.HighPart),
               (unsigned long)HIWORD(id.DriverVersion.LowPart), (unsigned long)LOWORD(id.DriverVersion.LowPart));

    D3DPRESENT_PARAMETERS pp = {0};
    pp.Windowed = TRUE; pp.SwapEffect = D3DSWAPEFFECT_DISCARD;
    pp.BackBufferFormat = D3DFMT_X8R8G8B8; pp.BackBufferWidth = 256; pp.BackBufferHeight = 256;
    pp.BackBufferCount = 1; pp.hDeviceWindow = hwnd;
    pp.PresentationInterval = D3DPRESENT_INTERVAL_IMMEDIATE;

    IDirect3DDevice9 *dev = NULL;
    HRESULT hr = IDirect3D9_CreateDevice(d3d, D3DADAPTER_DEFAULT, D3DDEVTYPE_HAL, hwnd,
                                         D3DCREATE_HARDWARE_VERTEXPROCESSING | D3DCREATE_FPU_PRESERVE, &pp, &dev);
    if (FAILED(hr)) return fail("CreateDevice", hr);

    D3DCAPS9 caps;
    if (SUCCEEDED(IDirect3DDevice9_GetDeviceCaps(dev, &caps)))
        printf("CAPS vs=%lx ps=%lx maxtex=%lux%lu maxaniso=%lu\n",
               (unsigned long)caps.VertexShaderVersion, (unsigned long)caps.PixelShaderVersion,
               (unsigned long)caps.MaxTextureWidth, (unsigned long)caps.MaxTextureHeight,
               (unsigned long)caps.MaxAnisotropy);
    printf("TEXMEM available=%u MB\n", (unsigned)(IDirect3DDevice9_GetAvailableTextureMem(dev) / (1024u * 1024u)));

    /* Depth-texture formats Source probes (DF16/DF24/RAWZ/INTZ + NULL). */
    static const struct { const char *name; D3DFORMAT fmt; } probes[] = {
        { "DF16", (D3DFORMAT)MAKEFOURCC('D','F','1','6') }, { "DF24", (D3DFORMAT)MAKEFOURCC('D','F','2','4') },
        { "RAWZ", (D3DFORMAT)MAKEFOURCC('R','A','W','Z') }, { "INTZ", (D3DFORMAT)MAKEFOURCC('I','N','T','Z') },
        { "NULL", (D3DFORMAT)MAKEFOURCC('N','U','L','L') }, { "D24S8", D3DFMT_D24S8 }, { "D16", D3DFMT_D16 },
    };
    printf("FORMATS");
    for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); ++i) {
        HRESULT f = IDirect3D9_CheckDeviceFormat(d3d, 0, D3DDEVTYPE_HAL, D3DFMT_X8R8G8B8,
                                                 D3DUSAGE_DEPTHSTENCIL, D3DRTYPE_TEXTURE, probes[i].fmt);
        printf(" %s=%s", probes[i].name, SUCCEEDED(f) ? "yes" : "no");
    }
    printf("\n");
    fflush(stdout);

    /* Shaders via the runtime HLSL compiler (Wine builtin d3dcompiler → vkd3d-shader). */
    HMODULE dc = LoadLibraryA("d3dcompiler_47.dll");
    if (!dc) dc = LoadLibraryA("d3dcompiler_43.dll");
    if (!dc) return fail("LoadLibrary d3dcompiler", 0);
    PFN_D3DCompile compile = (PFN_D3DCompile)GetProcAddress(dc, "D3DCompile");
    if (!compile) return fail("GetProcAddress D3DCompile", 0);

    ID3DBlob *vsb = NULL, *psb = NULL, *err = NULL;
    hr = compile(VS, strlen(VS), "vs", NULL, NULL, "main", "vs_2_0", 0, 0, (void **)&vsb, (void **)&err);
    if (FAILED(hr)) { if (err) printf("%s\n", (char *)ID3D10Blob_GetBufferPointer(err)); return fail("D3DCompile vs", hr); }
    hr = compile(PS, strlen(PS), "ps", NULL, NULL, "main", "ps_2_0", 0, 0, (void **)&psb, (void **)&err);
    if (FAILED(hr)) { if (err) printf("%s\n", (char *)ID3D10Blob_GetBufferPointer(err)); return fail("D3DCompile ps", hr); }

    IDirect3DVertexShader9 *vs = NULL; IDirect3DPixelShader9 *ps = NULL;
    hr = IDirect3DDevice9_CreateVertexShader(dev, (const DWORD *)ID3D10Blob_GetBufferPointer(vsb), &vs);
    if (FAILED(hr)) return fail("CreateVertexShader", hr);
    hr = IDirect3DDevice9_CreatePixelShader(dev, (const DWORD *)ID3D10Blob_GetBufferPointer(psb), &ps);
    if (FAILED(hr)) return fail("CreatePixelShader", hr);

    /* 2×2 texture, every texel (R=200, G=100, B=50). */
    IDirect3DTexture9 *tex = NULL;
    hr = IDirect3DDevice9_CreateTexture(dev, 2, 2, 1, 0, D3DFMT_A8R8G8B8, D3DPOOL_MANAGED, &tex, NULL);
    if (FAILED(hr)) return fail("CreateTexture", hr);
    D3DLOCKED_RECT lr;
    if (SUCCEEDED(IDirect3DTexture9_LockRect(tex, 0, &lr, NULL, 0))) {
        for (int y = 0; y < 2; ++y) {
            DWORD *row = (DWORD *)((BYTE *)lr.pBits + y * lr.Pitch);
            row[0] = row[1] = 0xFFC86432u; /* A=FF R=C8 G=64 B=32 */
        }
        IDirect3DTexture9_UnlockRect(tex, 0);
    }

    static const D3DVERTEXELEMENT9 decl[] = {
        { 0, 0,  D3DDECLTYPE_FLOAT3, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_POSITION, 0 },
        { 0, 12, D3DDECLTYPE_FLOAT2, D3DDECLMETHOD_DEFAULT, D3DDECLUSAGE_TEXCOORD, 0 },
        D3DDECL_END()
    };
    IDirect3DVertexDeclaration9 *vdecl = NULL;
    hr = IDirect3DDevice9_CreateVertexDeclaration(dev, decl, &vdecl);
    if (FAILED(hr)) return fail("CreateVertexDeclaration", hr);

    static const struct Vertex quad[4] = {
        { -1.f, -1.f, 0.5f, 0.f, 1.f }, { -1.f, 1.f, 0.5f, 0.f, 0.f },
        {  1.f, -1.f, 0.5f, 1.f, 1.f }, {  1.f, 1.f, 0.5f, 1.f, 0.f },
    };
    IDirect3DVertexBuffer9 *vb = NULL;
    hr = IDirect3DDevice9_CreateVertexBuffer(dev, sizeof(quad), 0, 0, D3DPOOL_MANAGED, &vb, NULL);
    if (FAILED(hr)) return fail("CreateVertexBuffer", hr);
    void *vp = NULL;
    if (SUCCEEDED(IDirect3DVertexBuffer9_Lock(vb, 0, 0, &vp, 0))) { memcpy(vp, quad, sizeof(quad)); IDirect3DVertexBuffer9_Unlock(vb); }

    /* tint = (0.5, 1, 1, 1) → expected pixel R=100 G=100 B=50 (±2). */
    static const float tint[4] = { 0.5f, 1.f, 1.f, 1.f };

    IDirect3DSurface9 *bb = NULL, *sys = NULL;
    IDirect3DDevice9_GetBackBuffer(dev, 0, 0, D3DBACKBUFFER_TYPE_MONO, &bb);
    IDirect3DDevice9_CreateOffscreenPlainSurface(dev, 256, 256, D3DFMT_X8R8G8B8, D3DPOOL_SYSTEMMEM, &sys, NULL);

    int result = 1;
    DWORD t0 = GetTickCount();
    for (int frame = 0; frame < 30; ++frame) {
        pump();
        if (GetTickCount() - t0 > 5000) {
            printf("FAIL render timeout after 5000 ms\n");
            break;
        }
        IDirect3DDevice9_Clear(dev, 0, NULL, D3DCLEAR_TARGET, D3DCOLOR_XRGB(0, 0, 255), 1.f, 0);
        IDirect3DDevice9_BeginScene(dev);
        IDirect3DDevice9_SetVertexDeclaration(dev, vdecl);
        IDirect3DDevice9_SetStreamSource(dev, 0, vb, 0, sizeof(struct Vertex));
        IDirect3DDevice9_SetVertexShader(dev, vs);
        IDirect3DDevice9_SetPixelShader(dev, ps);
        IDirect3DDevice9_SetPixelShaderConstantF(dev, 0, tint, 1);
        IDirect3DDevice9_SetTexture(dev, 0, (IDirect3DBaseTexture9 *)tex);
        IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MINFILTER, D3DTEXF_LINEAR);
        IDirect3DDevice9_SetSamplerState(dev, 0, D3DSAMP_MAGFILTER, D3DTEXF_LINEAR);
        IDirect3DDevice9_SetRenderState(dev, D3DRS_CULLMODE, D3DCULL_NONE);
        IDirect3DDevice9_SetRenderState(dev, D3DRS_ZENABLE, FALSE);
        IDirect3DDevice9_SetRenderState(dev, D3DRS_LIGHTING, FALSE);
        IDirect3DDevice9_DrawPrimitive(dev, D3DPT_TRIANGLESTRIP, 0, 2);
        IDirect3DDevice9_EndScene(dev);

        if (frame == 29 && bb && sys) {
            hr = IDirect3DDevice9_GetRenderTargetData(dev, bb, sys);
            if (FAILED(hr)) { fail("GetRenderTargetData", hr); break; }
            if (SUCCEEDED(IDirect3DSurface9_LockRect(sys, &lr, NULL, D3DLOCK_READONLY))) {
                DWORD px = *(DWORD *)((BYTE *)lr.pBits + 128 * lr.Pitch + 128 * 4);
                DWORD corner = *(DWORD *)((BYTE *)lr.pBits + 2 * lr.Pitch + 2 * 4);
                IDirect3DSurface9_UnlockRect(sys);
                int r = (px >> 16) & 0xff, g = (px >> 8) & 0xff, b = px & 0xff;
                printf("PIXEL centre=%d,%d,%d corner=0x%06lx expected=100,100,50\n", r, g, b, (unsigned long)(corner & 0xffffff));
                result = (r >= 97 && r <= 103 && g >= 97 && g <= 103 && b >= 47 && b <= 53) ? 0 : 1;
            }
        }
        hr = IDirect3DDevice9_Present(dev, NULL, NULL, NULL, NULL);
        if (FAILED(hr)) { fail("Present", hr); break; }
    }
    printf("FRAMES 30 in %lu ms\n", (unsigned long)(GetTickCount() - t0));
    printf("RESULT %s\n", result == 0 ? "PASS" : "FAIL");
    fflush(stdout);
    DestroyWindow(hwnd);
    return result;
}
