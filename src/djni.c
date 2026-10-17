/* Dynamic JNI loader: no JVM dependency is resolved at namespace load. */
#ifdef _WIN32
#define _WIN32_WINNT 0x0602
#include <windows.h>
#else
#include <dlfcn.h>
#endif
#include <stdio.h>
#include "djni.h"

static JNI_GetDefaultJavaVMInitArgs_fnptr JNI_GetDefaultJavaVMInitArgs_fn;
static JNI_CreateJavaVM_fnptr JNI_CreateJavaVM_fn;
static JNI_GetCreatedJavaVMs_fnptr JNI_GetCreatedJavaVMs_fn;
#ifdef _WIN32
static HMODULE jni_dl;
#else
static void *jni_dl;
#endif
static char last_error[1024];

static void clear_symbols(void) {
    JNI_GetDefaultJavaVMInitArgs_fn = 0;
    JNI_CreateJavaVM_fn = 0;
    JNI_GetCreatedJavaVMs_fn = 0;
}
static void save_error(void) {
#ifdef _WIN32
    DWORD code = GetLastError();
    snprintf(last_error, sizeof(last_error), "Windows loader error %lu", (unsigned long) code);
#else
    const char *error = dlerror();
    snprintf(last_error, sizeof(last_error), "%s", error ? error : "dynamic loader error");
#endif
}
static int load_sym(const char *sym, void **ptr) {
#ifdef _WIN32
    *ptr = (void *) GetProcAddress(jni_dl, sym);
#else
    *ptr = dlsym(jni_dl, sym);
#endif
    if (!*ptr) { save_error(); return -1; }
    return 0;
}
int djni_load(const char *path) {
    last_error[0] = 0;
    if (jni_dl) return -1;
#ifdef _WIN32
    wchar_t wide_path[32768], bin_path[32768], *slash;
    DLL_DIRECTORY_COOKIE cookie = 0;
    if (!MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, path, -1, wide_path, 32768)) {
        save_error(); return -2;
    }
    /* JDK 8 needs its bin directory as well as bin/server for dependent DLLs. */
    wcscpy(bin_path, wide_path);
    for (slash = bin_path; *slash; slash++) if (*slash == L'/') *slash = L'\\';
    slash = wcsrchr(bin_path, L'\\');
    if (slash) {
        *slash = 0;
        slash = wcsrchr(bin_path, L'\\');
        if (slash) { *slash = 0; cookie = AddDllDirectory(bin_path); }
    }
    jni_dl = LoadLibraryExW(wide_path, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (!jni_dl) save_error();
    if (cookie) RemoveDllDirectory(cookie);
#else
    jni_dl = dlopen(path, RTLD_LOCAL | RTLD_NOW);
    if (!jni_dl) save_error();
#endif
    if (!jni_dl) return -2;
    if (load_sym("JNI_GetDefaultJavaVMInitArgs", (void **) &JNI_GetDefaultJavaVMInitArgs_fn) ||
        load_sym("JNI_CreateJavaVM", (void **) &JNI_CreateJavaVM_fn) ||
        load_sym("JNI_GetCreatedJavaVMs", (void **) &JNI_GetCreatedJavaVMs_fn)) {
        djni_unload();
        return -3;
    }
    return 0;
}
int djni_unload(void) {
    if (!jni_dl) return -1;
#ifdef _WIN32
    if (!FreeLibrary(jni_dl)) { save_error(); return -2; }
#else
    if (dlclose(jni_dl)) { save_error(); return -2; }
#endif
    jni_dl = 0;
    clear_symbols();
    return 0;
}
int djni_loaded(void) { return jni_dl ? 1 : 0; }
const char *djni_last_error(void) { return last_error[0] ? last_error : 0; }
jint JNI_GetDefaultJavaVMInitArgs(void *args) {
    return JNI_GetDefaultJavaVMInitArgs_fn ? JNI_GetDefaultJavaVMInitArgs_fn(args) : JNI_NO_DJNI;
}
jint JNI_CreateJavaVM(JavaVM **pvm, void **penv, void *args) {
    return JNI_CreateJavaVM_fn ? JNI_CreateJavaVM_fn(pvm, penv, args) : JNI_NO_DJNI;
}
jint JNI_GetCreatedJavaVMs(JavaVM **vmBuf, jsize bufLen, jsize *nVMs) {
    return JNI_GetCreatedJavaVMs_fn ? JNI_GetCreatedJavaVMs_fn(vmBuf, bufLen, nVMs) : JNI_NO_DJNI;
}

/* define DJNI_MAIN_TEST to test the load + create + print version + destroy + unload cycle
   it will create an executable - just compile djni.c alone for this (not used in rJava) */
#ifdef DJNI_MAIN_TEST

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* calls java.lang.System.getProperty("java.version") and returns the result or NULL
   if something went wrong. Any non-NULL returns must be free()d */
static char *java_version(JNIEnv *eenv) {
    char *jver = 0;
    jclass sys = (*eenv)->FindClass(eenv, "java/lang/System");
    if (sys) {
	jmethodID mid = (*eenv)->GetStaticMethodID(eenv, sys, "getProperty", "(Ljava/lang/String;)Ljava/lang/String;");
	if (mid) {
	    jstring jvs = (*eenv)->NewStringUTF(eenv, "java.version");
	    if (jvs) {
		jobject jres = (*eenv)->CallStaticObjectMethod(eenv, sys, mid, jvs);
		(*eenv)->DeleteLocalRef(eenv, jvs);
		if (jres) {
		    const char *str = (*eenv)->GetStringUTFChars(eenv, (jstring) jres, NULL);
		    if (str) {
			jver = strdup(str);
			(*eenv)->ReleaseStringUTFChars(eenv, (jstring) jres, str);
		    }
		    (*eenv)->DeleteLocalRef(eenv, jres);
		}
	    }
	}
	(*eenv)->DeleteLocalRef(eenv, sys);
    }
    return jver;
}

/* create a JVM, call java_version(), destroy the JVM */
static int run_jvm_test(void) {
    JavaVM *jvm;
    JNIEnv *eenv;
    JavaVMOption   vm_options[4];
    JavaVMInitArgs vm_args;
    vm_args.version = JNI_VERSION_1_2;
    if(JNI_GetDefaultJavaVMInitArgs(&vm_args) != JNI_OK) {
	fprintf(stderr, "JNI 1.2 or higher is required\n");
	return -1;
    }
    vm_args.ignoreUnrecognized = JNI_TRUE;
    vm_args.options = vm_options;
    vm_args.nOptions = 0;
    jint res = JNI_CreateJavaVM(&jvm,(void **)&eenv, &vm_args);
    if (res != 0) {
	fprintf(stderr, "Cannot create Java virtual machine (JNI_CreateJavaVM returned %d)\n", (int) res);
	return -1;
    }
    if (!eenv) {
	fprintf(stderr, "Cannot obtain JVM environment");
	return -1;
    }
    printf("JVM initialized, JNI version: %x\n", (*eenv)->GetVersion(eenv));
    {
	char *jver = java_version(eenv);
	if (jver) {
	    printf("Java version: %s\n", jver);
	    free(jver);
	}
    }
    /* this shouldn't be even needed, but was last-ditch effort - makes no difference */
    if ((*jvm)->DetachCurrentThread(jvm) != JNI_OK)
	fprintf(stderr, "FWIW: cannot detach thread.\n");
    /* destroy the VM */
    if ((*jvm)->DestroyJavaVM(jvm) != JNI_OK) {
	fprintf(stderr, "ERROR: cannot destroy VM\n");
	return -1;
    } 
    printf("JVM destroyed.\n");
    return 0;
}

int test_jvm(const char *path) {
    int e = djni_load(path);
    if (e) {
	printf("Cannot load: %d (%s)\n", e, djni_last_error() ? djni_last_error() : "not a dl error");
	return 1;
    }
    printf("JVM Loaded!\n");
    if (!run_jvm_test()) {
	if (djni_unload())
	    fprintf(stderr, "ERROR: cannot unload JNI (%s)\n", djni_last_error() ? djni_last_error() : "no information");
	else
	    printf("JNI unloaded.\n");
    }
    return 0;
}

/* for debugging on macOS - prints all dynamic loads */
#ifdef __APPLE__
#include <mach-o/dyld.h>

static void add_image(const struct mach_header* mh, intptr_t vmaddr_slide) {
    Dl_info DlInfo;
    dladdr(mh, &DlInfo);
    printf("LOADED: %s\n", DlInfo.dli_fname);
}

static void rm_image(const struct mach_header* mh, intptr_t vmaddr_slide) {
    Dl_info DlInfo;
    dladdr(mh, &DlInfo);
    printf("REMOVE: %s\n", DlInfo.dli_fname);
}
#endif

int main(int ac, char **av) {
#ifdef __APPLE__
    _dyld_register_func_for_add_image(add_image);
    _dyld_register_func_for_remove_image(rm_image);
#endif

    test_jvm("/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home/lib/server/libjvm.dylib");
#ifdef SAME_VM /* option 1: try the same VM twice (will load but fail to create VM) */
    test_jvm("/Library/Java/JavaVirtualMachines/temurin-17.jdk/Contents/Home/lib/server/libjvm.dylib");
#else          /* option 2: will even fail to load */
    test_jvm("/Library/Java/JavaVirtualMachines/temurin-11.jdk/Contents/Home/lib/server/libjvm.dylib");
#endif
    return 0;
}

#endif
