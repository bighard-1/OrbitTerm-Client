#ifndef ORBIT_REMOTE_DESKTOP_H
#define ORBIT_REMOTE_DESKTOP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ORBIT_RDP_ABI_VERSION 1u
#define ORBIT_RDP_EXPECTED_FREERDP_VERSION "3.26.0"

typedef enum orbit_rdp_runtime_status {
    ORBIT_RDP_RUNTIME_UNAVAILABLE = 0,
    ORBIT_RDP_RUNTIME_AVAILABLE = 1,
    ORBIT_RDP_RUNTIME_VERSION_MISMATCH = 2
} orbit_rdp_runtime_status;

typedef enum orbit_rdp_result {
    ORBIT_RDP_OK = 0,
    ORBIT_RDP_INVALID_ARGUMENT = -1,
    ORBIT_RDP_ENGINE_UNAVAILABLE = -2,
    ORBIT_RDP_NOT_IMPLEMENTED = -3
} orbit_rdp_result;

typedef struct orbit_rdp_session orbit_rdp_session;

typedef struct orbit_rdp_session_options {
    uint32_t abi_version;
    const char* host;
    uint16_t port;
    uint32_t desktop_width;
    uint32_t desktop_height;
    uint8_t require_nla;
} orbit_rdp_session_options;

uint32_t orbit_rdp_abi_version(void);
const char* orbit_rdp_expected_freerdp_version(void);
orbit_rdp_runtime_status orbit_rdp_runtime_probe(char* version, size_t version_capacity);

orbit_rdp_result orbit_rdp_session_create(
    const orbit_rdp_session_options* options,
    orbit_rdp_session** out_session
);
orbit_rdp_result orbit_rdp_session_start(orbit_rdp_session* session);
orbit_rdp_result orbit_rdp_session_stop(orbit_rdp_session* session);
void orbit_rdp_session_free(orbit_rdp_session* session);

#ifdef __cplusplus
}
#endif

#endif
