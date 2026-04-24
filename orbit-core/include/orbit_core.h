#ifndef ORBIT_CORE_H
#define ORBIT_CORE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// 返回值格式：
// - 成功: "OK:<payload>"
// - 失败: "ERR:<message>"
// 调用方使用 orbit_free_string 释放返回字符串。
char *orbit_encrypt_config(const char *master_password, const unsigned char *plaintext_ptr, size_t plaintext_len);
char *orbit_decrypt_config(const char *master_password, const char *encrypted_base64);
char *orbit_test_ssh_connection(const char *ip, const char *username, const char *password);
void orbit_free_string(char *s);

#ifdef __cplusplus
}
#endif

#endif // ORBIT_CORE_H
