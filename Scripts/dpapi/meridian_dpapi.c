/*
 * meridian_dpapi.c — Wine CryptProtectData helper
 *
 * Produces meridian-dpapi.exe, a tiny Windows PE that uses Wine's built-in
 * crypt32.dll to encrypt / decrypt blobs in the exact format Wine reads and
 * writes. We use this to populate Steam's local.vdf ConnectCache blob from
 * outside the bottle — Meridian captures a JWT refresh_token via OAuth, this
 * helper wraps it with CryptProtectData, and Meridian writes the result to
 * AppData/Local/Steam/local.vdf. At sign-in time, the same engine's steam.exe
 * calls CryptUnprotectData on the same bytes, which succeeds because:
 *   - The DPAPI key is salted with GetUserNameA() → always "crossover" in our bottles
 *   - Wine's crypt32 protectdata_secret is a compile-time constant
 *   - The salt is embedded in the blob itself
 *   - Entropy (if any) is supplied by both sides
 *
 * Usage:
 *   meridian-dpapi.exe encrypt <plaintext_file> <output_file> [entropy]
 *   meridian-dpapi.exe decrypt <blob_file>       <output_file> [entropy]
 *
 *   entropy is an optional ASCII string passed as pOptionalEntropy. When
 *   omitted, NULL is used.
 *
 * Exit codes:
 *   0 — success
 *   1 — argument error
 *   2 — file I/O error
 *   3 — Crypt* API failure (GetLastError printed to stderr)
 */

#include <windows.h>
#include <wincrypt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static void die(int code, const char *msg) {
    fprintf(stderr, "meridian-dpapi: %s (GetLastError=0x%08lx)\n", msg,
            (unsigned long)GetLastError());
    ExitProcess(code);
}

static BYTE *read_file(const char *path, DWORD *out_len) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "meridian-dpapi: cannot open %s\n", path); return NULL; }
    fseek(f, 0, SEEK_END);
    long sz = ftell(f);
    fseek(f, 0, SEEK_SET);
    if (sz < 0) { fclose(f); return NULL; }
    BYTE *buf = (BYTE*)malloc((size_t)sz);
    if (!buf) { fclose(f); return NULL; }
    size_t got = fread(buf, 1, (size_t)sz, f);
    fclose(f);
    if (got != (size_t)sz) { free(buf); return NULL; }
    *out_len = (DWORD)sz;
    return buf;
}

static int write_file(const char *path, const BYTE *data, DWORD len) {
    FILE *f = fopen(path, "wb");
    if (!f) return 0;
    size_t got = fwrite(data, 1, len, f);
    fclose(f);
    return got == (size_t)len;
}

static void print_usage(void) {
    fprintf(stderr,
        "Usage:\n"
        "  meridian-dpapi.exe encrypt <plaintext_file> <output_file> [entropy]\n"
        "  meridian-dpapi.exe decrypt <blob_file>       <output_file> [entropy]\n"
        "\n"
        "entropy: optional ASCII string. If omitted, no optional entropy is used.\n");
}

int main(int argc, char **argv) {
    if (argc < 4 || argc > 5) { print_usage(); return 1; }

    const char *mode     = argv[1];
    const char *in_path  = argv[2];
    const char *out_path = argv[3];
    const char *entropy  = (argc == 5) ? argv[4] : NULL;

    int do_encrypt;
    if (strcmp(mode, "encrypt") == 0) do_encrypt = 1;
    else if (strcmp(mode, "decrypt") == 0) do_encrypt = 0;
    else { print_usage(); return 1; }

    DATA_BLOB in_blob = {0};
    in_blob.pbData = read_file(in_path, &in_blob.cbData);
    if (!in_blob.pbData) { fprintf(stderr, "meridian-dpapi: read %s failed\n", in_path); return 2; }

    DATA_BLOB entropy_blob = {0};
    DATA_BLOB *entropy_ptr = NULL;
    if (entropy) {
        entropy_blob.pbData = (BYTE*)entropy;
        entropy_blob.cbData = (DWORD)strlen(entropy);
        entropy_ptr = &entropy_blob;
    }

    DATA_BLOB out_blob = {0};
    BOOL ok;
    LPWSTR descr_out = NULL;

    if (do_encrypt) {
        ok = CryptProtectData(&in_blob,
                              L"",         /* szDataDescr — empty, Steam writes "" */
                              entropy_ptr,
                              NULL,        /* reserved */
                              NULL,        /* pPromptStruct */
                              0,           /* dwFlags */
                              &out_blob);
    } else {
        ok = CryptUnprotectData(&in_blob,
                                &descr_out,
                                entropy_ptr,
                                NULL,        /* reserved */
                                NULL,        /* pPromptStruct */
                                0,           /* dwFlags */
                                &out_blob);
    }

    if (!ok) { free(in_blob.pbData); die(3, do_encrypt ? "CryptProtectData failed" : "CryptUnprotectData failed"); }

    if (!write_file(out_path, out_blob.pbData, out_blob.cbData)) {
        fprintf(stderr, "meridian-dpapi: write %s failed\n", out_path);
        LocalFree(out_blob.pbData);
        if (descr_out) LocalFree(descr_out);
        free(in_blob.pbData);
        return 2;
    }

    fprintf(stderr, "meridian-dpapi: %s OK — %lu bytes in, %lu bytes out\n",
            do_encrypt ? "encrypt" : "decrypt",
            (unsigned long)in_blob.cbData, (unsigned long)out_blob.cbData);

    LocalFree(out_blob.pbData);
    if (descr_out) LocalFree(descr_out);
    free(in_blob.pbData);
    return 0;
}
