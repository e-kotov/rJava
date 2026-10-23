/* Record loaded JVM/MSVC origins without launching another process. */
#define _WIN32_WINNT 0x0602
#define PSAPI_VERSION 2
#include <windows.h>
#include <psapi.h>
#include <stdio.h>
#include <string.h>

void rjava_compare_modules(void) {
    HMODULE modules[2048];
    DWORD bytes, i;
    if (!K32EnumProcessModules(GetCurrentProcess(), modules, sizeof(modules), &bytes) ||
        bytes > sizeof(modules)) return;
    for (i = 0; i < bytes / sizeof(*modules); i++) {
        char path[32768], lower[32768];
        size_t j;
        DWORD n = GetModuleFileNameA(modules[i], path, sizeof(path));
        if (!n || n >= sizeof(path)) continue;
        for (j = 0; j <= n; j++) lower[j] = (path[j] >= 'A' && path[j] <= 'Z') ? path[j] + 'a' - 'A' : path[j];
        if (strstr(lower, "msvcp") || strstr(lower, "vcruntime") || strstr(lower, "msvcr") ||
            strstr(lower, "jvm.dll") || strstr(lower, "java.dll") || strstr(lower, "jri.dll"))
            printf("MODULE|%s\n", path);
    }
    fflush(stdout);
}
