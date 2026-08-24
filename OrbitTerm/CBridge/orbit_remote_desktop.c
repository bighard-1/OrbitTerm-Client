#include "orbit_remote_desktop.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#endif

struct orbit_rdp_session {
    orbit_rdp_session_options options;
    char* host;
};

typedef const char* (*orbit_freerdp_version_fn)(void);

static void orbit_copy_string(char* destination, size_t capacity, const char* source) {
    if (!destination || capacity == 0) return;
    if (!source) source = "";
    (void)snprintf(destination, capacity, "%s", source);
}

#if defined(__APPLE__) && TARGET_OS_OSX
static void* orbit_open_freerdp_library(void) {
    const char* candidates[] = {
        "@rpath/libfreerdp3.dylib",
        "libfreerdp3.dylib",
        "libfreerdp3.3.dylib"
    };

    uint32_t executable_capacity = PATH_MAX;
    char executable_path[PATH_MAX] = { 0 };
    if (_NSGetExecutablePath(executable_path, &executable_capacity) == 0) {
        char* macos_component = strstr(executable_path, "/Contents/MacOS/");
        if (macos_component) {
            char bundled_library[PATH_MAX] = { 0 };
            *macos_component = '\0';
            (void)snprintf(
                bundled_library,
                sizeof(bundled_library),
                "%s/Contents/Frameworks/libfreerdp3.3.dylib",
                executable_path
            );
            void* bundled = dlopen(bundled_library, RTLD_NOW | RTLD_LOCAL);
            if (bundled) return bundled;
        }
    }

    for (size_t index = 0; index < sizeof(candidates) / sizeof(candidates[0]); index++) {
        void* handle = dlopen(candidates[index], RTLD_NOW | RTLD_LOCAL);
        if (handle) return handle;
    }
    return NULL;
}
#endif

uint32_t orbit_rdp_abi_version(void) {
    return ORBIT_RDP_ABI_VERSION;
}

const char* orbit_rdp_expected_freerdp_version(void) {
    return ORBIT_RDP_EXPECTED_FREERDP_VERSION;
}

orbit_rdp_runtime_status orbit_rdp_runtime_probe(char* version, size_t version_capacity) {
    orbit_copy_string(version, version_capacity, "");
#if defined(__APPLE__) && TARGET_OS_OSX
    void* handle = orbit_open_freerdp_library();
    if (!handle) return ORBIT_RDP_RUNTIME_UNAVAILABLE;

    orbit_freerdp_version_fn get_version =
        (orbit_freerdp_version_fn)dlsym(handle, "freerdp_get_version_string");
    if (!get_version) {
        dlclose(handle);
        return ORBIT_RDP_RUNTIME_UNAVAILABLE;
    }

    const char* actual = get_version();
    orbit_copy_string(version, version_capacity, actual);
    const int matches = actual && strcmp(actual, ORBIT_RDP_EXPECTED_FREERDP_VERSION) == 0;
    dlclose(handle);
    return matches ? ORBIT_RDP_RUNTIME_AVAILABLE : ORBIT_RDP_RUNTIME_VERSION_MISMATCH;
#else
    return ORBIT_RDP_RUNTIME_UNAVAILABLE;
#endif
}

orbit_rdp_result orbit_rdp_session_create(
    const orbit_rdp_session_options* options,
    orbit_rdp_session** out_session
) {
    if (!options || !out_session || options->abi_version != ORBIT_RDP_ABI_VERSION ||
        !options->host || options->host[0] == '\0' || options->port == 0) {
        return ORBIT_RDP_INVALID_ARGUMENT;
    }

    *out_session = NULL;
    orbit_rdp_session* session = calloc(1, sizeof(*session));
    if (!session) return ORBIT_RDP_ENGINE_UNAVAILABLE;

    const size_t host_length = strlen(options->host);
    session->host = calloc(host_length + 1, sizeof(char));
    if (!session->host) {
        free(session);
        return ORBIT_RDP_ENGINE_UNAVAILABLE;
    }
    memcpy(session->host, options->host, host_length);
    session->options = *options;
    session->options.host = session->host;
    *out_session = session;
    return ORBIT_RDP_OK;
}

orbit_rdp_result orbit_rdp_session_start(orbit_rdp_session* session) {
    if (!session) return ORBIT_RDP_INVALID_ARGUMENT;
    return ORBIT_RDP_NOT_IMPLEMENTED;
}

orbit_rdp_result orbit_rdp_session_stop(orbit_rdp_session* session) {
    if (!session) return ORBIT_RDP_INVALID_ARGUMENT;
    return ORBIT_RDP_OK;
}

void orbit_rdp_session_free(orbit_rdp_session* session) {
    if (!session) return;
    free(session->host);
    free(session);
}
