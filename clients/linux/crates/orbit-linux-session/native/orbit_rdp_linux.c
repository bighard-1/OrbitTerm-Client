#define _POSIX_C_SOURCE 200809L

#include "orbit_rdp_linux.h"

#include <freerdp/addin.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/rdpgfx.h>
#include <freerdp/channels/rdpgfx.h>
#include <freerdp/freerdp.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/gdi/gfx.h>
#include <freerdp/input.h>
#include <freerdp/locale/keyboard.h>
#include <freerdp/settings.h>
#include <freerdp/update.h>
#include <winpr/crt.h>
#include <winpr/input.h>
#include <winpr/synch.h>

#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__GLIBC__)
#include <malloc.h>
#endif

typedef struct orbit_rdp_context {
    rdpContext context;
    struct orbit_rdp_linux_session* owner;
} orbit_rdp_context;

struct orbit_rdp_linux_session {
    freerdp* instance;
    orbit_rdp_linux_callbacks callbacks;
    char* host;
    char* username;
    char* password;
    char* domain;
    char* config_path;
    pthread_t worker;
    pthread_mutex_t gate;
    pthread_cond_t certificate_ready;
    int gate_initialized;
    int certificate_ready_initialized;
    int worker_created;
    atomic_bool started;
    atomic_bool stopping;
    atomic_bool connected;
    int certificate_decision;
    int certificate_pending;
};

static char* orbit_duplicate(const char* value) {
    return strdup(value ? value : "");
}

static void orbit_secure_free(char* value) {
    if (!value) return;
    const size_t length = strlen(value);
    if (length > 0) SecureZeroMemory(value, length);
    free(value);
}

static void orbit_copy_string(char* destination, size_t capacity, const char* source) {
    if (!destination || capacity == 0) return;
    if (!source) source = "";
    (void)snprintf(destination, capacity, "%s", source);
}

static orbit_rdp_linux_session* orbit_owner(const freerdp* instance) {
    if (!instance || !instance->context) return NULL;
    orbit_rdp_context* context = (orbit_rdp_context*)instance->context;
    return context->owner;
}

static void orbit_publish_state(
    orbit_rdp_linux_session* session,
    orbit_rdp_linux_state state,
    uint32_t error_code
) {
    if (!session || !session->callbacks.state) return;
    const char* name = error_code == 0 ? "" : freerdp_get_last_error_name(error_code);
    session->callbacks.state(
        session->callbacks.user_data,
        (uint32_t)state,
        error_code,
        name ? name : "rdp_error"
    );
}

static DWORD orbit_wait_for_certificate(
    freerdp* instance,
    uint8_t changed,
    const char* host,
    uint16_t port,
    const char* common_name,
    const char* subject,
    const char* issuer,
    const char* fingerprint,
    const char* old_fingerprint,
    DWORD flags
) {
    orbit_rdp_linux_session* session = orbit_owner(instance);
    if (!session || !session->callbacks.certificate) return 0;

    pthread_mutex_lock(&session->gate);
    session->certificate_pending = 1;
    session->certificate_decision = -1;
    pthread_mutex_unlock(&session->gate);

    session->callbacks.certificate(
        session->callbacks.user_data,
        changed,
        host ? host : "",
        port,
        common_name ? common_name : "",
        subject ? subject : "",
        issuer ? issuer : "",
        fingerprint ? fingerprint : "",
        old_fingerprint ? old_fingerprint : "",
        flags
    );

    pthread_mutex_lock(&session->gate);
    while (session->certificate_decision < 0 && !atomic_load(&session->stopping)) {
        pthread_cond_wait(&session->certificate_ready, &session->gate);
    }
    const int accepted = session->certificate_decision > 0 && !atomic_load(&session->stopping);
    session->certificate_pending = 0;
    session->certificate_decision = -1;
    pthread_mutex_unlock(&session->gate);
    return accepted ? 1u : 0u;
}

static DWORD orbit_verify_certificate(
    freerdp* instance,
    const char* host,
    UINT16 port,
    const char* common_name,
    const char* subject,
    const char* issuer,
    const char* fingerprint,
    DWORD flags
) {
    return orbit_wait_for_certificate(
        instance,
        0,
        host,
        port,
        common_name,
        subject,
        issuer,
        fingerprint,
        "",
        flags
    );
}

static DWORD orbit_verify_changed_certificate(
    freerdp* instance,
    const char* host,
    UINT16 port,
    const char* common_name,
    const char* subject,
    const char* issuer,
    const char* new_fingerprint,
    const char* old_subject,
    const char* old_issuer,
    const char* old_fingerprint,
    DWORD flags
) {
    (void)old_subject;
    (void)old_issuer;
    return orbit_wait_for_certificate(
        instance,
        1,
        host,
        port,
        common_name,
        subject,
        issuer,
        new_fingerprint,
        old_fingerprint,
        flags
    );
}

static BOOL orbit_begin_paint(rdpContext* context) {
    (void)context;
    return TRUE;
}

static void orbit_reset_invalid_region(rdpGdi* gdi) {
    if (!gdi || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd) return;
    HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    if (hwnd->invalid) hwnd->invalid->null = TRUE;
    hwnd->ninvalid = 0;
}

static BOOL orbit_damage_region(
    const rdpGdi* gdi,
    uint8_t force_full,
    uint32_t* x,
    uint32_t* y,
    uint32_t* width,
    uint32_t* height
) {
    if (!gdi || !x || !y || !width || !height || gdi->width <= 0 || gdi->height <= 0) {
        return FALSE;
    }
    if (force_full || !gdi->primary || !gdi->primary->hdc || !gdi->primary->hdc->hwnd) {
        *x = 0;
        *y = 0;
        *width = (uint32_t)gdi->width;
        *height = (uint32_t)gdi->height;
        return TRUE;
    }

    const HGDI_WND hwnd = gdi->primary->hdc->hwnd;
    INT32 left = gdi->width;
    INT32 top = gdi->height;
    INT32 right = 0;
    INT32 bottom = 0;
    BOOL found = FALSE;

    if (hwnd->invalid && !hwnd->invalid->null) {
        const GDI_RGN* region = hwnd->invalid;
        left = region->x;
        top = region->y;
        right = region->x + region->w;
        bottom = region->y + region->h;
        found = TRUE;
    }
    if (hwnd->cinvalid && hwnd->ninvalid > 0) {
        for (INT32 index = 0; index < hwnd->ninvalid; index++) {
            const GDI_RGN* region = &hwnd->cinvalid[index];
            if (region->null || region->w <= 0 || region->h <= 0) continue;
            if (!found) {
                left = region->x;
                top = region->y;
                right = region->x + region->w;
                bottom = region->y + region->h;
                found = TRUE;
            } else {
                if (region->x < left) left = region->x;
                if (region->y < top) top = region->y;
                if (region->x + region->w > right) right = region->x + region->w;
                if (region->y + region->h > bottom) bottom = region->y + region->h;
            }
        }
    }
    if (!found) return FALSE;

    if (left < 0) left = 0;
    if (top < 0) top = 0;
    if (right > gdi->width) right = gdi->width;
    if (bottom > gdi->height) bottom = gdi->height;
    if (right <= left || bottom <= top) return FALSE;

    *x = (uint32_t)left;
    *y = (uint32_t)top;
    *width = (uint32_t)(right - left);
    *height = (uint32_t)(bottom - top);
    return TRUE;
}

static BOOL orbit_publish_frame(rdpContext* context, uint8_t force_full) {
    if (!context || !context->gdi || !context->gdi->primary_buffer) return FALSE;
    orbit_rdp_context* orbit_context = (orbit_rdp_context*)context;
    orbit_rdp_linux_session* session = orbit_context->owner;
    if (!session || !session->callbacks.frame) return TRUE;

    const rdpGdi* gdi = context->gdi;
    if (gdi->width <= 0 || gdi->height <= 0 || gdi->stride == 0) return FALSE;
    const size_t height = (size_t)gdi->height;
    if (height > SIZE_MAX / gdi->stride) return FALSE;
    uint32_t damage_x = 0;
    uint32_t damage_y = 0;
    uint32_t damage_width = 0;
    uint32_t damage_height = 0;
    if (!orbit_damage_region(
            gdi,
            force_full,
            &damage_x,
            &damage_y,
            &damage_width,
            &damage_height
        )) {
        orbit_reset_invalid_region(context->gdi);
        return TRUE;
    }
    session->callbacks.frame(
        session->callbacks.user_data,
        (uint32_t)gdi->width,
        (uint32_t)gdi->height,
        gdi->stride,
        gdi->primary_buffer,
        height * gdi->stride,
        damage_x,
        damage_y,
        damage_width,
        damage_height
    );
    orbit_reset_invalid_region(context->gdi);
    return TRUE;
}

static BOOL orbit_end_paint(rdpContext* context) {
    return orbit_publish_frame(context, 0);
}

static BOOL orbit_desktop_resize(rdpContext* context) {
    if (!context || !context->gdi || !context->settings) return FALSE;
    const UINT32 width = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth);
    const UINT32 height = freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight);
    if (!gdi_resize(context->gdi, width, height)) return FALSE;
    return orbit_publish_frame(context, 1);
}

static void orbit_channel_connected(
    void* context,
    const ChannelConnectedEventArgs* event
) {
    rdpContext* rdp_context = (rdpContext*)context;
    if (!rdp_context || !event || !event->name || !event->pInterface) return;
    if (strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        if (!rdp_context->gdi) return;
        (void)gdi_graphics_pipeline_init(
            rdp_context->gdi,
            (RdpgfxClientContext*)event->pInterface
        );
        return;
    }
}

static void orbit_channel_disconnected(
    void* context,
    const ChannelDisconnectedEventArgs* event
) {
    rdpContext* rdp_context = (rdpContext*)context;
    if (!rdp_context || !event || !event->name || !event->pInterface) return;
    if (strcmp(event->name, RDPGFX_DVC_CHANNEL_NAME) == 0) {
        if (!rdp_context->gdi) return;
        gdi_graphics_pipeline_uninit(
            rdp_context->gdi,
            (RdpgfxClientContext*)event->pInterface
        );
        return;
    }
}

static BOOL orbit_pre_connect(freerdp* instance) {
    if (!instance || !instance->context || !instance->context->settings) return FALSE;
    if (!freerdp_settings_set_bool(
        instance->context->settings,
        FreeRDP_CertificateCallbackPreferPEM,
        FALSE
    )) return FALSE;
    if (PubSub_SubscribeChannelConnected(
            instance->context->pubSub,
            orbit_channel_connected
        ) < 0) return FALSE;
    if (PubSub_SubscribeChannelDisconnected(
            instance->context->pubSub,
            orbit_channel_disconnected
        ) < 0) {
        PubSub_UnsubscribeChannelConnected(
            instance->context->pubSub,
            orbit_channel_connected
        );
        return FALSE;
    }
    return TRUE;
}

static BOOL orbit_post_connect(freerdp* instance) {
    if (!instance || !instance->context || !instance->context->update) return FALSE;
    if (!gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    instance->context->update->BeginPaint = orbit_begin_paint;
    instance->context->update->EndPaint = orbit_end_paint;
    instance->context->update->DesktopResize = orbit_desktop_resize;
    return TRUE;
}

static void orbit_post_disconnect(freerdp* instance) {
    if (!instance || !instance->context) return;
    PubSub_UnsubscribeChannelConnected(
        instance->context->pubSub,
        orbit_channel_connected
    );
    PubSub_UnsubscribeChannelDisconnected(
        instance->context->pubSub,
        orbit_channel_disconnected
    );
    if (instance->context->gdi) gdi_free(instance);
}

static void* orbit_worker(void* argument) {
    orbit_rdp_linux_session* session = (orbit_rdp_linux_session*)argument;
    freerdp* instance = session->instance;
    orbit_publish_state(session, ORBIT_RDP_STATE_AUTHENTICATING, 0);

    if (!freerdp_connect(instance)) {
        const uint32_t error = instance && instance->context
            ? freerdp_get_last_error(instance->context)
            : 0;
        orbit_publish_state(session, ORBIT_RDP_STATE_FAILED, error);
        atomic_store(&session->started, false);
        return NULL;
    }

    atomic_store(&session->connected, true);
    orbit_publish_state(session, ORBIT_RDP_STATE_CONNECTED, 0);

    while (!atomic_load(&session->stopping) &&
           !freerdp_shall_disconnect_context(instance->context)) {
        HANDLE handles[MAXIMUM_WAIT_OBJECTS] = { 0 };
        const DWORD count = freerdp_get_event_handles(
            instance->context,
            handles,
            MAXIMUM_WAIT_OBJECTS
        );
        if (count == 0) break;
        const DWORD status = WaitForMultipleObjects(count, handles, FALSE, 100);
        if (status == WAIT_FAILED) break;
        if (status != WAIT_TIMEOUT && !freerdp_check_event_handles(instance->context)) break;
    }

    atomic_store(&session->connected, false);
    const uint32_t disconnect_error = instance && instance->context
        ? freerdp_get_last_error(instance->context)
        : 0;
    (void)freerdp_disconnect(instance);
    if (atomic_load(&session->stopping)) {
        orbit_publish_state(session, ORBIT_RDP_STATE_CLOSED, 0);
    } else if (disconnect_error != 0) {
        orbit_publish_state(session, ORBIT_RDP_STATE_FAILED, disconnect_error);
    } else {
        orbit_publish_state(session, ORBIT_RDP_STATE_DISCONNECTED, 0);
    }
    atomic_store(&session->started, false);
    return NULL;
}

uint32_t orbit_rdp_linux_abi_version(void) {
    return ORBIT_RDP_LINUX_ABI_VERSION;
}

const char* orbit_rdp_linux_expected_version(void) {
    return ORBIT_RDP_LINUX_EXPECTED_VERSION;
}

int32_t orbit_rdp_linux_runtime_probe(char* version, size_t version_capacity) {
    const char* actual = freerdp_get_version_string();
    orbit_copy_string(version, version_capacity, actual);
    if (!actual) return 0;
    unsigned int major = 0;
    unsigned int minor = 0;
    unsigned int patch = 0;
    if (sscanf(actual, "%u.%u.%u", &major, &minor, &patch) != 3) return 2;
    // The native adapter is built against the host headers and only uses the
    // stable FreeRDP 3 API. Accept compatible 3.x maintenance/minor releases
    // at or above the audited baseline; reject older or future-major ABIs.
    return major == 3 && minor >= 30 ? 1 : 2;
}

static int orbit_apply_profile(
    orbit_rdp_linux_session* session,
    const orbit_rdp_linux_profile* profile
) {
    rdpSettings* settings = session->instance->context->settings;
    if (!settings) return 0;
    const BOOL ok =
        freerdp_settings_set_string(settings, FreeRDP_ServerHostname, session->host) &&
        freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, profile->port) &&
        freerdp_settings_set_string(settings, FreeRDP_Username, session->username) &&
        freerdp_settings_set_string(settings, FreeRDP_Password, session->password) &&
        freerdp_settings_set_string(settings, FreeRDP_Domain, session->domain) &&
        freerdp_settings_set_string(settings, FreeRDP_ConfigPath, session->config_path) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, profile->desktop_width) &&
        freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, profile->desktop_height) &&
        freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) &&
        freerdp_settings_set_bool(settings, FreeRDP_Authentication, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_NegotiateSecurityLayer, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, profile->require_nla ? TRUE : FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AutoAcceptCertificate, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SoftwareGdi, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportGraphicsPipeline, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxH264, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxAVC444v2, FALSE) &&
        /*
         * Let the RDP peer negotiate around changing bandwidth while keeping
         * video codecs disabled for the deterministic software-GDI path.
         * Caches are memory-only: no remote pixels are persisted to disk.
         */
        freerdp_settings_set_uint32(settings, FreeRDP_ConnectionType, CONNECTION_TYPE_AUTODETECT) &&
        freerdp_settings_set_bool(settings, FreeRDP_NetworkAutoDetect, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportHeartbeatPdu, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_CompressionEnabled, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_BitmapCacheEnabled, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_BitmapCacheV3Enabled, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_BitmapCachePersistEnabled, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxThinClient, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxSmallCache, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxProgressive, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxProgressiveV2, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxPlanar, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_GfxSendQoeAck, TRUE) &&
        freerdp_settings_set_bool(settings, FreeRDP_TcpKeepAlive, TRUE) &&
        freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveDelay, 5) &&
        freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveInterval, 5) &&
        freerdp_settings_set_uint32(settings, FreeRDP_TcpKeepAliveRetries, 3) &&
        freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_SupportMultitransport, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_DeviceRedirection, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectClipboard, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectDrives, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectHomeDrive, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectSerialPorts, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectSmartCards, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_RedirectPrinters, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AudioCapture, FALSE) &&
        freerdp_settings_set_bool(settings, FreeRDP_AudioPlayback, FALSE);
    return ok ? 1 : 0;
}

int32_t orbit_rdp_linux_session_create(
    const orbit_rdp_linux_profile* profile,
    const orbit_rdp_linux_callbacks* callbacks,
    orbit_rdp_linux_session** out_session
) {
    if (!profile || !callbacks || !out_session ||
        profile->abi_version != ORBIT_RDP_LINUX_ABI_VERSION ||
        !profile->host || profile->host[0] == '\0' || profile->port == 0 ||
        !profile->username || profile->username[0] == '\0' ||
        !profile->password || profile->password[0] == '\0' ||
        !profile->config_path || profile->config_path[0] == '\0' ||
        profile->desktop_width < 320 || profile->desktop_width > 8192 ||
        profile->desktop_height < 240 || profile->desktop_height > 8192) {
        return -1;
    }

    *out_session = NULL;
    orbit_rdp_linux_session* session = calloc(1, sizeof(*session));
    if (!session) return -2;
    session->callbacks = *callbacks;
    session->host = orbit_duplicate(profile->host);
    session->username = orbit_duplicate(profile->username);
    session->password = orbit_duplicate(profile->password);
    session->domain = orbit_duplicate(profile->domain);
    session->config_path = orbit_duplicate(profile->config_path);
    session->certificate_decision = -1;
    if (!session->host || !session->username || !session->password ||
        !session->domain || !session->config_path) {
        orbit_rdp_linux_session_free(session);
        return -2;
    }
    if (pthread_mutex_init(&session->gate, NULL) != 0) {
        orbit_rdp_linux_session_free(session);
        return -2;
    }
    session->gate_initialized = 1;
    if (pthread_cond_init(&session->certificate_ready, NULL) != 0) {
        orbit_rdp_linux_session_free(session);
        return -2;
    }
    session->certificate_ready_initialized = 1;

    session->instance = freerdp_new();
    if (!session->instance) {
        orbit_rdp_linux_session_free(session);
        return -2;
    }
    session->instance->ContextSize = sizeof(orbit_rdp_context);
    session->instance->PreConnect = orbit_pre_connect;
    session->instance->PostConnect = orbit_post_connect;
    session->instance->PostDisconnect = orbit_post_disconnect;
    session->instance->LoadChannels = freerdp_client_load_channels;
    session->instance->VerifyCertificateEx = orbit_verify_certificate;
    session->instance->VerifyChangedCertificateEx = orbit_verify_changed_certificate;
    if (!freerdp_context_new(session->instance)) {
        orbit_rdp_linux_session_free(session);
        return -2;
    }
    if (freerdp_register_addin_provider(
            freerdp_channels_load_static_addin_entry,
            0
        ) != CHANNEL_RC_OK) {
        orbit_rdp_linux_session_free(session);
        return -2;
    }
    ((orbit_rdp_context*)session->instance->context)->owner = session;
    if (!orbit_apply_profile(session, profile)) {
        orbit_rdp_linux_session_free(session);
        return -1;
    }
    *out_session = session;
    return 0;
}

int32_t orbit_rdp_linux_session_start(orbit_rdp_linux_session* session) {
    if (!session || atomic_exchange(&session->started, true)) return -1;
    atomic_store(&session->stopping, false);
    orbit_publish_state(session, ORBIT_RDP_STATE_STARTING, 0);
    if (pthread_create(&session->worker, NULL, orbit_worker, session) != 0) {
        atomic_store(&session->started, false);
        return -2;
    }
    session->worker_created = 1;
    return 0;
}

int32_t orbit_rdp_linux_session_certificate_decision(
    orbit_rdp_linux_session* session,
    uint8_t accept_and_store
) {
    if (!session) return -1;
    pthread_mutex_lock(&session->gate);
    if (!session->certificate_pending) {
        pthread_mutex_unlock(&session->gate);
        return -1;
    }
    session->certificate_decision = accept_and_store ? 1 : 0;
    pthread_cond_broadcast(&session->certificate_ready);
    pthread_mutex_unlock(&session->gate);
    return 0;
}

int32_t orbit_rdp_linux_session_send_pointer(
    orbit_rdp_linux_session* session,
    uint16_t flags,
    uint16_t x,
    uint16_t y
) {
    if (!session || !atomic_load(&session->connected) || !session->instance ||
        !session->instance->context || !session->instance->context->input) return -1;
    return freerdp_input_send_mouse_event(session->instance->context->input, flags, x, y) ? 0 : -2;
}

int32_t orbit_rdp_linux_session_send_keycode(
    orbit_rdp_linux_session* session,
    uint32_t hardware_keycode,
    uint8_t down
) {
    if (!session || !atomic_load(&session->connected) || !session->instance ||
        !session->instance->context || !session->instance->context->input) return -1;
    const DWORD virtual_key = GetVirtualKeyCodeFromKeycode(
        hardware_keycode,
        WINPR_KEYCODE_TYPE_XKB
    );
    if (virtual_key == VK_NONE) return -1;
    const DWORD scancode = GetVirtualScanCodeFromVirtualKeyCode(
        virtual_key,
        WINPR_KBD_TYPE_IBM_ENHANCED
    );
    if (scancode == RDP_SCANCODE_UNKNOWN) return -1;
    return freerdp_input_send_keyboard_event_ex(
        session->instance->context->input,
        down ? TRUE : FALSE,
        FALSE,
        scancode
    ) ? 0 : -2;
}

int32_t orbit_rdp_linux_session_send_unicode(
    orbit_rdp_linux_session* session,
    uint16_t code_unit
) {
    if (!session || code_unit == 0 || !atomic_load(&session->connected) ||
        !session->instance || !session->instance->context ||
        !session->instance->context->input) return -1;
    rdpInput* input = session->instance->context->input;
    if (!freerdp_input_send_unicode_keyboard_event(input, 0, code_unit)) return -2;
    return freerdp_input_send_unicode_keyboard_event(
        input,
        KBD_FLAGS_RELEASE,
        code_unit
    ) ? 0 : -2;
}

int32_t orbit_rdp_linux_session_stop(orbit_rdp_linux_session* session) {
    if (!session) return -1;
    atomic_store(&session->stopping, true);
    if (session->gate_initialized) {
        pthread_mutex_lock(&session->gate);
        session->certificate_decision = 0;
        if (session->certificate_ready_initialized)
            pthread_cond_broadcast(&session->certificate_ready);
        pthread_mutex_unlock(&session->gate);
    }
    if (session->instance && session->instance->context) {
        (void)freerdp_abort_connect_context(session->instance->context);
    }
    if (session->worker_created) {
        (void)pthread_join(session->worker, NULL);
        session->worker_created = 0;
        atomic_store(&session->started, false);
    }
    return 0;
}

void orbit_rdp_linux_session_free(orbit_rdp_linux_session* session) {
    if (!session) return;
    (void)orbit_rdp_linux_session_stop(session);
    if (session->instance) {
        if (session->instance->context) freerdp_context_free(session->instance);
        freerdp_free(session->instance);
    }
    if (session->certificate_ready_initialized)
        pthread_cond_destroy(&session->certificate_ready);
    if (session->gate_initialized)
        pthread_mutex_destroy(&session->gate);
    orbit_secure_free(session->host);
    orbit_secure_free(session->username);
    orbit_secure_free(session->password);
    orbit_secure_free(session->domain);
    orbit_secure_free(session->config_path);
    SecureZeroMemory(session, sizeof(*session));
    free(session);

    /*
     * FreeRDP creates sizeable, short-lived decode and transport arenas. A
     * reconnect replaces the native session after its worker has joined; on
     * glibc those freed pages can otherwise remain in the process RSS for the
     * rest of a long-running desktop session. Trim only at this lifecycle
     * boundary, never on the frame/input hot paths. Other libc targets keep
     * their allocator's normal policy.
     */
#if defined(__GLIBC__)
    (void)malloc_trim(0);
#endif
}
