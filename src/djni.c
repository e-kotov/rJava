/* Dynamic JNI loader: no JVM dependency is resolved at namespace load. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#ifdef _WIN32
#define _WIN32_WINNT 0x0602
/* EnumProcessModules is K32EnumProcessModules in kernel32, without psapi.dll */
#define PSAPI_VERSION 2
#include <windows.h>
#include <psapi.h>
#else
#include <dlfcn.h>
#include <unistd.h>
#include <sys/stat.h>
#ifdef __APPLE__
#include <mach-o/dyld.h>
#include <libproc.h>
#elif defined(__linux__)
#include <link.h>
#include <sys/sysmacros.h>
#include <sys/vfs.h>
#endif
#endif
#include <stdint.h>
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
/* The file mapped for a module, as a path that opens it: the module's
   recorded name may now be another file, if the mapped one was renamed and
   replaced. GetMappedFileNameW gives an NT device path. */
static wchar_t *mapped_path(HMODULE module) {
    static const wchar_t root[] = L"\\\\?\\GLOBALROOT";
    DWORD size = 32768, skip = (DWORD) wcslen(root), n;
    wchar_t *buf = malloc(sizeof(wchar_t) * (skip + size));
    if (!buf) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); return NULL; }
    wcscpy(buf, root);
    n = K32GetMappedFileNameW(GetCurrentProcess(), (LPVOID) module, buf + skip, size);
    if (n && n < size - 1) return buf;
    if (n) SetLastError(ERROR_INSUFFICIENT_BUFFER);
    free(buf);
    return NULL;
}
static int in_image(DWORD rva, DWORD count, DWORD width, DWORD size) {
    return rva < size && count <= (size - rva) / width;
}
/* Whether a mapped module defines, rather than forwards, an export. The
   export table is read in memory, so nothing is loaded; GetProcAddress
   would load the target of a forwarded export. */
static int owns_export(HMODULE module, const char *sym) {
    const BYTE *base = (const BYTE *) module;
    const IMAGE_DOS_HEADER *dos = (const IMAGE_DOS_HEADER *) base;
    const IMAGE_NT_HEADERS *nt;
    const IMAGE_DATA_DIRECTORY *dir;
    const IMAGE_EXPORT_DIRECTORY *exp;
    const DWORD *names, *functions;
    const WORD *ordinals;
    DWORD size, i, len = (DWORD) strlen(sym) + 1;
    if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew < (LONG) sizeof(*dos) ||
        dos->e_lfanew > 4096 - (LONG) sizeof(*nt))
        return 0;
    nt = (const IMAGE_NT_HEADERS *) (base + dos->e_lfanew);
    if (nt->Signature != IMAGE_NT_SIGNATURE || nt->OptionalHeader.Magic != IMAGE_NT_OPTIONAL_HDR_MAGIC ||
        nt->OptionalHeader.NumberOfRvaAndSizes <= IMAGE_DIRECTORY_ENTRY_EXPORT)
        return 0;
    size = nt->OptionalHeader.SizeOfImage;
    dir = &nt->OptionalHeader.DataDirectory[IMAGE_DIRECTORY_ENTRY_EXPORT];
    if (!dir->VirtualAddress || dir->VirtualAddress >= size || dir->Size < sizeof(*exp) ||
        dir->Size > size - dir->VirtualAddress)
        return 0;
    exp = (const IMAGE_EXPORT_DIRECTORY *) (base + dir->VirtualAddress);
    if (!in_image(exp->AddressOfNames, exp->NumberOfNames, 4, size) ||
        !in_image(exp->AddressOfNameOrdinals, exp->NumberOfNames, 2, size) ||
        !in_image(exp->AddressOfFunctions, exp->NumberOfFunctions, 4, size))
        return 0;
    names = (const DWORD *) (base + exp->AddressOfNames);
    ordinals = (const WORD *) (base + exp->AddressOfNameOrdinals);
    functions = (const DWORD *) (base + exp->AddressOfFunctions);
    /* Names are usually sorted, but a linear scan does not depend on it. */
    for (i = 0; i < exp->NumberOfNames; i++) {
        DWORD f;
        if (names[i] >= size || len > size - names[i] || memcmp(base + names[i], sym, len)) continue;
        if (ordinals[i] >= exp->NumberOfFunctions) return 0;
        f = functions[ordinals[i]];
        /* An address inside the export directory names a forwarded export. */
        return f && f < size && (f < dir->VirtualAddress || f - dir->VirtualAddress >= dir->Size);
    }
    return 0;
}
static int is_jvm_name(const wchar_t *path) {
    const wchar_t *base = wcsrchr(path, L'\\');
    return !_wcsicmp(base ? base + 1 : path, L"jvm.dll");
}
/* A module is a JVM if it is named jvm.dll, even if malformed, or if it
   defines the JNI invocation exports and a JVM_ export, whatever its name.
   JNI exports alone do not suffice: rJava's wrappers have them too. */
static int is_jvm_module(HMODULE module, const wchar_t *path) {
    return (path && is_jvm_name(path)) ||
        (owns_export(module, "JVM_CurrentTimeMillis") && owns_export(module, "JNI_CreateJavaVM") &&
         owns_export(module, "JNI_GetCreatedJavaVMs"));
}
struct jvm_image { HMODULE handle; wchar_t *path; };
/* Lists the JVM modules mapped into the process, each with a reference
   (and path if known). Returns their number, -1 if modules cannot be listed. */
static int find_jvms(struct jvm_image **out) {
    HMODULE *mods = NULL;
    struct jvm_image *v = NULL;
    DWORD need = 0, size = 0, count, i;
    int n = 0, tries;
    *out = NULL;
    for (tries = 0; tries < 4 && need >= size; tries++) {
        HMODULE *m = realloc(mods, (size = need + 64 * sizeof(HMODULE)));
        if (!m) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); goto fail; }
        mods = m;
        if (!K32EnumProcessModules(GetCurrentProcess(), mods, size, &need)) goto fail;
    }
    if (need >= size) { SetLastError(ERROR_INSUFFICIENT_BUFFER); goto fail; }
    count = need / sizeof(HMODULE);
    if (count && !(v = calloc(count, sizeof(*v)))) { SetLastError(ERROR_NOT_ENOUGH_MEMORY); goto fail; }
    for (i = 0; i < count; i++) {
        HMODULE module = NULL;
        wchar_t *path;
        /* Hold a reference while reading the module: a module unloaded since
           the enumeration is skipped, and cannot be replaced while read. */
        if (!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS, (LPCWSTR) mods[i], &module)) continue;
        if (module != mods[i]) { FreeLibrary(module); continue; }
        path = module_path(module);
        if (is_jvm_module(module, path)) {
            v[n].handle = module;
            v[n++].path = path;
        } else {
            free(path);
            FreeLibrary(module);
        }
    }
    free(mods);
    *out = v;
    return n;
fail:
    free(mods);
    free(v);
    return -1;
}
static void free_jvms(struct jvm_image *v, int n) {
    int i;
    for (i = 0; i < n; i++) {
        if (v[i].handle) FreeLibrary(v[i].handle);
        free(v[i].path);
    }
    free(v);
}
/* The number of VMs created by a JVM module, or -1 if unknown. */
static int created_vms(HMODULE module) {
    JNI_GetCreatedJavaVMs_fnptr created;
    JavaVM *vm;
    jsize count = 0;
    if (!owns_export(module, "JNI_GetCreatedJavaVMs")) return -1;
    created = (JNI_GetCreatedJavaVMs_fnptr) GetProcAddress(module, "JNI_GetCreatedJavaVMs");
    return created && created(&vm, 1, &count) == JNI_OK ? (int) count : -1;
}
/* Keep already loaded runtimes alive; otherwise prefer the selected JDK's
   own set, as java.exe does. Only a missing bundled copy falls back to
   System32. References last until process exit, without changing PATH or
   retaining a DLL search directory. Optional load failures are diagnosed. */
static void load_bundled_msvc(void) {
    static const wchar_t *names[] = {
        L"vcruntime140.dll", L"vcruntime140_1.dll", L"msvcp140.dll",
        L"msvcp140_1.dll", L"msvcp140_2.dll", L"msvcp140_atomic_wait.dll"
    };
    static HMODULE retained[sizeof(names) / sizeof(names[0])];
    wchar_t *path = module_path(jni_dl), *slash, *candidate;
    size_t i, len;
    if (!path) {
        fprintf(stderr, "rJava: cannot determine the selected JVM's MSVC runtime directory (Windows error %lu).\n", (unsigned long) GetLastError());
        return;
    }
    slash = wcsrchr(path, L'\\');
    if (!slash) { free(path); return; }
    *slash = 0; /* bin\server */
    slash = wcsrchr(path, L'\\');
    if (!slash) { free(path); return; }
    *slash = 0; /* bin */
    len = wcslen(path);
    candidate = malloc(sizeof(wchar_t) * (len + 64));
    if (candidate) {
        for (i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
            DWORD attrs, error;
            char *name;
            if (retained[i]) continue;
            /* Unlike GetModuleHandleW, this owns a reference even if the
               component that originally loaded the runtime is unloaded. */
            if (GetModuleHandleExW(0, names[i], &retained[i])) continue;
            wcscpy(candidate, path);
            candidate[len] = L'\\';
            wcscpy(candidate + len + 1, names[i]);
            attrs = GetFileAttributesW(candidate);
            error = attrs == INVALID_FILE_ATTRIBUTES ? GetLastError() : 0;
            if (error && error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND) {
                name = to_utf8(candidate);
                fprintf(stderr, "rJava: cannot inspect bundled MSVC runtime %s (Windows error %lu).\n",
                        name ? name : "(unknown path)", (unsigned long) error);
                free(name);
                continue;
            }
            if (attrs != INVALID_FILE_ATTRIBUTES)
                retained[i] = LoadLibraryExW(candidate, NULL,
                    LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR | LOAD_LIBRARY_SEARCH_SYSTEM32);
            else
                retained[i] = LoadLibraryExW(names[i], NULL, LOAD_LIBRARY_SEARCH_SYSTEM32);
            if (retained[i]) continue;
            error = GetLastError();
            /* A JDK need not use every optional runtime in the list. */
            if (attrs == INVALID_FILE_ATTRIBUTES && error == ERROR_MOD_NOT_FOUND) continue;
            name = to_utf8(attrs != INVALID_FILE_ATTRIBUTES ? candidate : names[i]);
            fprintf(stderr, "rJava: cannot retain MSVC runtime %s (Windows error %lu); later Java native loads may fail.\n",
                    name ? name : "(unknown path)", (unsigned long) error);
            free(name);
        }
        free(candidate);
    } else fprintf(stderr, "rJava: cannot prepare MSVC runtimes: out of memory.\n");
    free(path);
}
static int load_library(const char *path) {
    wchar_t *wide = NULL, *full = NULL, *bin = NULL, *slash;
    struct jvm_image *jvms = NULL;
    DLL_DIRECTORY_COOKIE cookie = NULL;
    int res = -2, n = 0;
    if (!(wide = to_wide(path))) {
        save_win_error("Cannot convert JVM library path to UTF-16", path, GetLastError());
        goto done;
    }
    if (!(full = full_path(wide))) {
        save_win_error("Cannot resolve JVM library path", path, GetLastError());
        goto done;
    }
    for (slash = full; *slash; slash++) if (*slash == L'/') *slash = L'\\';
    if ((n = find_jvms(&jvms)) < 0) {
        save_win_error("Cannot list the modules of", "this process", GetLastError());
        res = -4;
        goto done;
    }
    if (n) {
        /* Two mapped JVM modules are two runtimes, even if they are one file.
           A path selects the mapped module only if it names the mapped file,
           also once a VM was created: djni_attach() attaches without a path. */
        wchar_t *mapped = NULL;
        char *name = jvms[0].path ? to_utf8(jvms[0].path) : NULL;
        int same = -1;
        if (n == 1 && jvms[0].path && (mapped = mapped_path(jvms[0].handle)))
            same = same_file(full, mapped);
        free(mapped);
        if (same == 1 && !is_jvm_name(jvms[0].path)) {
            /* The JDK's DLLs import jvm.dll by name, and the loader matches
               loaded modules by base name: starting this one would load
               another jvm.dll or fail. */
            snprintf(last_error, sizeof(last_error), "The JVM library %s is already mapped under another name: %s. Use a new R process.",
                     path, name ? name : "unknown path");
            res = -4;
        } else if (same == 1) {
            /* Reference the mapped module itself: loading an alias of its path
               must never map a second copy of the JVM. */
            jni_dl = jvms[0].handle;
            jvms[0].handle = NULL;
            res = 0;
        } else {
            if (n > 1)
                snprintf(last_error, sizeof(last_error), "%d JVM libraries are already mapped, including %s. Use a new R process.",
                         n, name ? name : "unknown path");
            else if (same)
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
    if (jvms) free_jvms(jvms, n);
    free(wide); free(full); free(bin);
    return res;
}
/* Takes a reference to the only mapped JVM module if it has created a VM.
   The module's name is not checked: no VM is started, so the JDK's DLLs,
   which import jvm.dll by name, are not loaded again. */
static int attach_library(void) {
    struct jvm_image *jvms;
    char *name;
    int n = find_jvms(&jvms), res = -4;
    if (n < 0) {
        save_win_error("Cannot list the modules of", "this process", GetLastError());
        return -4;
    }
    name = (n && jvms[0].path) ? to_utf8(jvms[0].path) : NULL;
    if (!n)
        snprintf(last_error, sizeof(last_error), "No JVM library is mapped into this process.");
    else if (n > 1)
        snprintf(last_error, sizeof(last_error), "%d JVM libraries are already mapped, including %s. Use a new R process.",
                 n, name ? name : "unknown path");
    else if (created_vms(jvms[0].handle) <= 0)
        snprintf(last_error, sizeof(last_error), "The JVM library mapped into this process has created no VM: %s.",
                 name ? name : "unknown path");
    else {
        jni_dl = jvms[0].handle;
        jvms[0].handle = NULL;
        res = 0;
    }
    free(name);
    free_jvms(jvms, n);
    return res;
}
const char *djni_mapped(int *vms) {
    struct jvm_image *jvms;
    int n;
    *vms = -1;
    free(mapped_name);
    mapped_name = NULL;
    if ((n = find_jvms(&jvms)) < 0) {
        save_win_error("Cannot list the modules of", "this process", GetLastError());
        *vms = -2;
        return NULL;
    }
    if (!n) {
        free(jvms);
        return NULL;
    }
    /* With several JVM modules, the VM count of one is not the answer. */
    if (n == 1) *vms = created_vms(jvms[0].handle);
    mapped_name = jvms[0].path ? to_utf8(jvms[0].path) : NULL;
    if (!mapped_name) mapped_name = strdup("(unknown path)");
    if (!mapped_name) {
        snprintf(last_error, sizeof(last_error), "Cannot report the mapped JVM library: out of memory");
        *vms = -2;
    }
    free_jvms(jvms, n);
    return mapped_name;
}
#else
/* Whether path names the file mapped at addr, by device and inode, which
   hold across symbolic links, hard links and equivalent spellings. The name
   the loader recorded is not used: the file there may have been deleted or
   replaced since, while the mapping keeps the old file. Returns 1 for the
   same file, 0 for another or no file, -1 if the mapped file is unknown, and
   -2 on overlayfs, where a mismatch proves nothing (below). */
static int same_as_mapped(const void *addr, const char *path) {
    struct stat s;
    int res = -1;
    if (stat(path, &s)) return 0;
#ifdef __APPLE__
    {
        struct proc_regionwithpathinfo r;
        uint64_t a = (uint64_t) (uintptr_t) addr;
        /* The region returned starts after addr if nothing is mapped there. */
        if (addr && proc_pidinfo(getpid(), PROC_PIDREGIONPATHINFO, a, &r, sizeof(r)) == (int) sizeof(r) &&
            a >= r.prp_prinfo.pri_address && a - r.prp_prinfo.pri_address < r.prp_prinfo.pri_size &&
            r.prp_vip.vip_vi.vi_stat.vst_ino)
            res = r.prp_vip.vip_vi.vi_stat.vst_dev == (uint32_t) s.st_dev &&
                r.prp_vip.vip_vi.vi_stat.vst_ino == (uint64_t) s.st_ino;
    }
#elif defined(__linux__)
    {
        FILE *f = addr ? fopen("/proc/self/maps", "r") : NULL;
        char *line = NULL;
        size_t size = 0;
        unsigned long long a = (uintptr_t) addr, start, end, ino;
        unsigned int maj = 0, min = 0;
        int device_mismatch = 0;
        struct statfs fs;
        if (f) {
            while (getline(&line, &size, f) > 0)
                if (sscanf(line, "%llx-%llx %*s %*s %x:%x %llu", &start, &end, &maj, &min, &ino) == 5 &&
                    a >= start && a < end) {
                    if (ino) {
                        device_mismatch = major(s.st_dev) != maj || minor(s.st_dev) != min;
                        res = !device_mismatch && (unsigned long long) s.st_ino == ino;
                    }
                    break;
                }
            free(line);
            fclose(f);
        }
        /* Some overlayfs kernels report a layer file in /proc/self/maps,
           while stat() reports the overlay identity. A mismatch is ambiguous. */
        if (!res && device_mismatch && !statfs(path, &fs) && fs.f_type == 0x794c7630) res = -2;
    }
#endif
    return res;
}
static int is_jvm_name(const char *name) {
    const char *base = strrchr(name, '/');
    base = base ? base + 1 : name;
    return !strcmp(base, "libjvm.dylib") || !strcmp(base, "libjvm.so");
}
/* An image mapped into the process: its name as the dynamic loader records
   it, and where it is mapped, to tell its own definitions from those of its
   dependencies. */
struct image {
    char *name;
#ifdef __APPLE__
    const void *header;
#else
    size_t nseg;
    uintptr_t *seg; /* start and end of each PT_LOAD segment */
#endif
};
struct images { struct image *v; size_t n, size; int failed; };
static struct image *add_image(struct images *l, const char *name) {
    struct image *im;
    if (l->n == l->size) {
        size_t size = l->size ? 2 * l->size : 64;
        struct image *v = realloc(l->v, size * sizeof(*v));
        if (!v) { l->failed = 1; return NULL; }
        l->v = v;
        l->size = size;
    }
    im = &l->v[l->n];
    memset(im, 0, sizeof(*im));
    if (!(im->name = strdup(name))) { l->failed = 1; return NULL; }
    l->n++;
    return im;
}
#ifdef __linux__
/* Only records images: dlopen() must not be called from this callback. */
static int phdr_image(struct dl_phdr_info *info, size_t size, void *data) {
    struct images *l = (struct images *) data;
    struct image *im;
    size_t i, n = 0;
    if (!info->dlpi_name || !*info->dlpi_name) return 0; /* the executable */
    if (!(im = add_image(l, info->dlpi_name))) return 1;
    for (i = 0; i < info->dlpi_phnum; i++) if (info->dlpi_phdr[i].p_type == PT_LOAD) n++;
    if (n && !(im->seg = malloc(2 * n * sizeof(uintptr_t)))) { l->failed = 1; return 1; }
    for (i = 0; i < info->dlpi_phnum; i++)
        if (info->dlpi_phdr[i].p_type == PT_LOAD) {
            uintptr_t start = (uintptr_t) info->dlpi_addr + (uintptr_t) info->dlpi_phdr[i].p_vaddr;
            im->seg[2 * im->nseg] = start;
            im->seg[2 * im->nseg++ + 1] = start + (uintptr_t) info->dlpi_phdr[i].p_memsz;
        }
    return 0;
}
#endif
static void free_images(struct images *l) {
    size_t i;
    for (i = 0; i < l->n; i++) {
        free(l->v[i].name);
#ifndef __APPLE__
        free(l->v[i].seg);
#endif
    }
    free(l->v);
}
/* Returns 0, or -1 if the images cannot be listed. Other systems list none. */
static int list_images(struct images *l) {
#ifdef __APPLE__
    uint32_t i, n = _dyld_image_count();
    for (i = 0; i < n; i++) {
        const char *name = _dyld_get_image_name(i);
        const struct mach_header *header = _dyld_get_image_header(i);
        struct image *im;
        if (!name || !header) continue;
        if (!(im = add_image(l, name))) break;
        im->header = header;
    }
#elif defined(__linux__)
    dl_iterate_phdr(phdr_image, l);
#endif
    return l->failed ? -1 : 0;
}
#ifdef RTLD_NOLOAD
/* Whether the image defines sym itself: dlsym() on its handle also finds
   definitions it inherits from the libraries it depends on. */
static int owns(void *handle, const struct image *im, const char *sym) {
    void *p = dlsym(handle, sym);
    if (!p) return 0;
#ifdef __APPLE__
    {
        Dl_info info;
        return dladdr(p, &info) && info.dli_fbase == im->header;
    }
#else
    {
        uintptr_t a = (uintptr_t) p;
        size_t i;
        for (i = 0; i < im->nseg; i++)
            if (a >= im->seg[2 * i] && a < im->seg[2 * i + 1]) return 1;
        return 0;
    }
#endif
}
#endif
struct jvm_image { char *name; void *handle; int owns_created; const void *addr; };
/* Lists the JVM images mapped into the process, each with a reference if
   one can be taken without loading anything. An image is a JVM if it has a
   JVM library name, even if malformed, or if it defines the JNI invocation
   exports and a JVM_ export, whatever its name. JNI exports alone do not
   suffice: the macOS libjli defines them to forward to libjvm. Returns the
   number of JVM images, or -1 if the images cannot be listed. */
static int find_jvms(struct jvm_image **out) {
    struct images l = { NULL, 0, 0, 0 };
    struct jvm_image *v = NULL;
    size_t i;
    int n = 0;
    *out = NULL;
    if (list_images(&l) || (l.n && !(v = calloc(l.n, sizeof(*v))))) {
        free_images(&l);
        return -1;
    }
    for (i = 0; i < l.n; i++) {
        void *handle = NULL;
        int jvm = is_jvm_name(l.v[i].name);
#ifdef RTLD_NOLOAD
        /* RTLD_NOLOAD returns a reference only if the image is already mapped,
           and RTLD_LAZY leaves the relocation of other images unchanged. */
        handle = dlopen(l.v[i].name, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
        if (handle && !jvm)
            jvm = owns(handle, &l.v[i], "JVM_CurrentTimeMillis") && owns(handle, &l.v[i], "JNI_CreateJavaVM") &&
                owns(handle, &l.v[i], "JNI_GetCreatedJavaVMs");
        if (jvm) v[n].owns_created = handle && owns(handle, &l.v[i], "JNI_GetCreatedJavaVMs");
#endif
        if (jvm) {
            v[n].name = l.v[i].name;
            l.v[i].name = NULL;
#ifdef __APPLE__
            v[n].addr = l.v[i].header;
#else
            v[n].addr = l.v[i].nseg ? (const void *) l.v[i].seg[0] : NULL;
#endif
            v[n++].handle = handle;
        } else if (handle)
            dlclose(handle);
    }
    dlerror(); /* failed lookups are not errors of the caller */
    free_images(&l);
    *out = v;
    return n;
}
static void free_jvms(struct jvm_image *v, int n) {
    int i;
    for (i = 0; i < n; i++) {
        if (v[i].handle) dlclose(v[i].handle);
        free(v[i].name);
    }
    free(v);
}
/* The number of VMs created by a JVM image, or -1 if unknown. */
static int created_vms(const struct jvm_image *im) {
    JNI_GetCreatedJavaVMs_fnptr created;
    JavaVM *vm;
    jsize count = 0;
    if (!im->owns_created) return -1;
    *(void **) &created = dlsym(im->handle, "JNI_GetCreatedJavaVMs");
    return created && created(&vm, 1, &count) == JNI_OK ? (int) count : -1;
}
static int load_library(const char *path) {
    struct jvm_image *jvms;
    int n = find_jvms(&jvms), res = -4;
    if (n < 0) {
        snprintf(last_error, sizeof(last_error), "Cannot list the libraries mapped into this process. Use a new R process.");
        return -4;
    }
    if (n > 1) {
        snprintf(last_error, sizeof(last_error), "%d JVM libraries are already mapped, including %s. Use a new R process.",
                 n, jvms[0].name);
    } else if (n == 1) {
        /* A path selects the mapped image only if it names the mapped file,
           also once a VM was created: djni_attach() attaches without a path. */
        int same = same_as_mapped(jvms[0].addr, path);
        if (!same)
            snprintf(last_error, sizeof(last_error), "Another JVM library is already mapped: %s. Use a new R process.", jvms[0].name);
        else if (same == -2)
            snprintf(last_error, sizeof(last_error), "Cannot verify that %s is the JVM library already mapped: %s, because the overlayfs mapping identity cannot be verified. Use a new R process.",
                     path, jvms[0].name);
        else if (same < 0)
            snprintf(last_error, sizeof(last_error), "Cannot verify that %s is the JVM library already mapped: %s. Use a new R process.", path, jvms[0].name);
        else if (!jvms[0].handle)
            snprintf(last_error, sizeof(last_error), "Cannot reference the JVM library already mapped: %s. Use a new R process.", jvms[0].name);
        else {
            /* Reference the mapped image itself, so an alias cannot map another copy. */
            jni_dl = jvms[0].handle;
            jvms[0].handle = NULL;
            res = 0;
        }
    } else if (!(jni_dl = dlopen(path, RTLD_LOCAL | RTLD_NOW))) {
        const char *error = dlerror();
        snprintf(last_error, sizeof(last_error), "%s", error ? error : "dynamic loader error");
        res = -2;
    } else
        res = 0;
    free_jvms(jvms, n);
    return res;
}
/* Takes the reference held to the only mapped JVM image if it has created
   a VM. Its recorded name is not interpreted: the file there may have been
   deleted or replaced, and on overlayfs the mapped file may be unverifiable,
   but the created VM is the image's own. */
static int attach_library(void) {
    struct jvm_image *jvms;
    int n = find_jvms(&jvms), res = -4;
    if (n < 0) {
        snprintf(last_error, sizeof(last_error), "Cannot list the libraries mapped into this process. Use a new R process.");
        return -4;
    }
    if (!n)
        snprintf(last_error, sizeof(last_error), "No JVM library is mapped into this process.");
    else if (n > 1)
        snprintf(last_error, sizeof(last_error), "%d JVM libraries are already mapped, including %s. Use a new R process.",
                 n, jvms[0].name);
    else if (created_vms(&jvms[0]) <= 0)
        snprintf(last_error, sizeof(last_error), "The JVM library mapped into this process has created no VM: %s.", jvms[0].name);
    else {
        jni_dl = jvms[0].handle;
        jvms[0].handle = NULL;
        res = 0;
    }
    free_jvms(jvms, n);
    return res;
}
const char *djni_mapped(int *vms) {
    struct jvm_image *jvms;
    int n;
    *vms = -1;
    free(mapped_name);
    mapped_name = NULL;
    if ((n = find_jvms(&jvms)) < 0) {
        snprintf(last_error, sizeof(last_error), "Cannot list the libraries mapped into this process");
        *vms = -2;
        return NULL;
    }
    /* With several JVM images, the VM count of one is not the answer. */
    if (n == 1) *vms = created_vms(&jvms[0]);
    if (n) {
        mapped_name = jvms[0].name;
        jvms[0].name = NULL;
    }
    free_jvms(jvms, n);
    return mapped_name;
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

/* Resolves the JNI entry points of jni_dl, releasing it if one is missing. */
static int load_syms(void) {
    if (load_sym("JNI_GetDefaultJavaVMInitArgs", (void **) &JNI_GetDefaultJavaVMInitArgs_fn) ||
        load_sym("JNI_CreateJavaVM", (void **) &JNI_CreateJavaVM_fn) ||
        load_sym("JNI_GetCreatedJavaVMs", (void **) &JNI_GetCreatedJavaVMs_fn)) {
        djni_unload();
        return -3;
    }
    return 0;
}

/* returns: 0 = success, -1 = already loaded, -2 = load error, -3 = symbols
   not found, -4 = another JVM library is already mapped */
int djni_load(const char *path) {
    int res;
    last_error[0] = 0;
    if (jni_dl) return -1;
    if ((res = load_library(path))) return res;
    res = load_syms();
#ifdef _WIN32
    if (!res) load_bundled_msvc();
#endif
    return res;
}
/* returns: 0 = success, -1 = already loaded, -3 = symbols not found, -4 = no
   single mapped JVM library with a created VM */
int djni_attach(void) {
    int res;
    last_error[0] = 0;
    if (jni_dl) return -1;
    if ((res = attach_library())) return res;
    res = load_syms();
#ifdef _WIN32
    if (!res) load_bundled_msvc();
#endif
    return res;
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

static void debug_add_image(const struct mach_header* mh, intptr_t vmaddr_slide) {
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
    _dyld_register_func_for_add_image(debug_add_image);
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
