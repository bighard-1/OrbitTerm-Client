#include "orbit_remote_desktop.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if defined(__APPLE__)
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <unistd.h>
#endif

#if defined(__APPLE__) && TARGET_OS_OSX && __has_include(<freerdp/freerdp.h>)
#define ORBIT_RDP_HAS_FREERDP 1
#include <pthread.h>
#include <freerdp/freerdp.h>
#include <freerdp/client.h>
#include <freerdp/client/channels.h>
#include <freerdp/client/cmdline.h>
#include <freerdp/client/disp.h>
#include <freerdp/channels/disp.h>
#include <freerdp/error.h>
#include <freerdp/event.h>
#include <freerdp/gdi/gdi.h>
#include <freerdp/input.h>
#include <freerdp/settings.h>
#include <freerdp/settings_keys.h>
#include <freerdp/codec/color.h>
#include <winpr/synch.h>
#include <winpr/ssl.h>
#include <winpr/sysinfo.h>
#else
#define ORBIT_RDP_HAS_FREERDP 0
#endif

struct orbit_rdp_session {
    orbit_rdp_session_options options;
    char* host;
    char* username;
    char* password;
    char* domain;
    orbit_rdp_event_callback event_callback;
    orbit_rdp_certificate_callback certificate_callback;
    orbit_rdp_frame_callback frame_callback;
    void* user_data;
#if ORBIT_RDP_HAS_FREERDP
    pthread_t worker;
    pthread_mutex_t lock;
    pthread_cond_t certificate_condition;
    freerdp* instance;
    DispClientContext* display_control;
    HANDLE wake_event;
    uint64_t last_frame_tick;
    uint32_t pending_width;
    uint32_t pending_height;
    uint8_t synchronization_ready;
    uint8_t worker_started;
    uint8_t worker_joinable;
    uint8_t stop_requested;
    uint8_t reconnect_requested;
    uint8_t resize_pending;
    uint8_t display_control_ready;
    uint8_t certificate_waiting;
    int certificate_decision;
#endif
};

typedef const char* (*orbit_freerdp_version_fn)(void);

static void orbit_copy_string(char* destination, size_t capacity, const char* source) {
    if (!destination || capacity == 0) return;
    (void)snprintf(destination, capacity, "%s", source ? source : "");
}

static char* orbit_duplicate_string(const char* value) {
    if (!value) value = "";
    const size_t length = strlen(value);
    char* copy = calloc(length + 1, 1);
    if (copy) memcpy(copy, value, length);
    return copy;
}

static void orbit_secure_free(char** value) {
    if (!value || !*value) return;
    volatile unsigned char* cursor = (volatile unsigned char*)*value;
    const size_t length = strlen(*value);
    for (size_t index = 0; index < length; index++) cursor[index] = 0;
    free(*value);
    *value = NULL;
}

#if defined(__APPLE__) && TARGET_OS_OSX
static int orbit_bundled_openssl_modules_path(char* destination, size_t capacity) {
    if (!destination || capacity == 0) return 0;
    uint32_t executable_capacity = PATH_MAX;
    char executable[PATH_MAX] = { 0 };
    if (_NSGetExecutablePath(executable, &executable_capacity) != 0) return 0;
    char* component = strstr(executable, "/Contents/MacOS/");
    if (!component) return 0;
    *component = '\0';
    const int written = snprintf(destination, capacity,
                                 "%s/Contents/Frameworks/ossl-modules", executable);
    if (written <= 0 || (size_t)written >= capacity) return 0;
    char provider[PATH_MAX] = { 0 };
    const int provider_written = snprintf(provider, sizeof(provider), "%s/legacy.dylib", destination);
    return provider_written > 0 && (size_t)provider_written < sizeof(provider) &&
           access(provider, R_OK) == 0;
}

static void* orbit_open_freerdp_library(void) {
    const char* candidates[] = { "@rpath/libfreerdp3.dylib", "libfreerdp3.dylib", "libfreerdp3.3.dylib" };
    uint32_t capacity = PATH_MAX;
    char path[PATH_MAX] = { 0 };
    if (_NSGetExecutablePath(path, &capacity) == 0) {
        char* component = strstr(path, "/Contents/MacOS/");
        if (component) {
            char bundled[PATH_MAX] = { 0 };
            *component = '\0';
            (void)snprintf(bundled, sizeof(bundled), "%s/Contents/Frameworks/libfreerdp3.3.dylib", path);
            void* handle = dlopen(bundled, RTLD_NOW | RTLD_LOCAL);
            if (handle) return handle;
        }
    }
    for (size_t index = 0; index < sizeof(candidates) / sizeof(candidates[0]); index++) {
        void* handle = dlopen(candidates[index], RTLD_NOW | RTLD_LOCAL);
        if (handle) return handle;
    }
    return NULL;
}
#endif

uint32_t orbit_rdp_abi_version(void) { return ORBIT_RDP_ABI_VERSION; }
const char* orbit_rdp_expected_freerdp_version(void) { return ORBIT_RDP_EXPECTED_FREERDP_VERSION; }

orbit_rdp_runtime_status orbit_rdp_runtime_probe(char* version, size_t capacity) {
    orbit_copy_string(version, capacity, "");
#if defined(__APPLE__) && TARGET_OS_OSX
    void* handle = orbit_open_freerdp_library();
    if (!handle) return ORBIT_RDP_RUNTIME_UNAVAILABLE;
    orbit_freerdp_version_fn get_version = (orbit_freerdp_version_fn)dlsym(handle, "freerdp_get_version_string");
    if (!get_version) { dlclose(handle); return ORBIT_RDP_RUNTIME_UNAVAILABLE; }
    const char* actual = get_version();
    orbit_copy_string(version, capacity, actual);
    const int matches = actual && strcmp(actual, ORBIT_RDP_EXPECTED_FREERDP_VERSION) == 0;
    dlclose(handle);
    return matches ? ORBIT_RDP_RUNTIME_AVAILABLE : ORBIT_RDP_RUNTIME_VERSION_MISMATCH;
#else
    return ORBIT_RDP_RUNTIME_UNAVAILABLE;
#endif
}

#if ORBIT_RDP_HAS_FREERDP
static pthread_once_t orbit_ssl_once = PTHREAD_ONCE_INIT;
static int orbit_ssl_ready = 0;

static void orbit_initialize_ssl_runtime(void) {
    char modules[PATH_MAX] = { 0 };
    if (orbit_bundled_openssl_modules_path(modules, sizeof(modules)))
        (void)setenv("OPENSSL_MODULES", modules, 1);
    orbit_ssl_ready = winpr_InitializeSSL(WINPR_SSL_INIT_DEFAULT) ? 1 : 0;
}
#endif

orbit_rdp_result orbit_rdp_runtime_prepare(void) {
#if ORBIT_RDP_HAS_FREERDP
    if (pthread_once(&orbit_ssl_once, orbit_initialize_ssl_runtime) != 0)
        return ORBIT_RDP_THREAD_FAILURE;
    return orbit_ssl_ready ? ORBIT_RDP_OK : ORBIT_RDP_ENGINE_UNAVAILABLE;
#else
    return ORBIT_RDP_ENGINE_UNAVAILABLE;
#endif
}

orbit_rdp_failure_category orbit_rdp_classify_error(uint32_t native_error) {
#if ORBIT_RDP_HAS_FREERDP
    switch (native_error) {
        case FREERDP_ERROR_AUTHENTICATION_FAILED:
        case FREERDP_ERROR_CONNECT_LOGON_FAILURE:
        case FREERDP_ERROR_CONNECT_WRONG_PASSWORD:
        case FREERDP_ERROR_CONNECT_ACCESS_DENIED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_DISABLED:
        case FREERDP_ERROR_CONNECT_ACCOUNT_LOCKED_OUT:
        case FREERDP_ERROR_CONNECT_ACCOUNT_EXPIRED:
        case FREERDP_ERROR_CONNECT_LOGON_TYPE_NOT_GRANTED:
        case FREERDP_ERROR_CONNECT_NO_OR_MISSING_CREDENTIALS:
            return ORBIT_RDP_FAILURE_AUTHENTICATION;
        case FREERDP_ERROR_DNS_ERROR:
        case FREERDP_ERROR_DNS_NAME_NOT_FOUND:
        case FREERDP_ERROR_CONNECT_FAILED:
        case FREERDP_ERROR_CONNECT_TRANSPORT_FAILED:
        case FREERDP_ERROR_CONNECT_KDC_UNREACHABLE:
            return ORBIT_RDP_FAILURE_NETWORK;
        case FREERDP_ERROR_IDLE_TIMEOUT:
        case FREERDP_ERROR_LOGON_TIMEOUT:
        case FREERDP_ERROR_CONNECT_ACTIVATION_TIMEOUT:
            return ORBIT_RDP_FAILURE_TIMEOUT;
        case FREERDP_ERROR_CONNECT_CANCELLED:
            return ORBIT_RDP_FAILURE_CANCELLED;
        case 0:
            return ORBIT_RDP_FAILURE_UNKNOWN;
        default:
            return ORBIT_RDP_FAILURE_PROTOCOL;
    }
#else
    return native_error == 0 ? ORBIT_RDP_FAILURE_UNKNOWN : ORBIT_RDP_FAILURE_PROTOCOL;
#endif
}

#if ORBIT_RDP_HAS_FREERDP
typedef struct orbit_rdp_context { rdpContext context; orbit_rdp_session* session; } orbit_rdp_context;

static pthread_once_t orbit_addin_provider_once = PTHREAD_ONCE_INIT;
static int orbit_addin_provider_status = -1;

static void orbit_register_addin_provider(void) {
    orbit_addin_provider_status = freerdp_register_addin_provider(
        freerdp_channels_load_static_addin_entry, 0
    );
}

static orbit_rdp_session* orbit_session_from_context(rdpContext* context) {
    return context ? ((orbit_rdp_context*)context)->session : NULL;
}
static orbit_rdp_session* orbit_session_from_instance(freerdp* instance) {
    return instance ? orbit_session_from_context(instance->context) : NULL;
}
static void orbit_emit_event(orbit_rdp_session* session, orbit_rdp_event_kind event, uint32_t error) {
    if (session && session->event_callback) session->event_callback(session, event, error, session->user_data);
}
static BOOL orbit_context_new(freerdp* instance, rdpContext* context) {
    (void)instance; (void)context; return TRUE;
}
static BOOL orbit_begin_paint(rdpContext* context) {
    if (!context || !context->gdi || !context->gdi->primary || !context->gdi->primary->hdc ||
        !context->gdi->primary->hdc->hwnd || !context->gdi->primary->hdc->hwnd->invalid) return FALSE;
    context->gdi->primary->hdc->hwnd->invalid->null = TRUE;
    return TRUE;
}
static BOOL orbit_end_paint(rdpContext* context) {
    orbit_rdp_session* session = orbit_session_from_context(context);
    if (!session || !context->gdi || !context->gdi->primary_buffer) return FALSE;
    const uint64_t now = GetTickCount64();
    if (session->last_frame_tick != 0 && now - session->last_frame_tick < 33) return TRUE;
    session->last_frame_tick = now;
    if (session->frame_callback) {
        session->frame_callback(session, context->gdi->primary_buffer, (uint32_t)context->gdi->width,
                                (uint32_t)context->gdi->height, context->gdi->stride, session->user_data);
    }
    return TRUE;
}
static BOOL orbit_desktop_resize(rdpContext* context) {
    if (!context || !context->gdi || !context->settings) return FALSE;
    return gdi_resize(context->gdi,
                      freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopWidth),
                      freerdp_settings_get_uint32(context->settings, FreeRDP_DesktopHeight));
}
static BOOL orbit_post_connect(freerdp* instance) {
    if (!instance || !instance->context || !gdi_init(instance, PIXEL_FORMAT_BGRA32)) return FALSE;
    rdpUpdate* update = instance->context->update;
    if (!update) return FALSE;
    update->BeginPaint = orbit_begin_paint;
    update->EndPaint = orbit_end_paint;
    update->DesktopResize = orbit_desktop_resize;
    return TRUE;
}
static void orbit_post_disconnect(freerdp* instance) {
    if (instance && instance->context && instance->context->gdi) gdi_free(instance);
}

static UINT orbit_display_control_caps(DispClientContext* display, UINT32 max_monitors,
                                       UINT32 area_factor_a, UINT32 area_factor_b) {
    (void)max_monitors;
    (void)area_factor_a;
    (void)area_factor_b;
    orbit_rdp_session* session = display ? (orbit_rdp_session*)display->custom : NULL;
    if (!session) return CHANNEL_RC_BAD_CHANNEL;
    pthread_mutex_lock(&session->lock);
    session->display_control = display;
    session->display_control_ready = 1;
    session->resize_pending = 1;
    pthread_mutex_unlock(&session->lock);
    if (session->wake_event) SetEvent(session->wake_event);
    return CHANNEL_RC_OK;
}

static void orbit_channel_connected(void* context, const ChannelConnectedEventArgs* event) {
    orbit_rdp_session* session = orbit_session_from_context((rdpContext*)context);
    if (!session || !event || !event->name) return;
    if (getenv("ORBIT_RDP_DEBUG"))
        fprintf(stderr, "orbit-rdp channel connected: %s\n", event->name);
    if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        DispClientContext* display = (DispClientContext*)event->pInterface;
        if (!display) return;
        display->custom = session;
        display->DisplayControlCaps = orbit_display_control_caps;
        pthread_mutex_lock(&session->lock);
        session->display_control = display;
        session->display_control_ready = 0;
        session->resize_pending = 1;
        pthread_mutex_unlock(&session->lock);
    } else {
        freerdp_client_OnChannelConnectedEventHandler(context, event);
    }
}

static void orbit_channel_disconnected(void* context, const ChannelDisconnectedEventArgs* event) {
    orbit_rdp_session* session = orbit_session_from_context((rdpContext*)context);
    if (!session || !event || !event->name) return;
    if (strcmp(event->name, DISP_DVC_CHANNEL_NAME) == 0) {
        DispClientContext* display = (DispClientContext*)event->pInterface;
        if (display) display->custom = NULL;
        pthread_mutex_lock(&session->lock);
        session->display_control = NULL;
        session->display_control_ready = 0;
        pthread_mutex_unlock(&session->lock);
    } else {
        freerdp_client_OnChannelDisconnectedEventHandler(context, event);
    }
}

static BOOL orbit_load_channels(freerdp* instance) {
    return instance && instance->context &&
           freerdp_client_load_addins(instance->context->channels, instance->context->settings);
}

static void orbit_apply_pending_resize(orbit_rdp_session* session) {
    if (!session) return;
    pthread_mutex_lock(&session->lock);
    DispClientContext* display = session->display_control;
    const uint32_t width = session->pending_width;
    const uint32_t height = session->pending_height;
    const int pending = session->resize_pending && session->display_control_ready;
    if (pending && display) session->resize_pending = 0;
    pthread_mutex_unlock(&session->lock);
    if (!pending || !display || !display->SendMonitorLayout) return;

    DISPLAY_CONTROL_MONITOR_LAYOUT layout = { 0 };
    layout.Flags = DISPLAY_CONTROL_MONITOR_PRIMARY;
    layout.Top = 0;
    layout.Left = 0;
    layout.Width = width;
    layout.Height = height;
    layout.Orientation = 0;
    layout.DesktopScaleFactor = 100;
    layout.DeviceScaleFactor = 100;
    layout.PhysicalWidth = width;
    layout.PhysicalHeight = height;
    const UINT resize_status = display->SendMonitorLayout(display, 1, &layout);
    if (getenv("ORBIT_RDP_DEBUG"))
        fprintf(stderr, "orbit-rdp resize %ux%u status=%u\n", width, height, resize_status);
    if (resize_status != CHANNEL_RC_OK) {
        pthread_mutex_lock(&session->lock);
        session->resize_pending = 1;
        pthread_mutex_unlock(&session->lock);
    }
}

static DWORD orbit_wait_for_certificate(orbit_rdp_session* session, const orbit_rdp_certificate_challenge* challenge) {
    if (!session || !session->certificate_callback) return ORBIT_RDP_CERTIFICATE_REJECT;
    pthread_mutex_lock(&session->lock);
    session->certificate_waiting = 1;
    session->certificate_decision = -1;
    pthread_mutex_unlock(&session->lock);
    session->certificate_callback(session, challenge, session->user_data);
    pthread_mutex_lock(&session->lock);
    while (session->certificate_decision < 0 && !session->stop_requested)
        pthread_cond_wait(&session->certificate_condition, &session->lock);
    const int decision = session->stop_requested ? ORBIT_RDP_CERTIFICATE_REJECT : session->certificate_decision;
    session->certificate_waiting = 0;
    pthread_mutex_unlock(&session->lock);
    return (DWORD)decision;
}
static DWORD orbit_verify_certificate(freerdp* instance, const char* host, UINT16 port,
                                      const char* common_name, const char* subject,
                                      const char* issuer, const char* fingerprint, DWORD flags) {
    orbit_rdp_certificate_challenge challenge = {
        host, port, common_name, subject, issuer, fingerprint, flags, 0
    };
    return orbit_wait_for_certificate(orbit_session_from_instance(instance), &challenge);
}
static DWORD orbit_verify_changed_certificate(freerdp* instance, const char* host, UINT16 port,
                                              const char* common_name, const char* subject,
                                              const char* issuer, const char* new_fingerprint,
                                              const char* old_subject, const char* old_issuer,
                                              const char* old_fingerprint, DWORD flags) {
    (void)old_subject; (void)old_issuer; (void)old_fingerprint;
    orbit_rdp_certificate_challenge challenge = {
        host, port, common_name, subject, issuer, new_fingerprint, flags, 1
    };
    return orbit_wait_for_certificate(orbit_session_from_instance(instance), &challenge);
}

static int orbit_configure_instance(orbit_rdp_session* session, freerdp* instance) {
    if (!session || !instance || !freerdp_context_new(instance)) return 0;
    pthread_once(&orbit_addin_provider_once, orbit_register_addin_provider);
    if (orbit_addin_provider_status != CHANNEL_RC_OK) return 0;
    ((orbit_rdp_context*)instance->context)->session = session;
    instance->PostConnect = orbit_post_connect;
    instance->PostDisconnect = orbit_post_disconnect;
    instance->LoadChannels = orbit_load_channels;
    instance->VerifyCertificateEx = orbit_verify_certificate;
    instance->VerifyChangedCertificateEx = orbit_verify_changed_certificate;
    rdpSettings* settings = instance->context->settings;
    if (!settings) return 0;
    char client_name[] = "orbitterm-rdp";
    char target[512] = { 0 };
    char username[512] = { 0 };
    char size[] = "/size:1440x900";
    char certificate[] = "/cert:deny";
    const int target_length = snprintf(target, sizeof(target), "/v:%s:%u", session->host,
                                       (unsigned)session->options.port);
    const int username_length = snprintf(username, sizeof(username), "/u:%s", session->username);
    if (target_length <= 0 || (size_t)target_length >= sizeof(target) ||
        username_length <= 0 || (size_t)username_length >= sizeof(username))
        return 0;
    char* client_arguments[] = { client_name, target, username, size, certificate };
    if (freerdp_client_settings_parse_command_line(settings, 5, client_arguments, FALSE) != 0)
        return 0;
    const char* display_channel[] = { DISP_CHANNEL_NAME };
    if (!freerdp_client_add_dynamic_channel(settings, 1, display_channel) ||
        PubSub_SubscribeChannelConnected(instance->context->pubSub, orbit_channel_connected) < 0 ||
        PubSub_SubscribeChannelDisconnected(instance->context->pubSub, orbit_channel_disconnected) < 0)
        return 0;
    return freerdp_settings_set_string(settings, FreeRDP_ServerHostname, session->host) &&
           freerdp_settings_set_uint32(settings, FreeRDP_ServerPort, session->options.port) &&
           freerdp_settings_set_string(settings, FreeRDP_Username, session->username) &&
           freerdp_settings_set_string(settings, FreeRDP_Password, session->password) &&
           freerdp_settings_set_string(settings, FreeRDP_Domain, session->domain) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopWidth, session->options.desktop_width) &&
           freerdp_settings_set_uint32(settings, FreeRDP_DesktopHeight, session->options.desktop_height) &&
           freerdp_settings_set_uint32(settings, FreeRDP_ColorDepth, 32) &&
           freerdp_settings_set_bool(settings, FreeRDP_NlaSecurity, session->options.require_nla != 0) &&
           freerdp_settings_set_bool(settings, FreeRDP_TlsSecurity, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_RdpSecurity, session->options.require_nla == 0) &&
           freerdp_settings_set_bool(settings, FreeRDP_IgnoreCertificate, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_AutoAcceptCertificate, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_AutoDenyCertificate, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_CertificateCallbackPreferPEM, FALSE) &&
           freerdp_settings_set_bool(settings, FreeRDP_DesktopResize, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_DynamicResolutionUpdate, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_SupportDisplayControl, TRUE) &&
           freerdp_settings_set_bool(settings, FreeRDP_AutoReconnectionEnabled, FALSE);
}
static void orbit_destroy_instance(freerdp* instance) {
    if (!instance) return;
    if (instance->context) freerdp_context_free(instance);
    freerdp_free(instance);
}
static void orbit_abort_active_instance(orbit_rdp_session* session) {
    pthread_mutex_lock(&session->lock);
    freerdp* instance = session->instance;
    pthread_mutex_unlock(&session->lock);
    if (instance && instance->context) (void)freerdp_abort_connect_context(instance->context);
}

static void* orbit_rdp_worker(void* argument) {
    orbit_rdp_session* session = argument;
    int reconnecting = 0;
    for (;;) {
        pthread_mutex_lock(&session->lock);
        const int should_stop = session->stop_requested;
        session->reconnect_requested = 0;
        pthread_mutex_unlock(&session->lock);
        if (should_stop) break;
        orbit_emit_event(session, reconnecting ? ORBIT_RDP_EVENT_RECONNECTING : ORBIT_RDP_EVENT_STARTING, 0);
        freerdp* instance = freerdp_new();
        if (!instance) { orbit_emit_event(session, ORBIT_RDP_EVENT_FAILED, FREERDP_ERROR_CONNECT_FAILED); break; }
        instance->ContextSize = sizeof(orbit_rdp_context);
        instance->ContextNew = orbit_context_new;
        if (!orbit_configure_instance(session, instance)) {
            orbit_destroy_instance(instance);
            orbit_emit_event(session, ORBIT_RDP_EVENT_FAILED, FREERDP_ERROR_CONNECT_FAILED);
            break;
        }
        pthread_mutex_lock(&session->lock);
        session->instance = instance;
        pthread_mutex_unlock(&session->lock);
        orbit_emit_event(session, ORBIT_RDP_EVENT_AUTHENTICATING, 0);
        const BOOL connected = freerdp_connect(instance);
        if (connected) {
            orbit_emit_event(session, ORBIT_RDP_EVENT_CONNECTED, 0);
            while (!freerdp_shall_disconnect_context(instance->context)) {
                pthread_mutex_lock(&session->lock);
                const int stop = session->stop_requested;
                const int reconnect = session->reconnect_requested;
                pthread_mutex_unlock(&session->lock);
                if (stop || reconnect) break;
                HANDLE handles[64] = { 0 };
                DWORD count = freerdp_get_event_handles(instance->context, handles, 63);
                if (count == 0) break;
                if (session->wake_event) handles[count++] = session->wake_event;
                const DWORD wait = WaitForMultipleObjects(count, handles, FALSE, 50);
                if (wait == WAIT_FAILED || !freerdp_check_event_handles(instance->context)) break;
                if (session->wake_event && WaitForSingleObject(session->wake_event, 0) == WAIT_OBJECT_0) {
                    ResetEvent(session->wake_event);
                    orbit_apply_pending_resize(session);
                }
            }
            (void)freerdp_disconnect(instance);
        }
        const uint32_t error = instance->context ? freerdp_get_last_error(instance->context) : 0;
        pthread_mutex_lock(&session->lock);
        session->instance = NULL;
        const int stop = session->stop_requested;
        const int reconnect = session->reconnect_requested;
        pthread_mutex_unlock(&session->lock);
        orbit_destroy_instance(instance);
        if (stop) break;
        if (reconnect) { reconnecting = 1; continue; }
        orbit_emit_event(session, connected ? ORBIT_RDP_EVENT_DISCONNECTED : ORBIT_RDP_EVENT_FAILED, error);
        break;
    }
    pthread_mutex_lock(&session->lock);
    session->worker_started = 0;
    pthread_mutex_unlock(&session->lock);
    return NULL;
}
#endif

orbit_rdp_result orbit_rdp_session_create(const orbit_rdp_session_options* options, orbit_rdp_session** output) {
    if (!options || !output || options->abi_version != ORBIT_RDP_ABI_VERSION || !options->host ||
        options->host[0] == '\0' || options->port == 0 || options->desktop_width < 320 ||
        options->desktop_height < 200 || options->desktop_width > 16384 || options->desktop_height > 16384)
        return ORBIT_RDP_INVALID_ARGUMENT;
    *output = NULL;
    orbit_rdp_session* session = calloc(1, sizeof(*session));
    if (!session) return ORBIT_RDP_ENGINE_UNAVAILABLE;
    session->host = orbit_duplicate_string(options->host);
    session->username = orbit_duplicate_string(options->username);
    session->password = orbit_duplicate_string(options->password);
    session->domain = orbit_duplicate_string(options->domain);
    if (!session->host || !session->username || !session->password || !session->domain) {
        orbit_rdp_session_free(session); return ORBIT_RDP_ENGINE_UNAVAILABLE;
    }
    session->options = *options;
    session->options.host = session->host;
    session->options.username = session->username;
    session->options.password = session->password;
    session->options.domain = session->domain;
#if ORBIT_RDP_HAS_FREERDP
    if (pthread_mutex_init(&session->lock, NULL) != 0) { orbit_rdp_session_free(session); return ORBIT_RDP_THREAD_FAILURE; }
    if (pthread_cond_init(&session->certificate_condition, NULL) != 0) {
        pthread_mutex_destroy(&session->lock); orbit_rdp_session_free(session); return ORBIT_RDP_THREAD_FAILURE;
    }
    session->synchronization_ready = 1;
    session->certificate_decision = -1;
    session->pending_width = options->desktop_width;
    session->pending_height = options->desktop_height;
    session->wake_event = CreateEvent(NULL, TRUE, FALSE, NULL);
    if (!session->wake_event) { orbit_rdp_session_free(session); return ORBIT_RDP_THREAD_FAILURE; }
#endif
    *output = session;
    return ORBIT_RDP_OK;
}

orbit_rdp_result orbit_rdp_session_set_callbacks(orbit_rdp_session* session,
    orbit_rdp_event_callback event_callback, orbit_rdp_certificate_callback certificate_callback,
    orbit_rdp_frame_callback frame_callback, void* user_data) {
    if (!session) return ORBIT_RDP_INVALID_ARGUMENT;
    session->event_callback = event_callback;
    session->certificate_callback = certificate_callback;
    session->frame_callback = frame_callback;
    session->user_data = user_data;
    return ORBIT_RDP_OK;
}

orbit_rdp_result orbit_rdp_session_start(orbit_rdp_session* session) {
    if (!session) return ORBIT_RDP_INVALID_ARGUMENT;
#if ORBIT_RDP_HAS_FREERDP
    const orbit_rdp_result runtime = orbit_rdp_runtime_prepare();
    if (runtime != ORBIT_RDP_OK) return runtime;
    pthread_mutex_lock(&session->lock);
    if (session->worker_started) { pthread_mutex_unlock(&session->lock); return ORBIT_RDP_INVALID_STATE; }
    const int join_previous = session->worker_joinable;
    pthread_mutex_unlock(&session->lock);
    if (join_previous && !pthread_equal(pthread_self(), session->worker)) {
        (void)pthread_join(session->worker, NULL);
        pthread_mutex_lock(&session->lock);
        session->worker_joinable = 0;
        pthread_mutex_unlock(&session->lock);
    }
    pthread_mutex_lock(&session->lock);
    session->stop_requested = 0;
    session->reconnect_requested = 0;
    session->worker_started = 1;
    pthread_mutex_unlock(&session->lock);
    if (pthread_create(&session->worker, NULL, orbit_rdp_worker, session) != 0) {
        pthread_mutex_lock(&session->lock); session->worker_started = 0; pthread_mutex_unlock(&session->lock);
        return ORBIT_RDP_THREAD_FAILURE;
    }
    pthread_mutex_lock(&session->lock);
    session->worker_joinable = 1;
    pthread_mutex_unlock(&session->lock);
    return ORBIT_RDP_OK;
#else
    return ORBIT_RDP_ENGINE_UNAVAILABLE;
#endif
}

orbit_rdp_result orbit_rdp_session_stop(orbit_rdp_session* session) {
    if (!session) return ORBIT_RDP_INVALID_ARGUMENT;
#if ORBIT_RDP_HAS_FREERDP
    if (!session->synchronization_ready) return ORBIT_RDP_OK;
    pthread_mutex_lock(&session->lock);
    const int join_worker = session->worker_joinable;
    session->stop_requested = 1;
    session->certificate_decision = ORBIT_RDP_CERTIFICATE_REJECT;
    pthread_cond_broadcast(&session->certificate_condition);
    pthread_mutex_unlock(&session->lock);
    if (session->wake_event) SetEvent(session->wake_event);
    orbit_abort_active_instance(session);
    if (join_worker && !pthread_equal(pthread_self(), session->worker)) {
        (void)pthread_join(session->worker, NULL);
        pthread_mutex_lock(&session->lock);
        session->worker_joinable = 0;
        pthread_mutex_unlock(&session->lock);
    }
#endif
    return ORBIT_RDP_OK;
}

orbit_rdp_result orbit_rdp_session_reconnect(orbit_rdp_session* session) {
    if (!session) return ORBIT_RDP_INVALID_ARGUMENT;
#if ORBIT_RDP_HAS_FREERDP
    pthread_mutex_lock(&session->lock);
    if (!session->worker_started) { pthread_mutex_unlock(&session->lock); return orbit_rdp_session_start(session); }
    session->reconnect_requested = 1;
    session->certificate_decision = ORBIT_RDP_CERTIFICATE_REJECT;
    pthread_cond_broadcast(&session->certificate_condition);
    pthread_mutex_unlock(&session->lock);
    if (session->wake_event) SetEvent(session->wake_event);
    orbit_abort_active_instance(session);
    return ORBIT_RDP_OK;
#else
    return ORBIT_RDP_ENGINE_UNAVAILABLE;
#endif
}

orbit_rdp_result orbit_rdp_session_decide_certificate(orbit_rdp_session* session, orbit_rdp_certificate_decision decision) {
    if (!session || (decision != ORBIT_RDP_CERTIFICATE_REJECT && decision != ORBIT_RDP_CERTIFICATE_ACCEPT_ONCE))
        return ORBIT_RDP_INVALID_ARGUMENT;
#if ORBIT_RDP_HAS_FREERDP
    pthread_mutex_lock(&session->lock);
    if (!session->certificate_waiting) { pthread_mutex_unlock(&session->lock); return ORBIT_RDP_INVALID_STATE; }
    session->certificate_decision = decision;
    pthread_cond_broadcast(&session->certificate_condition);
    pthread_mutex_unlock(&session->lock);
    return ORBIT_RDP_OK;
#else
    return ORBIT_RDP_ENGINE_UNAVAILABLE;
#endif
}

orbit_rdp_result orbit_rdp_session_resize(orbit_rdp_session* session, uint32_t width, uint32_t height) {
    if (!session || width < 320 || height < 200 || width > 16384 || height > 16384) return ORBIT_RDP_INVALID_ARGUMENT;
#if ORBIT_RDP_HAS_FREERDP
    pthread_mutex_lock(&session->lock);
    session->options.desktop_width = width;
    session->options.desktop_height = height;
    session->pending_width = width;
    session->pending_height = height;
    session->resize_pending = 1;
    pthread_mutex_unlock(&session->lock);
    if (session->wake_event) SetEvent(session->wake_event);
    return ORBIT_RDP_OK;
#else
    return ORBIT_RDP_ENGINE_UNAVAILABLE;
#endif
}

orbit_rdp_result orbit_rdp_session_send_unicode(orbit_rdp_session* session, const uint16_t* utf16, size_t count) {
    if (!session || (!utf16 && count > 0)) return ORBIT_RDP_INVALID_ARGUMENT;
#if ORBIT_RDP_HAS_FREERDP
    pthread_mutex_lock(&session->lock);
    rdpInput* input = session->instance && session->instance->context ? session->instance->context->input : NULL;
    BOOL ok = input != NULL;
    for (size_t index = 0; ok && index < count; index++)
        ok = freerdp_input_send_unicode_keyboard_event(input, KBD_FLAGS_DOWN, utf16[index]) &&
             freerdp_input_send_unicode_keyboard_event(input, KBD_FLAGS_RELEASE, utf16[index]);
    pthread_mutex_unlock(&session->lock);
    return ok ? ORBIT_RDP_OK : ORBIT_RDP_INVALID_STATE;
#else
    return ORBIT_RDP_ENGINE_UNAVAILABLE;
#endif
}

orbit_rdp_result orbit_rdp_session_send_scancode(orbit_rdp_session* session, uint32_t scancode, uint8_t pressed) {
    if (!session || scancode == 0) return ORBIT_RDP_INVALID_ARGUMENT;
#if ORBIT_RDP_HAS_FREERDP
    pthread_mutex_lock(&session->lock);
    rdpInput* input = session->instance && session->instance->context ? session->instance->context->input : NULL;
    const BOOL ok = input && freerdp_input_send_keyboard_event_ex(input, pressed != 0, FALSE, scancode);
    pthread_mutex_unlock(&session->lock);
    return ok ? ORBIT_RDP_OK : ORBIT_RDP_INVALID_STATE;
#else
    return ORBIT_RDP_ENGINE_UNAVAILABLE;
#endif
}

orbit_rdp_result orbit_rdp_session_send_pointer(orbit_rdp_session* session, orbit_rdp_pointer_action action,
                                                uint16_t x, uint16_t y, int16_t wheel_delta) {
    if (!session) return ORBIT_RDP_INVALID_ARGUMENT;
#if ORBIT_RDP_HAS_FREERDP
    UINT16 flags = PTR_FLAGS_MOVE;
    switch (action) {
        case ORBIT_RDP_POINTER_MOVE: break;
        case ORBIT_RDP_POINTER_LEFT_DOWN: flags = PTR_FLAGS_BUTTON1 | PTR_FLAGS_DOWN; break;
        case ORBIT_RDP_POINTER_LEFT_UP: flags = PTR_FLAGS_BUTTON1; break;
        case ORBIT_RDP_POINTER_RIGHT_DOWN: flags = PTR_FLAGS_BUTTON2 | PTR_FLAGS_DOWN; break;
        case ORBIT_RDP_POINTER_RIGHT_UP: flags = PTR_FLAGS_BUTTON2; break;
        case ORBIT_RDP_POINTER_MIDDLE_DOWN: flags = PTR_FLAGS_BUTTON3 | PTR_FLAGS_DOWN; break;
        case ORBIT_RDP_POINTER_MIDDLE_UP: flags = PTR_FLAGS_BUTTON3; break;
        case ORBIT_RDP_POINTER_WHEEL_VERTICAL:
            flags = PTR_FLAGS_WHEEL | (wheel_delta < 0 ? PTR_FLAGS_WHEEL_NEGATIVE : 0) | ((UINT16)abs(wheel_delta) & WheelRotationMask); break;
        case ORBIT_RDP_POINTER_WHEEL_HORIZONTAL:
            flags = PTR_FLAGS_HWHEEL | (wheel_delta < 0 ? PTR_FLAGS_WHEEL_NEGATIVE : 0) | ((UINT16)abs(wheel_delta) & WheelRotationMask); break;
        default: return ORBIT_RDP_INVALID_ARGUMENT;
    }
    pthread_mutex_lock(&session->lock);
    rdpInput* input = session->instance && session->instance->context ? session->instance->context->input : NULL;
    const BOOL ok = input && freerdp_input_send_mouse_event(input, flags, x, y);
    pthread_mutex_unlock(&session->lock);
    return ok ? ORBIT_RDP_OK : ORBIT_RDP_INVALID_STATE;
#else
    (void)action; (void)x; (void)y; (void)wheel_delta;
    return ORBIT_RDP_ENGINE_UNAVAILABLE;
#endif
}

void orbit_rdp_session_free(orbit_rdp_session* session) {
    if (!session) return;
    (void)orbit_rdp_session_stop(session);
#if ORBIT_RDP_HAS_FREERDP
    if (session->synchronization_ready) {
        if (session->wake_event) CloseHandle(session->wake_event);
        pthread_cond_destroy(&session->certificate_condition);
        pthread_mutex_destroy(&session->lock);
    }
#endif
    free(session->host);
    free(session->username);
    orbit_secure_free(&session->password);
    orbit_secure_free(&session->domain);
    free(session);
}
