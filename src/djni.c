/* Dynamic JNI loader: no JVM dependency is resolved at namespace load. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifdef _WIN32
#define _WIN32_WINNT 0x0602
#include <windows.h>
#else
#include <dlfcn.h>
#include <sys/stat.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#elif defined(__linux__)
#include <link.h>
#endif
#endif
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "djni.h"

/* jni.h replaces the JDK headers, so configure no longer compares JNI types
   with native ones. Check the fixed sizes all supported JDKs use instead. */
typedef char djni_jbyte_size[sizeof(jbyte) == 1 ? 1 : -1];
typedef char djni_jboolean_size[sizeof(jboolean) == 1 ? 1 : -1];
typedef char djni_jchar_size[sizeof(jchar) == 2 ? 1 : -1];
typedef char djni_jshort_size[sizeof(jshort) == 2 ? 1 : -1];
typedef char djni_jint_size[sizeof(jint) == 4 ? 1 : -1];
typedef char djni_jlong_size[sizeof(jlong) == 8 ? 1 : -1];
typedef char djni_jfloat_size[sizeof(jfloat) == 4 ? 1 : -1];
typedef char djni_jdouble_size[sizeof(jdouble) == 8 ? 1 : -1];
typedef char djni_jvalue_size[sizeof(jvalue) == 8 ? 1 : -1];

static JNI_GetDefaultJavaVMInitArgs_fnptr JNI_GetDefaultJavaVMInitArgs_fn;
static JNI_CreateJavaVM_fnptr JNI_CreateJavaVM_fn;
static JNI_GetCreatedJavaVMs_fnptr JNI_GetCreatedJavaVMs_fn;
#ifdef _WIN32
static HMODULE jni_dl;
#else
static void *jni_dl;
#endif
static char last_error[1024];
static char *mapped_name;

static void clear_symbols(void) {
    JNI_GetDefaultJavaVMInitArgs_fn = 0;
    JNI_CreateJavaVM_fn = 0;
    JNI_GetCreatedJavaVMs_fn = 0;
}

#ifdef _WIN32
static wchar_t *to_wide(const char *s) {
    int n = MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, NULL, 0);
    wchar_t *w = (n > 0) ? malloc(sizeof(wchar_t) * n) : NULL;
    if (n > 0 && !w) SetLastError(ERROR_NOT_ENOUGH_MEMORY);
    if (w && MultiByteToWideChar(CP_UTF8, MB_ERR_INVALID_CHARS, s, -1, w, n) != n) {
        free(w);
        w = NULL;
    }
    return w;
}
static char *to_utf8(const wchar_t *w) {
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, NULL, 0, NULL, NULL);
    char *s = (n > 0) ? malloc(n) : NULL;
    if (s && WideCharToMultiByte(CP_UTF8, 0, w, -1, s, n, NULL, NULL) != n) {
        free(s);
        s = NULL;
    }
    return s;
}
static void save_win_error(const char *what, const char *path, DWORD code) {
    wchar_t *msg = NULL;
    char *text = NULL;
    size_t n;
    if (FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                       FORMAT_MESSAGE_IGNORE_INSERTS, NULL, code, 0, (LPWSTR) &msg, 0, NULL) && msg)
        text = to_utf8(msg);
    if (msg) LocalFree(msg);
    n = text ? strlen(text) : 0;
    while (n && (text[n - 1] == '\n' || text[n - 1] == '\r' || text[n - 1] == ' ')) text[--n] = 0;
    snprintf(last_error, sizeof(last_error), "%s %s: %s (Windows error %lu)", what, path,
             n ? text : "unknown error", (unsigned long) code);
    free(text);
}
/* A return value of at least the buffer size is the size required, not the
   length of a complete path, so retry instead of using a truncated path. */
static wchar_t *full_path(const wchar_t *path) {
    DWORD size = GetFullPathNameW(path, 0, NULL, NULL), n;
    int tries;
    for (tries = 0; size && tries < 3; tries++) {
        wchar_t *buf = malloc(sizeof(wchar_t) * size);
        if (!buf) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
        n = GetFullPathNameW(path, size, buf, NULL);
        if (n && n < size) return buf;
        free(buf);
        size = n;
    }
    if (size) SetLastError(ERROR_INSUFFICIENT_BUFFER);
    return NULL;
}
/* GetModuleFileNameW returns the buffer size when it truncates. */
static wchar_t *module_path(HMODULE module) {
    DWORD size = MAX_PATH, n;
    for (;;) {
        wchar_t *buf = malloc(sizeof(wchar_t) * size);
        if (!buf) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
        n = GetModuleFileNameW(module, buf, size);
        if (n && n < size) return buf;
        free(buf);
        if (!n) return NULL;
        if (size >= 65536) { SetLastError(ERROR_INSUFFICIENT_BUFFER); return NULL; }
        size *= 2;
    }
}
static HANDLE open_file(const wchar_t *path) {
    return CreateFileW(path, FILE_READ_ATTRIBUTES, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
                       NULL, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, NULL);
}
/* Compare file identities rather than names: 8.3 aliases, junctions,
   symbolic links and spelling variants can all name the same file.
   Returns 1 for the same file, 0 for different files, -1 if unknown. */
static int same_file(const wchar_t *a, const wchar_t *b) {
    HANDLE ha = open_file(a), hb = open_file(b);
    FILE_ID_INFO ia, ib;
    BY_HANDLE_FILE_INFORMATION fa, fb;
    int res = -1;
    if (ha != INVALID_HANDLE_VALUE && hb != INVALID_HANDLE_VALUE) {
        if (GetFileInformationByHandleEx(ha, FileIdInfo, &ia, sizeof(ia)) &&
            GetFileInformationByHandleEx(hb, FileIdInfo, &ib, sizeof(ib)))
            res = ia.VolumeSerialNumber == ib.VolumeSerialNumber &&
                !memcmp(&ia.FileId, &ib.FileId, sizeof(ia.FileId));
        else if (GetFileInformationByHandle(ha, &fa) && GetFileInformationByHandle(hb, &fb))
            res = fa.dwVolumeSerialNumber == fb.dwVolumeSerialNumber &&
                fa.nFileIndexHigh == fb.nFileIndexHigh && fa.nFileIndexLow == fb.nFileIndexLow;
    } else if (hb != INVALID_HANDLE_VALUE)
        res = 0; /* the requested file does not exist, but a JVM is mapped */
    if (ha != INVALID_HANDLE_VALUE) CloseHandle(ha);
    if (hb != INVALID_HANDLE_VALUE) CloseHandle(hb);
    return res;
}
static int load_library(const char *path) {
    wchar_t *wide = NULL, *full = NULL, *mapped_path = NULL, *bin = NULL, *slash;
    HMODULE mapped;
    DLL_DIRECTORY_COOKIE cookie = NULL;
    int res = -2;
    if (!(wide = to_wide(path))) {
        save_win_error("Cannot convert JVM library path to UTF-16", path, GetLastError());
        goto done;
    }
    if (!(full = full_path(wide))) {
        save_win_error("Cannot resolve JVM library path", path, GetLastError());
        goto done;
    }
    for (slash = full; *slash; slash++) if (*slash == L'/') *slash = L'\\';
    if ((mapped = GetModuleHandleW(L"jvm.dll"))) {
        int same = (mapped_path = module_path(mapped)) ? same_file(full, mapped_path) : -1;
        char *name = mapped_path ? to_utf8(mapped_path) : NULL;
        if (same == 1) {
            /* Reference the mapped module itself: loading an alias of its path
               must never map a second copy of jvm.dll. */
            if (GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, (LPCWSTR) mapped, &jni_dl))
                res = 0;
            else {
                jni_dl = NULL;
                save_win_error("Cannot reference the mapped JVM library", name ? name : path, GetLastError());
            }
        } else {
            if (same)
                snprintf(last_error, sizeof(last_error), "Cannot verify that %s is the JVM library already mapped: %s. Use a new R process.",
                         path, name ? name : "unknown path");
            else
                snprintf(last_error, sizeof(last_error), "Another JVM library is already mapped: %s. Use a new R process.",
                         name ? name : "unknown path");
            res = -4;
        }
        free(name);
        goto done;
    }
    /* JDK 8 keeps MSVC runtime DLLs in bin, the parent of bin\server. The
       directory is searched only during this load and removed again after
       success or failure, leaving the process DLL search state unchanged. */
    if ((bin = malloc(sizeof(wchar_t) * (wcslen(full) + 1)))) {
        wcscpy(bin, full);
        if ((slash = wcsrchr(bin, L'\\'))) {
            *slash = 0;
            if ((slash = wcsrchr(bin, L'\\'))) {
                *slash = 0;
                cookie = AddDllDirectory(bin);
            }
        }
    }
    jni_dl = LoadLibraryExW(full, NULL, LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_DEFAULT_DIRS);
    if (jni_dl) res = 0;
    else save_win_error("Cannot load JVM library", path, GetLastError());
    if (cookie) RemoveDllDirectory(cookie);
done:
    free(wide); free(full); free(mapped_path); free(bin);
    return res;
}
const char *djni_mapped(int *vms) {
    HMODULE module = NULL;
    wchar_t *path;
    JNI_GetCreatedJavaVMs_fnptr created;
    *vms = -1;
    free(mapped_name);
    mapped_name = NULL;
    if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT, L"jvm.dll", &module))
        return NULL;
    if ((created = (JNI_GetCreatedJavaVMs_fnptr) GetProcAddress(module, "JNI_GetCreatedJavaVMs"))) {
        JavaVM *vm;
        jsize n = 0;
        if (created(&vm, 1, &n) == JNI_OK) *vms = (int) n;
    }
    if ((path = module_path(module))) {
        mapped_name = to_utf8(path);
        free(path);
    }
    return mapped_name;
}
#else
static int same_file(const char *a, const char *b) {
    struct stat sa, sb;
    if (stat(a, &sa) || stat(b, &sb)) return -1;
    return sa.st_dev == sb.st_dev && sa.st_ino == sb.st_ino;
}
static int is_jvm_image(const char *name) {
    const char *base = strrchr(name, '/');
    base = base ? base + 1 : name;
    return !strcmp(base, "libjvm.dylib") || !strcmp(base, "libjvm.so");
}
typedef int (*image_fn)(const char *name, void *data);
#ifdef __linux__
struct phdr_data { image_fn fn; void *data; };
static int phdr_image(struct dl_phdr_info *info, size_t size, void *data) {
    struct phdr_data *d = (struct phdr_data *) data;
    return info->dlpi_name ? d->fn(info->dlpi_name, d->data) : 0;
}
#endif
/* Calls fn for each image mapped into the process until it returns nonzero. */
static int each_image(image_fn fn, void *data) {
#ifdef __APPLE__
    uint32_t i, n = _dyld_image_count();
    for (i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && fn(name, data)) return 1;
    }
    return 0;
#elif defined(__linux__)
    struct phdr_data d = { fn, data };
    return dl_iterate_phdr(phdr_image, &d);
#else
    return 0;
#endif
}
struct jvm_match { const char *requested; char *mapped; };
/* Device and inode identify the file across symbolic links, hard links and
   equivalent spellings; a requested file that cannot be found differs. */
static int check_mapped(const char *name, void *data) {
    struct jvm_match *m = (struct jvm_match *) data;
    if (!is_jvm_image(name)) return 0;
    if (same_file(name, m->requested) == 1) {
        if (!m->mapped) m->mapped = strdup(name);
        return 0;
    }
    snprintf(last_error, sizeof(last_error), "Another JVM library is already mapped: %s. Use a new R process.", name);
    return 1;
}
static int find_jvm(const char *name, void *data) {
    if (!is_jvm_image(name)) return 0;
    *(char **) data = strdup(name);
    return 1;
}
static int load_library(const char *path) {
    struct jvm_match m = { path, NULL };
    if (each_image(check_mapped, &m)) {
        free(m.mapped);
        return -4;
    }
    /* Open a mapped JVM by its own name, so an alias cannot map another copy. */
    jni_dl = dlopen(m.mapped ? m.mapped : path, RTLD_LOCAL | RTLD_NOW);
    free(m.mapped);
    if (!jni_dl) {
        const char *error = dlerror();
        snprintf(last_error, sizeof(last_error), "%s", error ? error : "dynamic loader error");
        return -2;
    }
    return 0;
}
const char *djni_mapped(int *vms) {
    char *found = NULL;
    *vms = -1;
    free(mapped_name);
    mapped_name = NULL;
    each_image(find_jvm, &found);
    if (!found) return NULL;
#ifdef RTLD_NOLOAD
    {
        /* RTLD_NOLOAD returns a reference only if the image is already mapped. */
        void *handle = dlopen(found, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
        if (handle) {
            JNI_GetCreatedJavaVMs_fnptr created;
            *(void **) &created = dlsym(handle, "JNI_GetCreatedJavaVMs");
            if (created) {
                JavaVM *vm;
                jsize n = 0;
                if (created(&vm, 1, &n) == JNI_OK) *vms = (int) n;
            }
            dlclose(handle);
        }
    }
#endif
    mapped_name = found;
    return found;
}
#endif

static int load_sym(const char *sym, void **ptr) {
#ifdef _WIN32
    *ptr = (void *) GetProcAddress(jni_dl, sym);
    if (!*ptr) { save_win_error("Cannot find JNI entry point", sym, GetLastError()); return -1; }
#else
    const char *error;
    *ptr = dlsym(jni_dl, sym);
    if (!*ptr) {
        error = dlerror();
        snprintf(last_error, sizeof(last_error), "%s", error ? error : "dynamic loader error");
        return -1;
    }
#endif
    return 0;
}

/* returns: 0 = success, -1 = already loaded, -2 = load error, -3 = symbols
   not found, -4 = another JVM library is already mapped */
int djni_load(const char *path) {
    int res;
    last_error[0] = 0;
    if (jni_dl) return -1;
    if ((res = load_library(path))) return res;
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
    if (!FreeLibrary(jni_dl)) { save_win_error("Cannot unload JVM library", "jvm.dll", GetLastError()); return -2; }
#else
    if (dlclose(jni_dl)) {
        const char *error = dlerror();
        snprintf(last_error, sizeof(last_error), "%s", error ? error : "dynamic loader error");
        return -2;
    }
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
