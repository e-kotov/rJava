/* Prints loaded MSVC runtime / JVM modules with their file versions. */
#include <windows.h>
#include <psapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
static void version(const wchar_t *path, char *out, size_t n) {
    DWORD ig, size = GetFileVersionInfoSizeW(path, &ig);
    void *data = size ? malloc(size) : NULL;
    VS_FIXEDFILEINFO *fi; UINT len;
    snprintf(out, n, "?");
    if (data && GetFileVersionInfoW(path, 0, size, data) && VerQueryValueW(data, L"\\", (void **) &fi, &len) && len)
        snprintf(out, n, "%u.%u.%u.%u", HIWORD(fi->dwFileVersionMS), LOWORD(fi->dwFileVersionMS),
                 HIWORD(fi->dwFileVersionLS), LOWORD(fi->dwFileVersionLS));
    free(data);
}
void rv_modules(void) {
    HMODULE mods[4096]; DWORD bytes, i;
    if (!K32EnumProcessModules(GetCurrentProcess(), mods, sizeof(mods), &bytes)) return;
    for (i = 0; i < bytes / sizeof(HMODULE); i++) {
        wchar_t p[32768], l[32768]; char v[64]; size_t j;
        DWORD n = GetModuleFileNameW(mods[i], p, 32768);
        if (!n || n >= 32768) continue;
        for (j = 0; j <= n; j++) l[j] = towlower(p[j]);
        if (wcsstr(l, L"msvcp140") || wcsstr(l, L"vcruntime140") || wcsstr(l, L"\\jvm.dll")) {
            version(p, v, sizeof v);
            printf("MODULE|%ls|%s\n", p, v);
        }
    }
    fflush(stdout);
}
/* Version of a file, for reporting bundled copies. */
void rv_file_version(char **path, char **out) {
    static char v[64]; wchar_t w[32768];
    MultiByteToWideChar(CP_UTF8, 0, path[0], -1, w, 32768);
    version(w, v, sizeof v); out[0] = v;
}
