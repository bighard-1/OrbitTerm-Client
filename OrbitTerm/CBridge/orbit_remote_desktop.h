#ifndef ORBIT_REMOTE_DESKTOP_H
#define ORBIT_REMOTE_DESKTOP_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define ORBIT_RDP_ABI_VERSION 2u
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
    ORBIT_RDP_NOT_IMPLEMENTED = -3,
    ORBIT_RDP_INVALID_STATE = -4,
    ORBIT_RDP_THREAD_FAILURE = -5
} orbit_rdp_result;

typedef enum orbit_rdp_event_kind {
    ORBIT_RDP_EVENT_STARTING = 1,
    ORBIT_RDP_EVENT_AUTHENTICATING = 2,
    ORBIT_RDP_EVENT_CONNECTED = 3,
    ORBIT_RDP_EVENT_RECONNECTING = 4,
    ORBIT_RDP_EVENT_DISCONNECTED = 5,
    ORBIT_RDP_EVENT_FAILED = 6
} orbit_rdp_event_kind;

typedef enum orbit_rdp_failure_category {
    ORBIT_RDP_FAILURE_UNKNOWN = 0,
    ORBIT_RDP_FAILURE_AUTHENTICATION = 1,
    ORBIT_RDP_FAILURE_NETWORK = 2,
    ORBIT_RDP_FAILURE_TIMEOUT = 3,
    ORBIT_RDP_FAILURE_PROTOCOL = 4,
    ORBIT_RDP_FAILURE_CANCELLED = 5
} orbit_rdp_failure_category;

typedef enum orbit_rdp_certificate_decision {
    ORBIT_RDP_CERTIFICATE_REJECT = 0,
    ORBIT_RDP_CERTIFICATE_ACCEPT_ONCE = 2
} orbit_rdp_certificate_decision;

typedef enum orbit_rdp_pointer_action {
    ORBIT_RDP_POINTER_MOVE = 0,
    ORBIT_RDP_POINTER_LEFT_DOWN = 1,
    ORBIT_RDP_POINTER_LEFT_UP = 2,
    ORBIT_RDP_POINTER_RIGHT_DOWN = 3,
    ORBIT_RDP_POINTER_RIGHT_UP = 4,
    ORBIT_RDP_POINTER_MIDDLE_DOWN = 5,
    ORBIT_RDP_POINTER_MIDDLE_UP = 6,
    ORBIT_RDP_POINTER_WHEEL_VERTICAL = 7,
    ORBIT_RDP_POINTER_WHEEL_HORIZONTAL = 8
} orbit_rdp_pointer_action;

typedef struct orbit_rdp_session orbit_rdp_session;

typedef struct orbit_rdp_session_options {
    uint32_t abi_version;
    const char* host;
    uint16_t port;
    uint32_t desktop_width;
    uint32_t desktop_height;
    uint8_t require_nla;
    const char* username;
    const char* password;
    const char* domain;
} orbit_rdp_session_options;

typedef struct orbit_rdp_certificate_challenge {
    const char* host;
    uint16_t port;
    const char* common_name;
    const char* subject;
    const char* issuer;
    const char* fingerprint;
    uint32_t flags;
    uint8_t changed;
} orbit_rdp_certificate_challenge;

typedef void (*orbit_rdp_event_callback)(orbit_rdp_session*, orbit_rdp_event_kind, uint32_t, void*);
typedef void (*orbit_rdp_certificate_callback)(orbit_rdp_session*, const orbit_rdp_certificate_challenge*, void*);
/* Frame bytes remain owned by FreeRDP and are valid only during this callback. */
typedef void (*orbit_rdp_frame_callback)(orbit_rdp_session*, const uint8_t*, uint32_t, uint32_t, uint32_t, void*);

uint32_t orbit_rdp_abi_version(void);
const char* orbit_rdp_expected_freerdp_version(void);
orbit_rdp_runtime_status orbit_rdp_runtime_probe(char* version, size_t version_capacity);
/* Preloads the audited crypto runtime before a session worker starts. */
orbit_rdp_result orbit_rdp_runtime_prepare(void);
orbit_rdp_failure_category orbit_rdp_classify_error(uint32_t native_error);
orbit_rdp_result orbit_rdp_session_create(const orbit_rdp_session_options*, orbit_rdp_session**);
orbit_rdp_result orbit_rdp_session_set_callbacks(orbit_rdp_session*, orbit_rdp_event_callback, orbit_rdp_certificate_callback, orbit_rdp_frame_callback, void*);
orbit_rdp_result orbit_rdp_session_start(orbit_rdp_session*);
orbit_rdp_result orbit_rdp_session_stop(orbit_rdp_session*);
orbit_rdp_result orbit_rdp_session_reconnect(orbit_rdp_session*);
orbit_rdp_result orbit_rdp_session_decide_certificate(orbit_rdp_session*, orbit_rdp_certificate_decision);
orbit_rdp_result orbit_rdp_session_resize(orbit_rdp_session*, uint32_t, uint32_t);
orbit_rdp_result orbit_rdp_session_send_unicode(orbit_rdp_session*, const uint16_t*, size_t);
orbit_rdp_result orbit_rdp_session_send_scancode(orbit_rdp_session*, uint32_t, uint8_t);
orbit_rdp_result orbit_rdp_session_send_pointer(orbit_rdp_session*, orbit_rdp_pointer_action, uint16_t, uint16_t, int16_t);
void orbit_rdp_session_free(orbit_rdp_session*);

#ifdef __cplusplus
}
#endif
#endif
