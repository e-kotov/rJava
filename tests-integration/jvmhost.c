/* Test helper: creates a JVM in the R process outside rJava, as a native
   application embedding both Java and R would. POSIX loads the library with
   global symbols, like the java launcher. Build with
     PKG_CPPFLAGS=-I<rJava>/src R CMD SHLIB jvmhost.c */
#ifdef _WIN32
#include <windows.h>
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
    HMODULE lib = LoadLibraryExA(path[0], NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
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
