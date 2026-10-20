/* Test fixture (Linux): unmaps a library unrelated to Java while djni lists
   the mapped images, without a test hook in rJava. Preloaded, it interposes
   dl_iterate_phdr(); built with -DDLRACE_VICTIM, it is that library:
     cc -shared -fPIC -o dlrace.so dlrace.c -ldl -lpthread
     cc -shared -fPIC -DDLRACE_VICTIM -o dlrace-victim.so dlrace.c
   glibc holds its loader lock while dl_iterate_phdr() runs and may unmap any
   image as soon as it returns. dlrace_arm() makes the next listing by rJava
   on the calling thread map the victim before it starts and unmap it right
   after it returns, when djni may no longer read it. dlrace_churn() maps and
   unmaps the victim on another thread instead, concurrently with listings. */
#ifdef DLRACE_VICTIM
int rjava_dlrace_victim(void) { return 42; }
#else
#define _GNU_SOURCE
#include <dlfcn.h>
#include <link.h>
#include <pthread.h>
#include <stdio.h>
#include <string.h>

typedef int (*callback_fn)(struct dl_phdr_info *, size_t, void *);
static int (*real_iterate)(callback_fn, void *);
static char victim[4096];
static pthread_t armed_thread, churn_thread;
static int armed, hits, unmapped, churning, joined = 1, cycles, churn_unmapped;

__attribute__((constructor)) static void init(void) {
    void *real = dlsym(RTLD_NEXT, "dl_iterate_phdr");
    memcpy(&real_iterate, &real, sizeof(real));
}
/* Whether the victim is no longer loaded. musl never unloads a library. */
static int gone(void) {
    void *h = dlopen(victim, RTLD_NOW | RTLD_LOCAL | RTLD_NOLOAD);
    if (h) dlclose(h);
    return !h;
}
static int from_rjava(callback_fn callback) {
    Dl_info info;
    const char *base;
    void *addr;
    memcpy(&addr, &callback, sizeof(addr));
    if (!dladdr(addr, &info) || !info.dli_fname) return 0;
    base = strrchr(info.dli_fname, '/');
    return !strcmp(base ? base + 1 : info.dli_fname, "rJava.so");
}
int dl_iterate_phdr(callback_fn callback, void *data) {
    void *h = NULL;
    int res;
    if (__atomic_load_n(&armed, __ATOMIC_ACQUIRE) && pthread_equal(pthread_self(), armed_thread) &&
        from_rjava(callback)) {
        __atomic_store_n(&armed, 0, __ATOMIC_RELEASE);
        if (!(h = dlopen(victim, RTLD_NOW | RTLD_LOCAL))) fprintf(stderr, "dlrace: %s\n", dlerror());
    }
    res = real_iterate(callback, data);
    if (h) {
        dlclose(h);
        hits++;
        unmapped += gone();
    }
    return res;
}
void dlrace_arm(char **path) {
    snprintf(victim, sizeof(victim), "%s", path[0]);
    armed_thread = pthread_self();
    __atomic_store_n(&armed, 1, __ATOMIC_RELEASE);
}
/* hits: listings by rJava that saw the victim, unmapped: those after which
   it was no longer loaded, armed: whether a listing is still expected. */
void dlrace_counts(int *n, int *closed, int *pending) {
    *n = hits;
    *closed = unmapped;
    *pending = __atomic_load_n(&armed, __ATOMIC_ACQUIRE);
}
static void *churn(void *arg) {
    int i, n = *(int *) arg;
    for (i = 0; i < n; i++) {
        void *h = dlopen(victim, RTLD_NOW | RTLD_LOCAL);
        if (!h) break;
        dlclose(h);
        churn_unmapped += gone();
        __atomic_store_n(&cycles, i + 1, __ATOMIC_RELEASE);
    }
    __atomic_store_n(&churning, 0, __ATOMIC_RELEASE);
    return NULL;
}
void dlrace_churn(char **path, int *n, int *result) {
    static int count;
    if (!joined) { *result = -1; return; }
    snprintf(victim, sizeof(victim), "%s", path[0]);
    count = *n;
    cycles = churn_unmapped = 0;
    churning = 1;
    if ((*result = pthread_create(&churn_thread, NULL, churn, &count))) churning = 0;
    else joined = 0;
}
/* running: whether the thread still runs; once it has stopped, joins it and
   reports its cycles and those after which the victim was unloaded. */
void dlrace_churn_status(int *running, int *done, int *closed) {
    *running = __atomic_load_n(&churning, __ATOMIC_ACQUIRE);
    *done = __atomic_load_n(&cycles, __ATOMIC_ACQUIRE);
    *closed = 0;
    if (!*running && !joined) {
        pthread_join(churn_thread, NULL);
        joined = 1;
    }
    if (!*running) *closed = churn_unmapped;
}
#endif
