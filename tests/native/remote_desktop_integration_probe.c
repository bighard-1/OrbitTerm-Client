#include "orbit_remote_desktop.h"

#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

typedef struct probe_state {
    pthread_mutex_t lock;
    unsigned connected;
    unsigned disconnected;
    int failed;
    unsigned frames;
    uint32_t last_width;
    uint32_t last_height;
} probe_state;

static void on_event(orbit_rdp_session* session, orbit_rdp_event_kind event,
                     uint32_t native_error, void* user_data) {
    (void)session;
    probe_state* state = user_data;
    pthread_mutex_lock(&state->lock);
    if (event == ORBIT_RDP_EVENT_CONNECTED) state->connected++;
    if (event == ORBIT_RDP_EVENT_DISCONNECTED) state->disconnected++;
    if (event == ORBIT_RDP_EVENT_FAILED) state->failed = 1;
    pthread_mutex_unlock(&state->lock);
    fprintf(stderr, "rdp event=%u native_error=%u\n", (unsigned)event, native_error);
}

static void on_certificate(orbit_rdp_session* session,
                           const orbit_rdp_certificate_challenge* challenge,
                           void* user_data) {
    (void)user_data;
    fprintf(stderr, "certificate host=%s port=%u changed=%u fingerprint=%s\n",
            challenge->host ? challenge->host : "",
            (unsigned)challenge->port,
            (unsigned)challenge->changed,
            challenge->fingerprint ? challenge->fingerprint : "");
    (void)orbit_rdp_session_decide_certificate(session, ORBIT_RDP_CERTIFICATE_ACCEPT_ONCE);
}

static void on_frame(orbit_rdp_session* session, const uint8_t* bytes,
                     uint32_t width, uint32_t height, uint32_t stride,
                     void* user_data) {
    (void)session;
    if (!bytes || width == 0 || height == 0 || stride < width * 4) return;
    probe_state* state = user_data;
    pthread_mutex_lock(&state->lock);
    state->frames++;
    state->last_width = width;
    state->last_height = height;
    pthread_mutex_unlock(&state->lock);
}

static int wait_for_state(probe_state* state, unsigned connected, unsigned minimum_frames,
                          uint32_t width, uint32_t height, unsigned attempts) {
    const struct timespec delay = { .tv_sec = 0, .tv_nsec = 100000000 };
    for (unsigned attempt = 0; attempt < attempts; attempt++) {
        nanosleep(&delay, NULL);
        pthread_mutex_lock(&state->lock);
        const int failed = state->failed;
        const int ready = state->connected >= connected && state->frames >= minimum_frames &&
                          (width == 0 || (state->last_width == width && state->last_height == height));
        pthread_mutex_unlock(&state->lock);
        if (failed) return 0;
        if (ready) return 1;
    }
    return 0;
}

int main(int argc, char** argv) {
    if (argc != 4) {
        fprintf(stderr, "usage: %s host port username\n", argv[0]);
        return 2;
    }
    const char* password = getenv("ORBIT_RDP_TEST_PASSWORD");
    if (!password || password[0] == '\0') {
        fputs("ORBIT_RDP_TEST_PASSWORD is required and is never printed\n", stderr);
        return 2;
    }
    const char* require_nla_value = getenv("ORBIT_RDP_TEST_REQUIRE_NLA");
    const int require_nla = !require_nla_value || strcmp(require_nla_value, "0") != 0;
    const int skip_resize = getenv("ORBIT_RDP_TEST_SKIP_RESIZE") != NULL;
    const int skip_reconnect = getenv("ORBIT_RDP_TEST_SKIP_RECONNECT") != NULL;
    const char* stability_value = getenv("ORBIT_RDP_TEST_STABILITY_SECONDS");
    const unsigned stability_seconds = stability_value ? (unsigned)strtoul(stability_value, NULL, 10) : 0;

    probe_state state = { .lock = PTHREAD_MUTEX_INITIALIZER };
    orbit_rdp_session_options options = {
        .abi_version = ORBIT_RDP_ABI_VERSION,
        .host = argv[1],
        .port = (uint16_t)strtoul(argv[2], NULL, 10),
        .desktop_width = 1024,
        .desktop_height = 640,
        .require_nla = require_nla,
        .username = argv[3],
        .password = password,
        .domain = ""
    };
    orbit_rdp_session* session = NULL;
    if (orbit_rdp_session_create(&options, &session) != ORBIT_RDP_OK || !session) return 3;
    if (orbit_rdp_session_set_callbacks(session, on_event, on_certificate, on_frame, &state) != ORBIT_RDP_OK ||
        orbit_rdp_session_start(session) != ORBIT_RDP_OK) {
        orbit_rdp_session_free(session);
        return 3;
    }

    int success = wait_for_state(&state, 1, 1, 0, 0, 200);
    if (success && stability_seconds > 0) {
        const struct timespec stability_delay = { .tv_sec = stability_seconds, .tv_nsec = 0 };
        nanosleep(&stability_delay, NULL);
        pthread_mutex_lock(&state.lock);
        success = !state.failed && state.disconnected == 0;
        pthread_mutex_unlock(&state.lock);
    }
    unsigned initial_frames = 0;
    if (success) {
        pthread_mutex_lock(&state.lock);
        initial_frames = state.frames;
        pthread_mutex_unlock(&state.lock);

        /* Benign input proves the live input channel without modifying remote data. */
        success = orbit_rdp_session_send_pointer(session, ORBIT_RDP_POINTER_MOVE, 32, 32, 0) == ORBIT_RDP_OK &&
                  orbit_rdp_session_send_scancode(session, 0x2A, 1) == ORBIT_RDP_OK &&
                  orbit_rdp_session_send_scancode(session, 0x2A, 0) == ORBIT_RDP_OK;
    }
    if (success && !skip_resize) {
        success = orbit_rdp_session_resize(session, 1184, 704) == ORBIT_RDP_OK &&
                  wait_for_state(&state, 1, initial_frames + 1, 1184, 704, 150);
    }
    if (success && !skip_reconnect) {
        pthread_mutex_lock(&state.lock);
        const unsigned frames_before_reconnect = state.frames;
        pthread_mutex_unlock(&state.lock);
        success = orbit_rdp_session_reconnect(session) == ORBIT_RDP_OK &&
                  wait_for_state(&state, 2, frames_before_reconnect + 1, 0, 0, 200);
    }

    (void)orbit_rdp_session_stop(session);
    orbit_rdp_session_free(session);
    pthread_mutex_lock(&state.lock);
    fprintf(stderr, "integration connected=%u disconnected=%u frames=%u size=%ux%u failed=%d success=%d\n",
            state.connected, state.disconnected, state.frames, state.last_width, state.last_height,
            state.failed, success);
    pthread_mutex_unlock(&state.lock);
    pthread_mutex_destroy(&state.lock);
    return success ? 0 : 1;
}
