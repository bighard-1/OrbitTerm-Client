#ifndef ORBIT_RDP_LINUX_H
#define ORBIT_RDP_LINUX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ORBIT_RDP_LINUX_ABI_VERSION 2u
#define ORBIT_RDP_LINUX_EXPECTED_VERSION "3.30.0"

typedef struct orbit_rdp_linux_session orbit_rdp_linux_session;

typedef enum orbit_rdp_linux_state {
    ORBIT_RDP_STATE_STARTING = 1,
    ORBIT_RDP_STATE_AUTHENTICATING = 2,
    ORBIT_RDP_STATE_CONNECTED = 3,
    ORBIT_RDP_STATE_DISCONNECTED = 4,
    ORBIT_RDP_STATE_FAILED = 5,
    ORBIT_RDP_STATE_CLOSED = 6
} orbit_rdp_linux_state;

typedef struct orbit_rdp_linux_profile {
    uint32_t abi_version;
    const char* host;
    uint16_t port;
    const char* username;
    const char* password;
    const char* domain;
    const char* config_path;
    uint32_t desktop_width;
    uint32_t desktop_height;
    uint8_t require_nla;
} orbit_rdp_linux_profile;

typedef void (*orbit_rdp_state_callback)(
    void* user_data,
    uint32_t state,
    uint32_t error_code,
    const char* error_name
);

typedef void (*orbit_rdp_frame_callback)(
    void* user_data,
    uint32_t width,
    uint32_t height,
    uint32_t stride,
    const uint8_t* bgra,
    size_t byte_length,
    uint32_t damage_x,
    uint32_t damage_y,
    uint32_t damage_width,
    uint32_t damage_height
);

typedef void (*orbit_rdp_certificate_callback)(
    void* user_data,
    uint8_t changed,
    const char* host,
    uint16_t port,
    const char* common_name,
    const char* subject,
    const char* issuer,
    const char* fingerprint,
    const char* old_fingerprint,
    uint32_t flags
);

typedef struct orbit_rdp_linux_callbacks {
    void* user_data;
    orbit_rdp_state_callback state;
    orbit_rdp_frame_callback frame;
    orbit_rdp_certificate_callback certificate;
} orbit_rdp_linux_callbacks;

uint32_t orbit_rdp_linux_abi_version(void);
const char* orbit_rdp_linux_expected_version(void);
int32_t orbit_rdp_linux_runtime_probe(char* version, size_t version_capacity);

int32_t orbit_rdp_linux_session_create(
    const orbit_rdp_linux_profile* profile,
    const orbit_rdp_linux_callbacks* callbacks,
    orbit_rdp_linux_session** out_session
);
int32_t orbit_rdp_linux_session_start(orbit_rdp_linux_session* session);
int32_t orbit_rdp_linux_session_certificate_decision(
    orbit_rdp_linux_session* session,
    uint8_t accept_and_store
);
int32_t orbit_rdp_linux_session_send_pointer(
    orbit_rdp_linux_session* session,
    uint16_t flags,
    uint16_t x,
    uint16_t y
);
int32_t orbit_rdp_linux_session_send_keycode(
    orbit_rdp_linux_session* session,
    uint32_t hardware_keycode,
    uint8_t down
);
int32_t orbit_rdp_linux_session_send_unicode(
    orbit_rdp_linux_session* session,
    uint16_t code_unit
);
int32_t orbit_rdp_linux_session_stop(orbit_rdp_linux_session* session);
void orbit_rdp_linux_session_free(orbit_rdp_linux_session* session);

#ifdef __cplusplus
}
#endif

#endif
