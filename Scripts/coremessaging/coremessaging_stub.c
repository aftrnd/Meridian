/*
 * coremessaging_stub.c — Custom replacement for Wine's coremessaging.dll
 *
 * Extends Wine's existing DispatcherQueueController implementation with
 * a stub activation factory for Windows.System.DispatcherQueue itself.
 *
 * Problem: Unity 6.3+ calls RoGetActivationFactory("Windows.System.DispatcherQueue")
 *   to get IDispatcherQueueStatics::GetForCurrentThread(). Wine's shipped
 *   coremessaging.dll only handles DispatcherQueueController in
 *   DllGetActivationFactory — returns CLASS_E_CLASSNOTAVAILABLE for DispatcherQueue.
 *   Unity treats this as fatal and crashes immediately after D3D11 init.
 *
 * Fix: This replacement handles both class names.
 *   DispatcherQueueController → existing Wine stub (unchanged)
 *   DispatcherQueue           → new stub returning a minimal IDispatcherQueue
 *
 * GetForCurrentThread() returns a static stub IDispatcherQueue.
 * TryEnqueue returns S_OK/TRUE (work accepted but not actually run — Unity only
 * needs the initialization to not fail, it doesn't need actual dispatch).
 *
 * Cross-compiled with: x86_64-w64-mingw32-gcc
 * Based on Wine dlls/coremessaging/main.c (Wine master, Mohamad Al-Jaf, 2024)
 *
 * Meridian engine — open source component, LGPL compatible.
 */

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdint.h>
#include <stdlib.h>

/* -----------------------------------------------------------------------
 * HSTRING shim (we only need the raw buffer accessor)
 * ----------------------------------------------------------------------- */

typedef void *HSTRING;
typedef const WCHAR *(WINAPI *PFN_WindowsGetStringRawBuffer)(HSTRING, UINT32 *);
static PFN_WindowsGetStringRawBuffer pfn_WindowsGetStringRawBuffer;

static const WCHAR *get_string(HSTRING h)
{
    if (!pfn_WindowsGetStringRawBuffer) {
        HMODULE mod = GetModuleHandleA("combase.dll");
        if (!mod) mod = LoadLibraryA("combase.dll");
        if (mod)
            pfn_WindowsGetStringRawBuffer =
                (PFN_WindowsGetStringRawBuffer)GetProcAddress(mod, "WindowsGetStringRawBuffer");
    }
    if (!pfn_WindowsGetStringRawBuffer) return L"";
    return pfn_WindowsGetStringRawBuffer(h, NULL);
}

/* -----------------------------------------------------------------------
 * GUIDs
 * ----------------------------------------------------------------------- */

static const GUID IID_IUnknown_ =
    {0x00000000,0x0000,0x0000,{0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}};
static const GUID IID_IInspectable_ =
    {0xAF86E2E0,0xB12D,0x4C6A,{0x9C,0x5A,0xD7,0xAA,0x65,0x10,0x1E,0x90}};
static const GUID IID_IAgileObject_ =
    {0x94EA2B94,0xE9CC,0x49E0,{0xC0,0xFF,0xEE,0x64,0xCA,0x8F,0x5B,0x90}};
static const GUID IID_IActivationFactory_ =
    {0x00000035,0x0000,0x0000,{0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}};

/* IDispatcherQueueStatics: a96d83d7-9371-4517-9245-d0824ac12c74 */
static const GUID IID_IDispatcherQueueStatics_ =
    {0xa96d83d7,0x9371,0x4517,{0x92,0x45,0xd0,0x82,0x4a,0xc1,0x2c,0x74}};

/* IDispatcherQueue: 603e88e4-a338-4ffe-a457-a5cfb9ceb899 */
static const GUID IID_IDispatcherQueue_ =
    {0x603e88e4,0xa338,0x4ffe,{0xa4,0x57,0xa5,0xcf,0xb9,0xce,0xb8,0x99}};

/* IDispatcherQueueController: 22f34e66-50db-4e36-a98d-61c01b384d20 */
static const GUID IID_IDispatcherQueueController_ =
    {0x22f34e66,0x50db,0x4e36,{0xa9,0x8d,0x61,0xc0,0x1b,0x38,0x4d,0x20}};

/* IDispatcherQueueControllerStatics: 0a6c98e0-5198-49a2-a313-3f70d1f13c27 */
static const GUID IID_IDispatcherQueueControllerStatics_ =
    {0x0a6c98e0,0x5198,0x49a2,{0xa3,0x13,0x3f,0x70,0xd1,0xf1,0x3c,0x27}};

static inline int guid_eq(REFIID a, const GUID *b)
{
    return memcmp(a, b, sizeof(GUID)) == 0;
}

/* -----------------------------------------------------------------------
 * Forward declarations
 * ----------------------------------------------------------------------- */

typedef struct IDispatcherQueueVtbl    IDispatcherQueueVtbl;
typedef struct IDispatcherQueue_       IDispatcherQueue_;

typedef struct IDispatcherQueueStaticsVtbl    IDispatcherQueueStaticsVtbl;
typedef struct IDispatcherQueueStatics_       IDispatcherQueueStatics_;

typedef struct IDispatcherQueueControllerVtbl      IDispatcherQueueControllerVtbl;
typedef struct IDispatcherQueueController_         IDispatcherQueueController_;
typedef struct IDispatcherQueueControllerStaticsVtbl IDispatcherQueueControllerStaticsVtbl;
typedef struct IDispatcherQueueControllerStatics_   IDispatcherQueueControllerStatics_;

/* -----------------------------------------------------------------------
 * Stub IDispatcherQueue
 * ----------------------------------------------------------------------- */

struct IDispatcherQueueVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDispatcherQueue_ *, REFIID, void **);
    ULONG   (STDMETHODCALLTYPE *AddRef)        (IDispatcherQueue_ *);
    ULONG   (STDMETHODCALLTYPE *Release)       (IDispatcherQueue_ *);
    HRESULT (STDMETHODCALLTYPE *GetIids)       (IDispatcherQueue_ *, ULONG *, IID **);
    HRESULT (STDMETHODCALLTYPE *GetRuntimeClassName)(IDispatcherQueue_ *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *GetTrustLevel) (IDispatcherQueue_ *, INT32 *);
    /* IDispatcherQueue methods */
    HRESULT (STDMETHODCALLTYPE *CreateTimer)              (IDispatcherQueue_ *, void **);
    HRESULT (STDMETHODCALLTYPE *TryEnqueue)               (IDispatcherQueue_ *, void *, BOOL *);
    HRESULT (STDMETHODCALLTYPE *TryEnqueueWithPriority)   (IDispatcherQueue_ *, INT32, void *, BOOL *);
    HRESULT (STDMETHODCALLTYPE *add_ShutdownStarting)     (IDispatcherQueue_ *, void *, INT64 *);
    HRESULT (STDMETHODCALLTYPE *remove_ShutdownStarting)  (IDispatcherQueue_ *, INT64);
    HRESULT (STDMETHODCALLTYPE *add_ShutdownCompleted)    (IDispatcherQueue_ *, void *, INT64 *);
    HRESULT (STDMETHODCALLTYPE *remove_ShutdownCompleted) (IDispatcherQueue_ *, INT64);
};

struct IDispatcherQueue_ { const IDispatcherQueueVtbl *lpVtbl; };

static HRESULT STDMETHODCALLTYPE dq_QueryInterface(IDispatcherQueue_ *This, REFIID iid, void **out)
{
    if (guid_eq(iid, &IID_IUnknown_) || guid_eq(iid, &IID_IInspectable_) ||
        guid_eq(iid, &IID_IAgileObject_) || guid_eq(iid, &IID_IDispatcherQueue_))
    {
        *out = This;
        This->lpVtbl->AddRef(This);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG   STDMETHODCALLTYPE dq_AddRef (IDispatcherQueue_ *This) { (void)This; return 2; }
static ULONG   STDMETHODCALLTYPE dq_Release(IDispatcherQueue_ *This) { (void)This; return 1; }
static HRESULT STDMETHODCALLTYPE dq_GetIids(IDispatcherQueue_ *T, ULONG *c, IID **i) { (void)T; *c=0; *i=NULL; return S_OK; }
static HRESULT STDMETHODCALLTYPE dq_GetRuntimeClassName(IDispatcherQueue_ *T, HSTRING *h) { (void)T; *h=NULL; return S_OK; }
static HRESULT STDMETHODCALLTYPE dq_GetTrustLevel(IDispatcherQueue_ *T, INT32 *lv) { (void)T; *lv=0; return S_OK; }
static HRESULT STDMETHODCALLTYPE dq_CreateTimer(IDispatcherQueue_ *T, void **r) { (void)T; *r=NULL; return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE dq_TryEnqueue(IDispatcherQueue_ *T, void *cb, BOOL *r)
    { (void)T; (void)cb; *r=TRUE; return S_OK; }
static HRESULT STDMETHODCALLTYPE dq_TryEnqueueWithPriority(IDispatcherQueue_ *T, INT32 p, void *cb, BOOL *r)
    { (void)T; (void)p; (void)cb; *r=TRUE; return S_OK; }
static HRESULT STDMETHODCALLTYPE dq_add_ShutdownStarting(IDispatcherQueue_ *T, void *h, INT64 *t)
    { (void)T; (void)h; *t=0; return S_OK; }
static HRESULT STDMETHODCALLTYPE dq_remove_ShutdownStarting(IDispatcherQueue_ *T, INT64 t)
    { (void)T; (void)t; return S_OK; }
static HRESULT STDMETHODCALLTYPE dq_add_ShutdownCompleted(IDispatcherQueue_ *T, void *h, INT64 *t)
    { (void)T; (void)h; *t=0; return S_OK; }
static HRESULT STDMETHODCALLTYPE dq_remove_ShutdownCompleted(IDispatcherQueue_ *T, INT64 t)
    { (void)T; (void)t; return S_OK; }

static const IDispatcherQueueVtbl dq_vtbl = {
    dq_QueryInterface, dq_AddRef, dq_Release,
    dq_GetIids, dq_GetRuntimeClassName, dq_GetTrustLevel,
    dq_CreateTimer, dq_TryEnqueue, dq_TryEnqueueWithPriority,
    dq_add_ShutdownStarting, dq_remove_ShutdownStarting,
    dq_add_ShutdownCompleted, dq_remove_ShutdownCompleted,
};
static IDispatcherQueue_ g_stub_queue = { &dq_vtbl };

/* -----------------------------------------------------------------------
 * IDispatcherQueueStatics activation factory
 * ----------------------------------------------------------------------- */

struct IDispatcherQueueStaticsVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDispatcherQueueStatics_ *, REFIID, void **);
    ULONG   (STDMETHODCALLTYPE *AddRef)        (IDispatcherQueueStatics_ *);
    ULONG   (STDMETHODCALLTYPE *Release)       (IDispatcherQueueStatics_ *);
    HRESULT (STDMETHODCALLTYPE *GetIids)       (IDispatcherQueueStatics_ *, ULONG *, IID **);
    HRESULT (STDMETHODCALLTYPE *GetRuntimeClassName)(IDispatcherQueueStatics_ *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *GetTrustLevel) (IDispatcherQueueStatics_ *, INT32 *);
    HRESULT (STDMETHODCALLTYPE *ActivateInstance)(IDispatcherQueueStatics_ *, void **);
    /* IDispatcherQueueStatics */
    HRESULT (STDMETHODCALLTYPE *GetForCurrentThread)(IDispatcherQueueStatics_ *, IDispatcherQueue_ **);
};

struct IDispatcherQueueStatics_ { const IDispatcherQueueStaticsVtbl *lpVtbl; };

static HRESULT STDMETHODCALLTYPE dqs_QueryInterface(IDispatcherQueueStatics_ *This, REFIID iid, void **out)
{
    if (guid_eq(iid, &IID_IUnknown_) || guid_eq(iid, &IID_IInspectable_) ||
        guid_eq(iid, &IID_IAgileObject_) || guid_eq(iid, &IID_IActivationFactory_) ||
        guid_eq(iid, &IID_IDispatcherQueueStatics_))
    {
        *out = This;
        This->lpVtbl->AddRef(This);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG   STDMETHODCALLTYPE dqs_AddRef (IDispatcherQueueStatics_ *T) { (void)T; return 2; }
static ULONG   STDMETHODCALLTYPE dqs_Release(IDispatcherQueueStatics_ *T) { (void)T; return 1; }
static HRESULT STDMETHODCALLTYPE dqs_GetIids(IDispatcherQueueStatics_ *T, ULONG *c, IID **i) { (void)T; *c=0; *i=NULL; return S_OK; }
static HRESULT STDMETHODCALLTYPE dqs_GetRuntimeClassName(IDispatcherQueueStatics_ *T, HSTRING *h) { (void)T; *h=NULL; return S_OK; }
static HRESULT STDMETHODCALLTYPE dqs_GetTrustLevel(IDispatcherQueueStatics_ *T, INT32 *lv) { (void)T; *lv=0; return S_OK; }
static HRESULT STDMETHODCALLTYPE dqs_ActivateInstance(IDispatcherQueueStatics_ *T, void **i) { (void)T; *i=NULL; return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE dqs_GetForCurrentThread(IDispatcherQueueStatics_ *T, IDispatcherQueue_ **result)
{
    (void)T;
    /* Return the static stub queue. Unity just checks this is non-NULL/S_OK. */
    *result = &g_stub_queue;
    g_stub_queue.lpVtbl->AddRef(&g_stub_queue);
    return S_OK;
}

static const IDispatcherQueueStaticsVtbl dqs_vtbl = {
    dqs_QueryInterface, dqs_AddRef, dqs_Release,
    dqs_GetIids, dqs_GetRuntimeClassName, dqs_GetTrustLevel,
    dqs_ActivateInstance, dqs_GetForCurrentThread,
};
static IDispatcherQueueStatics_ g_dq_statics = { &dqs_vtbl };

/* -----------------------------------------------------------------------
 * IDispatcherQueueController (from Wine dlls/coremessaging/main.c)
 * Mohamad Al-Jaf, 2024 — LGPL
 * ----------------------------------------------------------------------- */

struct IDispatcherQueueControllerVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDispatcherQueueController_ *, REFIID, void **);
    ULONG   (STDMETHODCALLTYPE *AddRef)        (IDispatcherQueueController_ *);
    ULONG   (STDMETHODCALLTYPE *Release)       (IDispatcherQueueController_ *);
    HRESULT (STDMETHODCALLTYPE *GetIids)       (IDispatcherQueueController_ *, ULONG *, IID **);
    HRESULT (STDMETHODCALLTYPE *GetRuntimeClassName)(IDispatcherQueueController_ *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *GetTrustLevel) (IDispatcherQueueController_ *, INT32 *);
    HRESULT (STDMETHODCALLTYPE *get_DispatcherQueue)(IDispatcherQueueController_ *, IDispatcherQueue_ **);
    HRESULT (STDMETHODCALLTYPE *ShutdownQueueAsync)(IDispatcherQueueController_ *, void **);
};

struct IDispatcherQueueController_ {
    const IDispatcherQueueControllerVtbl *lpVtbl;
    LONG ref;
};

static HRESULT STDMETHODCALLTYPE dqc_QueryInterface(IDispatcherQueueController_ *This, REFIID iid, void **out)
{
    if (guid_eq(iid, &IID_IUnknown_) || guid_eq(iid, &IID_IInspectable_) ||
        guid_eq(iid, &IID_IAgileObject_) || guid_eq(iid, &IID_IDispatcherQueueController_))
    {
        *out = This;
        InterlockedIncrement(&This->ref);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG STDMETHODCALLTYPE dqc_AddRef (IDispatcherQueueController_ *T) { return InterlockedIncrement(&T->ref); }
static ULONG STDMETHODCALLTYPE dqc_Release(IDispatcherQueueController_ *T) {
    ULONG r = InterlockedDecrement(&T->ref);
    if (!r) free(T);
    return r;
}
static HRESULT STDMETHODCALLTYPE dqc_GetIids(IDispatcherQueueController_ *T, ULONG *c, IID **i) { (void)T; *c=0; *i=NULL; return S_OK; }
static HRESULT STDMETHODCALLTYPE dqc_GetRuntimeClassName(IDispatcherQueueController_ *T, HSTRING *h) { (void)T; *h=NULL; return S_OK; }
static HRESULT STDMETHODCALLTYPE dqc_GetTrustLevel(IDispatcherQueueController_ *T, INT32 *lv) { (void)T; *lv=0; return S_OK; }
static HRESULT STDMETHODCALLTYPE dqc_get_DispatcherQueue(IDispatcherQueueController_ *T, IDispatcherQueue_ **r)
    { (void)T; *r=NULL; return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE dqc_ShutdownQueueAsync(IDispatcherQueueController_ *T, void **op)
    { (void)T; *op=NULL; return E_NOTIMPL; }

static const IDispatcherQueueControllerVtbl dqc_vtbl = {
    dqc_QueryInterface, dqc_AddRef, dqc_Release,
    dqc_GetIids, dqc_GetRuntimeClassName, dqc_GetTrustLevel,
    dqc_get_DispatcherQueue, dqc_ShutdownQueueAsync,
};

/* -----------------------------------------------------------------------
 * IDispatcherQueueControllerStatics activation factory
 * ----------------------------------------------------------------------- */

struct IDispatcherQueueControllerStaticsVtbl {
    HRESULT (STDMETHODCALLTYPE *QueryInterface)(IDispatcherQueueControllerStatics_ *, REFIID, void **);
    ULONG   (STDMETHODCALLTYPE *AddRef)        (IDispatcherQueueControllerStatics_ *);
    ULONG   (STDMETHODCALLTYPE *Release)       (IDispatcherQueueControllerStatics_ *);
    HRESULT (STDMETHODCALLTYPE *GetIids)       (IDispatcherQueueControllerStatics_ *, ULONG *, IID **);
    HRESULT (STDMETHODCALLTYPE *GetRuntimeClassName)(IDispatcherQueueControllerStatics_ *, HSTRING *);
    HRESULT (STDMETHODCALLTYPE *GetTrustLevel) (IDispatcherQueueControllerStatics_ *, INT32 *);
    HRESULT (STDMETHODCALLTYPE *ActivateInstance)(IDispatcherQueueControllerStatics_ *, void **);
    HRESULT (STDMETHODCALLTYPE *CreateOnDedicatedThread)(IDispatcherQueueControllerStatics_ *, IDispatcherQueueController_ **);
};

struct IDispatcherQueueControllerStatics_ { const IDispatcherQueueControllerStaticsVtbl *lpVtbl; };

static HRESULT STDMETHODCALLTYPE dqcs_QueryInterface(IDispatcherQueueControllerStatics_ *This, REFIID iid, void **out)
{
    if (guid_eq(iid, &IID_IUnknown_) || guid_eq(iid, &IID_IInspectable_) ||
        guid_eq(iid, &IID_IAgileObject_) || guid_eq(iid, &IID_IActivationFactory_) ||
        guid_eq(iid, &IID_IDispatcherQueueControllerStatics_))
    {
        *out = This;
        This->lpVtbl->AddRef(This);
        return S_OK;
    }
    *out = NULL;
    return E_NOINTERFACE;
}
static ULONG   STDMETHODCALLTYPE dqcs_AddRef (IDispatcherQueueControllerStatics_ *T) { (void)T; return 2; }
static ULONG   STDMETHODCALLTYPE dqcs_Release(IDispatcherQueueControllerStatics_ *T) { (void)T; return 1; }
static HRESULT STDMETHODCALLTYPE dqcs_GetIids(IDispatcherQueueControllerStatics_ *T, ULONG *c, IID **i) { (void)T; *c=0; *i=NULL; return S_OK; }
static HRESULT STDMETHODCALLTYPE dqcs_GetRuntimeClassName(IDispatcherQueueControllerStatics_ *T, HSTRING *h) { (void)T; *h=NULL; return S_OK; }
static HRESULT STDMETHODCALLTYPE dqcs_GetTrustLevel(IDispatcherQueueControllerStatics_ *T, INT32 *lv) { (void)T; *lv=0; return S_OK; }
static HRESULT STDMETHODCALLTYPE dqcs_ActivateInstance(IDispatcherQueueControllerStatics_ *T, void **i) { (void)T; *i=NULL; return E_NOTIMPL; }
static HRESULT STDMETHODCALLTYPE dqcs_CreateOnDedicatedThread(IDispatcherQueueControllerStatics_ *T, IDispatcherQueueController_ **result)
{
    IDispatcherQueueController_ *obj;
    (void)T;
    if (!(obj = calloc(1, sizeof(*obj)))) return E_OUTOFMEMORY;
    obj->lpVtbl = &dqc_vtbl;
    obj->ref = 1;
    *result = obj;
    return S_OK;
}

static const IDispatcherQueueControllerStaticsVtbl dqcs_vtbl = {
    dqcs_QueryInterface, dqcs_AddRef, dqcs_Release,
    dqcs_GetIids, dqcs_GetRuntimeClassName, dqcs_GetTrustLevel,
    dqcs_ActivateInstance, dqcs_CreateOnDedicatedThread,
};
static IDispatcherQueueControllerStatics_ g_dqc_statics = { &dqcs_vtbl };

/* -----------------------------------------------------------------------
 * DllGetActivationFactory — entry point called by combase/RoGetActivationFactory
 * ----------------------------------------------------------------------- */

__declspec(dllexport)
HRESULT WINAPI DllGetActivationFactory(HSTRING classid, void **factory)
{
    const WCHAR *name = get_string(classid);
    *factory = NULL;

    if (!wcscmp(name, L"Windows.System.DispatcherQueueController"))
    {
        *factory = &g_dqc_statics;
        return S_OK;
    }
    if (!wcscmp(name, L"Windows.System.DispatcherQueue"))
    {
        *factory = &g_dq_statics;
        return S_OK;
    }

    return 0x80040111; /* CLASS_E_CLASSNOTAVAILABLE */
}

/* -----------------------------------------------------------------------
 * CreateDispatcherQueueController — C-level export (games may call directly)
 * ----------------------------------------------------------------------- */

typedef struct {
    DWORD dwSize;
    INT   threadType;
    INT   apartmentType;
} DispatcherQueueOptions;

__declspec(dllexport)
HRESULT WINAPI CreateDispatcherQueueController(
    DispatcherQueueOptions options,
    IDispatcherQueueController_ **result)
{
    IDispatcherQueueController_ *obj;
    (void)options;
    if (!result) return E_POINTER;
    if (!(obj = calloc(1, sizeof(*obj)))) return E_OUTOFMEMORY;
    obj->lpVtbl = &dqc_vtbl;
    obj->ref = 1;
    *result = obj;
    return S_OK;
}

/* GetDispatcherQueueForCurrentThread — C-level export */
__declspec(dllexport)
HRESULT WINAPI GetDispatcherQueueForCurrentThread(IDispatcherQueue_ **result)
{
    if (!result) return E_POINTER;
    *result = &g_stub_queue;
    g_stub_queue.lpVtbl->AddRef(&g_stub_queue);
    return S_OK;
}

/* -----------------------------------------------------------------------
 * DllMain
 * ----------------------------------------------------------------------- */

BOOL WINAPI DllMain(HINSTANCE inst, DWORD reason, void *reserved)
{
    (void)inst; (void)reason; (void)reserved;
    return TRUE;
}
