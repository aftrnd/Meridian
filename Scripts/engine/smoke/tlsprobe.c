/*
 * tlsprobe — HTTPS GET through WinHTTP (Schannel → Wine secur32 → GnuTLS).
 *
 * Prints the HTTP status of https://<host>/ and exits 0 on 2xx/3xx. Exercises
 * the engine's GnuTLS + nettle + gmp chain that Steam's networking relies on.
 *
 * Build: x86_64-w64-mingw32-gcc -O2 -o tlsprobe64.exe tlsprobe.c -lwinhttp
 */
#include <windows.h>
#include <winhttp.h>
#include <stdio.h>

int wmain(int argc, wchar_t **argv)
{
    const wchar_t *host = argc > 1 ? argv[1] : L"store.steampowered.com";
    HINTERNET session = WinHttpOpen(L"meridian-tlsprobe/1.0", WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    HINTERNET connect = session ? WinHttpConnect(session, host, INTERNET_DEFAULT_HTTPS_PORT, 0) : NULL;
    HINTERNET request = connect ? WinHttpOpenRequest(connect, L"GET", L"/", NULL, WINHTTP_NO_REFERER,
                                                     WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE) : NULL;
    if (!request ||
        !WinHttpSendRequest(request, WINHTTP_NO_ADDITIONAL_HEADERS, 0, WINHTTP_NO_REQUEST_DATA, 0, 0, 0) ||
        !WinHttpReceiveResponse(request, NULL)) {
        printf("https://%ls/ failed: error %lu\n", host, GetLastError());
        return 1;
    }
    DWORD status = 0, size = sizeof(status);
    WinHttpQueryHeaders(request, WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                        WINHTTP_HEADER_NAME_BY_INDEX, &status, &size, WINHTTP_NO_HEADER_INDEX);
    printf("https://%ls/ -> HTTP %lu\n", host, status);
    return status >= 200 && status < 400 ? 0 : 1;
}
