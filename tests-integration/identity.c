/* Exercise real mapped-file selection without creating a VM. */
#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include "djni.h"

int main(int argc, char **argv) {
    int result, old;
    void *handle, *other;
    if (argc != 4) return 2;
    old = !strcmp(argv[3], "old-btrfs");
    handle = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (!handle) { fprintf(stderr, "%s\n", dlerror()); return 1; }
    result = djni_load(argv[2]);
    printf("different file: %d (%s)\n", result, djni_last_error());
    if (result != -4 || djni_loaded()) return 1;
    other = dlopen(argv[2], RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
    if (other) { dlclose(other); return 1; }
    result = djni_load(argv[1]);
    printf("same file: %d (%s)\n", result,
           djni_last_error() ? djni_last_error() : "success");
    if (old) {
        if (result != -4 || djni_loaded() ||
            !strstr(djni_last_error(), "Another JVM library is already mapped")) return 1;
        puts("PASS old btrfs regression reproduced");
    } else {
        if (result || !djni_loaded()) return 1;
        puts("PASS same mapped file selected without loading another JVM");
    }
    return 0;
}
