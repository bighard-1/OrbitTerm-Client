#include "../OrbitTerm/CBridge/orbit_core.h"

#define ORBIT_ASSERT_DECLARED(symbol) \
    _Static_assert(sizeof(&(symbol)) == sizeof(void (*)(void)), #symbol " must be declared")

ORBIT_ASSERT_DECLARED(orbit_ssh_connect);
ORBIT_ASSERT_DECLARED(orbit_sftp_connect);
ORBIT_ASSERT_DECLARED(orbit_ssh_connect_checked_v1);
ORBIT_ASSERT_DECLARED(orbit_sftp_open_checked_v1);
ORBIT_ASSERT_DECLARED(orbit_terminal_open_checked_v1);
ORBIT_ASSERT_DECLARED(orbit_monitor_snapshot_checked_v1);
ORBIT_ASSERT_DECLARED(orbit_docker_list_checked_v1);
ORBIT_ASSERT_DECLARED(orbit_hostkey_challenge_accept_and_persist_v1);
ORBIT_ASSERT_DECLARED(orbit_derive_config_root_key_v2);
ORBIT_ASSERT_DECLARED(orbit_encrypt_config_v2);
ORBIT_ASSERT_DECLARED(orbit_decrypt_config_v2);

void orbitterm_checked_ffi_header_compile_check(void) {}
