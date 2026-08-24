#include "orbit_remote_desktop.h"

#include <stdio.h>
#include <string.h>

static int require(int condition, const char* message) {
    if (condition) return 0;
    fprintf(stderr, "FAILED: %s\n", message);
    return 1;
}

int main(void) {
    int failures = 0;
    char version[64] = { 0 };
    failures += require(orbit_rdp_abi_version() == 1u, "ABI version must remain pinned");
    failures += require(
        strcmp(orbit_rdp_expected_freerdp_version(), "3.26.0") == 0,
        "FreeRDP version must remain pinned"
    );
    failures += require(
        orbit_rdp_runtime_probe(version, sizeof(version)) == ORBIT_RDP_RUNTIME_AVAILABLE,
        "audited runtime should be discoverable"
    );
    failures += require(strcmp(version, "3.26.0") == 0, "runtime version must match manifest");

    orbit_rdp_session* session = NULL;
    orbit_rdp_session_options invalid = { 0 };
    failures += require(
        orbit_rdp_session_create(&invalid, &session) == ORBIT_RDP_INVALID_ARGUMENT,
        "invalid session options must fail closed"
    );

    orbit_rdp_session_options valid = {
        .abi_version = ORBIT_RDP_ABI_VERSION,
        .host = "rdp.example.test",
        .port = 3389,
        .desktop_width = 1440,
        .desktop_height = 900,
        .require_nla = 1
    };
    failures += require(
        orbit_rdp_session_create(&valid, &session) == ORBIT_RDP_OK && session != NULL,
        "valid session options should create an isolated handle"
    );
    failures += require(
        orbit_rdp_session_start(session) == ORBIT_RDP_NOT_IMPLEMENTED,
        "unfinished transport must never report a successful connection"
    );
    failures += require(orbit_rdp_session_stop(session) == ORBIT_RDP_OK, "stop must be idempotent");
    orbit_rdp_session_free(session);

    if (failures == 0) puts("remote_desktop_runtime_test: PASS");
    return failures == 0 ? 0 : 1;
}
