/* Windows only: the JVM bin directory may be added to the DLL search path
   only while djni_load() loads jvm.dll, and must be removed again after both
   failed and successful loads. Build and run with a stripped PATH:
     gcc -Isrc -o dll-search.exe tests-integration/dll-search.c
     dll-search.exe <missing bin\server\jvm.dll> <copied bin\server\jvm.dll> <bin of the first>
   Both bin directories contain rjava_marker.dll, which is nowhere else. */
#include "../src/djni.c"

static int failures;

static void check(int ok, const char *what) {
    printf("%s: %s\n", ok ? "ok" : "FAIL", what);
    if (!ok) failures++;
}
/* Searches only directories added with AddDllDirectory. */
static int marker_visible(void) {
    HMODULE h = LoadLibraryExW(L"rjava_marker.dll", NULL, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_SEARCH_USER_DIRS);
    if (h) FreeLibrary(h);
    return h != NULL;
}

int main(int argc, char **argv) {
    DLL_DIRECTORY_COOKIE cookie;
    wchar_t *bin;
    char *path;
    const char *mapped;
    int vms, res;
    if (argc != 4) { fprintf(stderr, "usage: dll-search <missing jvm.dll> <jvm.dll> <bin>\n"); return 2; }
    check(!marker_visible(), "marker is not visible initially");
    bin = to_wide(argv[3]);
    cookie = bin ? AddDllDirectory(bin) : NULL;
    check(cookie && marker_visible(), "control: an added directory is searched");
    if (cookie) RemoveDllDirectory(cookie);
    check(!marker_visible(), "control: a removed directory is not searched");

    res = djni_load(argv[1]);
    printf("missing library: %d %s\n", res, djni_last_error() ? djni_last_error() : "");
    check(res == -2 && !djni_loaded(), "a missing jvm.dll fails cleanly");
    check(!marker_visible(), "bin is not searched after a failed load");

    /* Relative input that only exceeds the path limit once completed. */
    path = malloc(32800);
    memset(path, 'b', 32700);
    strcpy(path + 32700, "\\server\\jvm.dll");
    res = djni_load(path);
    printf("over-long path: %d %.120s\n", res, djni_last_error() ? djni_last_error() : "");
    check(res == -2 && !djni_loaded(), "an over-long path fails cleanly");
    free(path);

    check(!djni_mapped(&vms), "no jvm.dll is mapped before loading");
    res = djni_load(argv[2]);
    printf("copied library: %d %s\n", res, djni_last_error() ? djni_last_error() : "");
    check(res == 0 && djni_loaded(), "a jvm.dll with dependencies in bin loads");
    check(!marker_visible(), "bin is not searched after a successful load");
    mapped = djni_mapped(&vms);
    printf("mapped: %s, %d VMs\n", mapped ? mapped : "(none)", vms);
    check(mapped && vms == 0, "the loaded jvm.dll is reported without a VM");
    free(bin);
    if (failures) { printf("FAIL dll-search: %d failures\n", failures); return 1; }
    printf("PASS dll-search\n");
    return 0;
}
