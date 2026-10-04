/* smoke — proves an unpacked archive works the way a consumer uses it.
 *
 *   smoke <backends-dir> [required-registry ...]
 *
 * 1. Every file in <backends-dir> is opened with the platform loader and
 *    must export `ggml_backend_init` (the entry point GGML_BACKEND_DL
 *    looks for). This is what proves a backend *library* is whole — its
 *    own dependencies resolve — on a machine with no GPU.
 * 2. ggml_backend_load_all_from_path(<backends-dir>) registers what this
 *    machine can use, then llama_backend_init(); every registry and device
 *    is printed. Each name given after the directory must be among the
 *    registries (e.g. CPU; Vulkan where a Vulkan driver, even a software
 *    one, is installed). A GPU *device* is never required.
 *
 * No model is loaded. Exit 0 on success, 1 on any failure.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ggml-backend.h"
#include "ggml.h"
#include "llama.h"

#ifdef _WIN32
#include <windows.h>
#else
#include <dirent.h>
#include <dlfcn.h>
#endif

static int check_library(const char *path) {
#ifdef _WIN32
    HMODULE h = LoadLibraryExA(path, NULL, LOAD_WITH_ALTERED_SEARCH_PATH);
    if (!h) {
        fprintf(stderr, "FAIL load %s: error %lu\n", path, (unsigned long)GetLastError());
        return 1;
    }
    FARPROC init = GetProcAddress(h, "ggml_backend_init");
    FreeLibrary(h);
#else
    void *h = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!h) {
        fprintf(stderr, "FAIL load %s: %s\n", path, dlerror());
        return 1;
    }
    void *init = dlsym(h, "ggml_backend_init");
    /* Not dlclose'd: a backend may have registered process-wide state. */
#endif
    if (!init) {
        fprintf(stderr, "FAIL %s exports no ggml_backend_init\n", path);
        return 1;
    }
    printf("  loads: %s\n", path);
    return 0;
}

static int check_all_libraries(const char *dir, int *count) {
    int failed = 0;
    char path[4096];
    *count = 0;
#ifdef _WIN32
    /* LOAD_WITH_ALTERED_SEARCH_PATH wants backslashes. */
    char win[4096];
    snprintf(win, sizeof win, "%s", dir);
    for (char *c = win; *c; c++)
        if (*c == '/') *c = '\\';
    dir = win;
    WIN32_FIND_DATAA fd;
    snprintf(path, sizeof path, "%s\\*.dll", dir);
    HANDLE it = FindFirstFileA(path, &fd);
    if (it == INVALID_HANDLE_VALUE) return 1;
    do {
        snprintf(path, sizeof path, "%s\\%s", dir, fd.cFileName);
        failed |= check_library(path);
        (*count)++;
    } while (FindNextFileA(it, &fd));
    FindClose(it);
#else
    DIR *d = opendir(dir);
    if (!d) {
        fprintf(stderr, "FAIL cannot open %s\n", dir);
        return 1;
    }
    struct dirent *e;
    while ((e = readdir(d)) != NULL) {
        size_t n = strlen(e->d_name);
        if (n < 4 || strcmp(e->d_name + n - 3, ".so") != 0) continue;
        snprintf(path, sizeof path, "%s/%s", dir, e->d_name);
        failed |= check_library(path);
        (*count)++;
    }
    closedir(d);
#endif
    return failed;
}

static const char *dev_type(enum ggml_backend_dev_type t) {
    switch (t) {
    case GGML_BACKEND_DEVICE_TYPE_CPU: return "cpu";
    case GGML_BACKEND_DEVICE_TYPE_GPU: return "gpu";
    case GGML_BACKEND_DEVICE_TYPE_IGPU: return "igpu";
    case GGML_BACKEND_DEVICE_TYPE_ACCEL: return "accel";
    default: return "other";
    }
}

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: %s <backends-dir> [required-registry ...]\n", argv[0]);
        return 1;
    }
    const char *dir = argv[1];
    int failed = 0, count = 0;

    printf("1. backend libraries in %s\n", dir);
    failed |= check_all_libraries(dir, &count);
    if (count == 0) {
        fprintf(stderr, "FAIL no backend library in %s\n", dir);
        failed = 1;
    }

    printf("2. registries after ggml_backend_load_all_from_path\n");
    ggml_backend_load_all_from_path(dir);
    llama_backend_init();
    size_t regs = ggml_backend_reg_count();
    for (size_t i = 0; i < regs; i++) {
        ggml_backend_reg_t reg = ggml_backend_reg_get(i);
        size_t devs = ggml_backend_reg_dev_count(reg);
        printf("  registry %s: %zu device(s)\n", ggml_backend_reg_name(reg), devs);
        for (size_t j = 0; j < devs; j++) {
            ggml_backend_dev_t dev = ggml_backend_reg_dev_get(reg, j);
            printf("    %s [%s] %s\n", ggml_backend_dev_name(dev),
                   dev_type(ggml_backend_dev_type(dev)), ggml_backend_dev_description(dev));
        }
    }
    for (int a = 2; a < argc; a++) {
        if (!ggml_backend_reg_by_name(argv[a])) {
            fprintf(stderr, "FAIL registry %s did not register\n", argv[a]);
            failed = 1;
        } else {
            printf("  required registry present: %s\n", argv[a]);
        }
    }

    printf("3. llama\n");
    printf("  system info: %s\n", llama_print_system_info());
    printf("  gpu offload: %s\n", llama_supports_gpu_offload() ? "yes" : "no");
    printf("  max devices: %zu\n", llama_max_devices());
    llama_backend_free();

    printf(failed ? "SMOKE FAILED\n" : "SMOKE OK\n");
    return failed;
}
