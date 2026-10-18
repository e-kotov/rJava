/* Test helper: creates a JVM in the R process outside rJava, as a native
   application embedding both Java and R would. POSIX loads the library with
   global symbols, like the java launcher. Build with
     PKG_CPPFLAGS=-I<rJava>/src R CMD SHLIB jvmhost.c */
#ifdef _WIN32
#define _WIN32_WINNT 0x0602
#include <windows.h>
#include <stdlib.h>
#include <wchar.h>
#else
#include <dlfcn.h>
#endif
#include "jni.h"

void rjava_test_create_jvm(char **path, char **classpath, int *result) {
    JNI_CreateJavaVM_fnptr create = 0;
    JavaVMOption options[2];
    JavaVMInitArgs args;
    JavaVM *vm;
    void *env;
#ifdef _WIN32
    /* A real native host must choose its own startup dependencies. Use the
       selected JDK's bin only during this load, like java.exe's app directory;
       rJava must independently arrange any later MSVC loads after attaching. */
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path[0], -1, NULL, 0);
    wchar_t *wide = n ? malloc(sizeof(wchar_t) * n) : NULL;
    wchar_t *bin = n ? malloc(sizeof(wchar_t) * n) : NULL, *slash;
    DLL_DIRECTORY_COOKIE cookie = NULL;
    HMODULE lib = NULL;
    if (wide && bin && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path[0], -1, wide, n)) {
        for (slash = wide; *slash; slash++) if (*slash == L'/') *slash = L'\\';
        wcscpy(bin, wide);
        if ((slash = wcsrchr(bin, L'\\'))) {
            *slash = 0;
            if ((slash = wcsrchr(bin, L'\\'))) { *slash = 0; cookie = AddDllDirectory(bin); }
        }
        lib = LoadLibraryExW(wide, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
        if (cookie) RemoveDllDirectory(cookie);
    }
    free(wide); free(bin);
    if (lib) create = (JNI_CreateJavaVM_fnptr) GetProcAddress(lib, "JNI_CreateJavaVM");
#else
    void *lib = dlopen(path[0], RTLD_NOW | RTLD_GLOBAL);
    if (lib) *(void **) &create = dlsym(lib, "JNI_CreateJavaVM");
#endif
    if (!create) { *result = -100; return; }
    options[0].optionString = classpath[0];
    options[1].optionString = "-Djava.awt.headless=true";
    args.version = JNI_VERSION_1_2;
    args.nOptions = 2;
    args.options = options;
    args.ignoreUnrecognized = JNI_TRUE;
    *result = create(&vm, &env, &args);
}

#ifdef _WIN32
/* Observe retention after the component that first loaded a runtime lets go. */
void rjava_test_module_loaded(char **name, int *result) {
    *result = GetModuleHandleA(name[0]) != NULL;
}
#endif
