#!/usr/bin/env bash

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

matrix="$ORBIT_ROOT/docs/ANDROID_IOS_BEHAVIOR_ALIGNMENT_MATRIX.md"
audit="$ORBIT_ROOT/docs/MOBILE_IOS_ANDROID_FULL_PARITY_AUDIT.md"
[[ -f "$matrix" ]] || fail "Android/iOS behavior alignment matrix is missing"
[[ -f "$audit" ]] || fail "Android/iOS full parity audit is missing"

section "Android/iOS behavior alignment matrix"
rg -q '^# Android / iOS 行为对齐矩阵$' "$matrix" || fail "alignment matrix has an unexpected title"

required_rows=(
  'Telnet'
  '多选文件与目录后一键批量下载/系统分享'
  'TalkBack'
  'Android 前台服务与常驻通知'
  '剪贴板按内容类型分级'
  '`ssh://` / `orbitterm://connect`'
  '锁屏公开版本'
  '高压力与资源边界'
)
for row in "${required_rows[@]}"; do
  rg -Fq "$row" "$matrix" || fail "alignment matrix is missing required scope: $row"
done

while IFS= read -r row; do
  [[ "$row" == *' 域 | 操作结果 / 安全语义 '* ]] && continue
  [[ "$row" == *' --- '* ]] && continue
  IFS='|' read -r _ domain behavior ios android status owner acceptance _ <<< "$row"
  [[ -n "${domain// }" && -n "${behavior// }" && -n "${ios// }" && -n "${android// }" ]] || fail "alignment matrix has an incomplete row"
  case "${status// }" in
    已对齐|有意差异|待完成) ;;
    *) fail "alignment matrix row has an invalid status: $status" ;;
  esac
  [[ -n "${owner// }" && -n "${acceptance// }" ]] || fail "alignment matrix row is missing owner or acceptance criteria"
done < <(rg '^\| ' "$matrix")

pass "Android/iOS behavior alignment matrix"

section "Android/iOS source parity contracts"
ios_assets="$ORBIT_ROOT/OrbitTerm/Features/Home/ServerListView.swift"
android_assets="$ORBIT_ROOT/clients/android/OrbitTermAndroid/feature/src/main/java/com/orbitterm/android/feature/assets/AssetsRoute.kt"
ios_session="$ORBIT_ROOT/OrbitTerm/App/MobileSessionComponents.swift"
ios_monitor="$ORBIT_ROOT/OrbitTerm/App/MobileSessionComponents.swift"
android_session="$ORBIT_ROOT/clients/android/OrbitTermAndroid/feature/src/main/java/com/orbitterm/android/feature/terminal/TerminalSessionsRoute.kt"
android_monitor="$ORBIT_ROOT/clients/android/OrbitTermAndroid/feature/src/main/java/com/orbitterm/android/feature/monitor/MonitorPanel.kt"
ios_connection_state="$ORBIT_ROOT/OrbitTerm/Core/Appearance/ConnectionPresentation.swift"
ios_sync_state="$ORBIT_ROOT/OrbitTerm/Core/Appearance/OperationRecoveryPresentation.swift"
ios_root_content="$ORBIT_ROOT/OrbitTerm/App/ContentView.swift"
android_connection_state="$ORBIT_ROOT/clients/android/OrbitTermAndroid/feature/src/main/java/com/orbitterm/android/feature/assets/ConnectionPhasePresentation.kt"
android_terminal_state="$ORBIT_ROOT/clients/android/OrbitTermAndroid/feature/src/main/java/com/orbitterm/android/feature/terminal/TerminalSessionStatus.kt"
android_sync_state="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/ui/SyncStatusPresentation.kt"
android_recently_deleted="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/app/RecentlyDeletedViewModel.kt"
android_sync_ui_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/androidTest/java/com/orbitterm/android/ui/SyncRecoveryComposeTest.kt"
android_security_state="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/app/SecurityOperationPresentation.kt"
android_auth_state="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/app/AuthViewModel.kt"
android_master_state="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/app/MasterPasswordViewModel.kt"
android_security_ui_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/androidTest/java/com/orbitterm/android/ui/SecurityOperationComposeTest.kt"
android_root_ui_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/androidTest/java/com/orbitterm/android/ui/MobileRootStateComposeTest.kt"
android_lock_policy="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/app/AppLockLifecyclePolicy.kt"
android_lock_policy_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/test/java/com/orbitterm/android/app/AppLockLifecyclePolicyTest.kt"
ios_auth="$ORBIT_ROOT/OrbitTerm/Features/Auth/AuthView.swift"
ios_biometric="$ORBIT_ROOT/OrbitTerm/Core/BiometricAuthService.swift"
ios_master_gate="$ORBIT_ROOT/OrbitTerm/Features/Security/MasterPasswordGateView.swift"
ios_app_session="$ORBIT_ROOT/OrbitTerm/Core/AppSession.swift"
ios_lifecycle_policy="$ORBIT_ROOT/OrbitTerm/Core/ApplicationOperationLifecyclePolicy.swift"
android_auth="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/ui/LoginScreen.kt"
android_operational_state="$ORBIT_ROOT/clients/android/OrbitTermAndroid/feature/src/main/java/com/orbitterm/android/feature/presentation/OperationalContentPresentation.kt"
android_operational_ui_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/feature/src/androidTest/java/com/orbitterm/android/feature/presentation/OperationalStateComposeTest.kt"
ios_operational_ui_test="$ORBIT_ROOT/OrbitTermiOSUITests/OrbitTermiOSUITests.swift"
ios_clipboard="$ORBIT_ROOT/OrbitTerm/Core/SecureClipboard.swift"
ios_sensitive_screen="$ORBIT_ROOT/OrbitTerm/Core/SensitiveScreenProtection.swift"
ios_deep_link="$ORBIT_ROOT/OrbitTerm/Core/DeepLinkManager.swift"
ios_clipboard_test="$ORBIT_ROOT/OrbitTermCheckedFFITests/ClipboardSecurityPolicyTests.swift"
ios_input_test="$ORBIT_ROOT/OrbitTermCheckedFFITests/AppleInputBoundaryTests.swift"
android_clipboard="$ORBIT_ROOT/clients/android/OrbitTermAndroid/data/src/main/java/com/orbitterm/android/security/SensitiveClipboard.kt"
android_clipboard_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/data/src/test/java/com/orbitterm/android/security/ClipboardContentKindPolicyTest.kt"
android_main_activity="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/MainActivity.kt"
android_notification="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/app/ActiveSessionService.kt"
android_notification_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/test/java/com/orbitterm/android/app/ActiveSessionNotificationPresentationTest.kt"
android_deep_link="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/app/DeepLinkCoordinator.kt"
android_deep_link_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/test/java/com/orbitterm/android/app/ServerDeepLinkParserTest.kt"
android_assets_view_model="$ORBIT_ROOT/clients/android/OrbitTermAndroid/feature/src/main/java/com/orbitterm/android/feature/assets/AssetsViewModel.kt"
ios_resource_budget="$ORBIT_ROOT/OrbitTerm/Core/OperationResourceBudget.swift"
ios_sync_queue="$ORBIT_ROOT/OrbitTerm/Core/SyncQueue.swift"
ios_resource_test="$ORBIT_ROOT/OrbitTermCheckedFFITests/OperationResourceBudgetStressTests.swift"
android_resource_budget="$ORBIT_ROOT/clients/android/OrbitTermAndroid/domain/src/main/java/com/orbitterm/android/domain/performance/RuntimeResourceBudget.kt"
android_sync_work="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/app/SyncWork.kt"
android_outbox_dao="$ORBIT_ROOT/clients/android/OrbitTermAndroid/data/src/main/java/com/orbitterm/android/data/local/AssetSyncOutboxDao.kt"
android_outbox_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/androidTest/java/com/orbitterm/android/data/local/AssetSyncOutboxBatchTest.kt"
ios_request_identity="$ORBIT_ROOT/OrbitTerm/Core/SyncRequestIdentity.swift"
ios_request_identity_test="$ORBIT_ROOT/OrbitTermCheckedFFITests/SyncRequestIdentityTests.swift"
android_api="$ORBIT_ROOT/clients/android/OrbitTermAndroid/data/src/main/java/com/orbitterm/android/sync/OrbitApi.kt"
android_migrations="$ORBIT_ROOT/clients/android/OrbitTermAndroid/data/src/main/java/com/orbitterm/android/data/local/OrbitTermMigrations.kt"
android_migration_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/androidTest/java/com/orbitterm/android/data/local/OrbitTermDatabaseMigrationTest.kt"
android_conflict_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/test/java/com/orbitterm/android/sync/AssetSyncConflictPolicyTest.kt"
ios_diagnostics="$ORBIT_ROOT/OrbitTerm/Core/DiagnosticsPrivacy.swift"
ios_diagnostics_test="$ORBIT_ROOT/OrbitTermCheckedFFITests/DiagnosticsPrivacyTests.swift"
android_sync_diagnostics="$ORBIT_ROOT/clients/android/OrbitTermAndroid/domain/src/main/java/com/orbitterm/android/domain/sync/SyncDiagnostics.kt"
android_sync_diagnostics_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/domain/src/test/java/com/orbitterm/android/domain/sync/SyncDiagnosticsTest.kt"
ios_sync_recovery_policy="$ORBIT_ROOT/OrbitTerm/Core/SyncQueueRecoveryPolicy.swift"
ios_sync_recovery_test="$ORBIT_ROOT/OrbitTermCheckedFFITests/SyncQueueRecoveryPolicyTests.swift"
android_sync_recovery_policy="$ORBIT_ROOT/clients/android/OrbitTermAndroid/domain/src/main/java/com/orbitterm/android/domain/sync/SyncDeliveryPolicy.kt"
android_sync_recovery_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/domain/src/test/java/com/orbitterm/android/domain/sync/SyncDeliveryPolicyTest.kt"
android_main_screen="$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/ui/MainScreen.kt"
ios_settings="$ORBIT_ROOT/OrbitTerm/Features/Home/SettingsView.swift"
ios_http_policy="$ORBIT_ROOT/OrbitTerm/Core/SyncHTTPResponsePolicy.swift"
ios_http_policy_test="$ORBIT_ROOT/OrbitTermCheckedFFITests/SyncHTTPResponsePolicyTests.swift"
ios_sync_conflict="$ORBIT_ROOT/OrbitTerm/Core/SyncService+Conflict.swift"
android_http_policy="$ORBIT_ROOT/clients/android/OrbitTermAndroid/domain/src/main/java/com/orbitterm/android/domain/sync/SyncHttpResponsePolicy.kt"
android_http_policy_test="$ORBIT_ROOT/clients/android/OrbitTermAndroid/domain/src/test/java/com/orbitterm/android/domain/sync/SyncHttpResponsePolicyTest.kt"

! rg -q '再次点击以连接|点击两次连接|armedConnection' "$ios_assets" "$android_assets" || fail "mobile asset cards reintroduced two-step connection arming"
for module in '终端' '快捷操作' '监控' 'Snippets'; do
  rg -Fq "$module" "$ios_session" || fail "iOS session module label is missing: $module"
  rg -Fq "$module" "$android_session" || fail "Android session module label is missing: $module"
done
for metric in 'CPU' '内存' '磁盘' 'TCP 延迟' '下载' '上传'; do
  rg -Fq "$metric" "$ios_monitor" || fail "iOS mobile monitor metric is missing: $metric"
  rg -Fq "$metric" "$android_monitor" || fail "Android mobile monitor metric is missing: $metric"
done
rg -Fq 'TelnetTerminalConnection.kt' "$matrix" || fail "matrix no longer reflects Android Telnet support"

for state in '连接中' '重连中' '已连接' '已断开' '连接失败'; do
  rg -Fq "$state" "$ios_connection_state" || fail "iOS connection vocabulary is missing: $state"
  rg -Fq "$state" "$android_connection_state" "$android_terminal_state" || fail "Android connection vocabulary is missing: $state"
done
for state in '等待网络' '等待解锁' '同步中' '同步失败'; do
  rg -Fq "$state" "$ios_sync_state" || fail "iOS sync vocabulary is missing: $state"
  rg -Fq "$state" "$android_sync_state" || fail "Android sync vocabulary is missing: $state"
done
for state in '检测到同步冲突' '保留本地修改' '保留云端修改' '无法加载最近删除' '操作未完成，当前删除记录仍可查看。' '已加入后台队列，联网后自动完成。'; do
  rg -Fq "$state" "$ios_sync_state" || fail "iOS sync/recovery vocabulary is missing: $state"
  rg -Fq "$state" "$android_sync_state" "$android_recently_deleted" || fail "Android sync/recovery vocabulary is missing: $state"
done
for state in '已更新登录密码；其他设备需要重新登录。' '已完成主密码轮换；其他设备需要重新登录并使用新主密码解锁。' '退出登录？' '将断开当前所有会话并清除当前登录状态；本机加密数据仍按账户隔离保留。'; do
  rg -Fq "$state" "$ios_sync_state" || fail "iOS account-security vocabulary is missing: $state"
  rg -Fq "$state" "$android_security_state" || fail "Android account-security vocabulary is missing: $state"
done
for state in '已启用生物识别解锁。' '已关闭生物识别解锁。' '已通过生物识别解锁。' '生物识别密钥已失效，请使用主密码解锁后重新启用。' '生物识别暂时锁定，请使用主密码解锁。' '此设备未配置可用的强生物识别方式。' '生物识别未通过，请重试或使用主密码解锁。' '正在验证…'; do
  rg -Fq "$state" "$ios_sync_state" || fail "iOS biometric vocabulary is missing: $state"
  rg -Fq "$state" "$android_security_state" || fail "Android biometric vocabulary is missing: $state"
done
for label in '已阅读并同意' '查看法律条款' '查看使用条款、免责声明与隐私说明'; do
  rg -Fq "$label" "$ios_auth" || fail "iOS compact legal-consent vocabulary is missing: $label"
  rg -Fq "$label" "$android_auth" || fail "Android compact legal-consent vocabulary is missing: $label"
done
for state in '正在加载监控' '暂无监控数据' '采样已暂停' '监控读取失败' '监控中' '正在加载目录' '此目录为空' 'SFTP 操作失败' '目录已就绪' '正在加载容器' '暂无容器' 'Docker 操作失败' '容器已就绪'; do
  rg -Fq "$state" "$ios_sync_state" || fail "iOS operational module vocabulary is missing: $state"
  rg -Fq "$state" "$android_operational_state" || fail "Android operational module vocabulary is missing: $state"
done
for action in '刷新中…' '重试' '暂停采样' '恢复采样' '操作未完成，正在显示上次成功的监控数据。' '操作未完成，当前目录列表仍可查看。' '操作未完成，正在显示上次成功的容器列表。'; do
  rg -Fq "$action" "$ios_sync_state" || fail "iOS operational action vocabulary is missing: $action"
  rg -Fq "$action" "$android_operational_state" || fail "Android operational action vocabulary is missing: $action"
done
rg -Fq 'successVisibleNanoseconds: UInt64 = 4_000_000_000' "$ios_sync_state" || fail "iOS operational success lifetime changed without parity review"
rg -Fq 'SUCCESS_VISIBLE_MILLIS = 4_000L' "$android_operational_state" || fail "Android operational success lifetime changed without parity review"
rg -Fq 'testOperationalFailuresExposeRetryRetainedContentAndTransientSuccessLifetime' "$ios_operational_ui_test" || fail "iOS operational UI regression is missing"
rg -Fq 'busyRefreshIsDisabledAndSuccessExpiresWhileFailurePersists' "$android_operational_ui_test" || fail "Android operational UI regression is missing"
rg -Fq 'testSyncRecoveryStatesExposeParityActionsAndTransientQueueFeedback' "$ios_operational_ui_test" || fail "iOS sync/recovery UI regression is missing"
rg -Fq 'successFeedbackExpiresAfterFourSecondsWhileFailurePersists' "$android_sync_ui_test" || fail "Android sync/recovery UI regression is missing"
rg -Fq 'passwordChangeGeneration' "$android_auth_state" || fail "Android login-password late callbacks are not generation fenced"
rg -Fq 'rotationGeneration' "$android_master_state" || fail "Android master-password late callbacks are not generation fenced"
rg -Fq 'PageOperationTimeout.perform(timeout: PageOperationTimeout.authentication)' "$ORBIT_ROOT/OrbitTerm/Features/Home/AccountSecurityView.swift" || fail "iOS login-password operation lost its active timeout"
rg -Fq 'PageOperationTimeout.perform(timeout: PageOperationTimeout.assetMutation)' "$ORBIT_ROOT/OrbitTerm/Features/Home/AccountSecurityView.swift" || fail "iOS master-password operation lost its active timeout"
rg -Fq 'scopedFeedbackAndLogoutConfirmationAreAccessible' "$android_security_ui_test" || fail "Android security-operation UI regression is missing"
rg -Fq 'testAccountSecurityStatesKeepRecoveryVisibleAndConfirmLogout' "$ios_operational_ui_test" || fail "iOS security-operation UI regression is missing"
rg -Fq 'biometricPromptBusyStatePreventsDuplicateSubmission' "$android_root_ui_test" || fail "Android biometric busy-state UI regression is missing"
rg -Fq 'biometricRecovery.exists' "$ios_operational_ui_test" || fail "iOS biometric invalidation persistence regression is missing"
rg -Fq 'setEnabled(false, for: session.username)' "$ios_master_gate" || fail "iOS invalid biometric enrollment is not failed closed"
! rg -Fq 'BiometricAuthService.shared.enroll' "$ios_master_gate" || fail "iOS master-password unlock silently re-enrolls biometrics"
rg -Fq 'setEnabled(false, for: accountID)' "$ios_biometric" || fail "iOS missing biometric enrollment is not invalidated"
rg -Fq 'BackgroundLockDisposition.LOCK_NOW' "$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main/java/com/orbitterm/android/MainActivity.kt" || fail "Android ordinary background transition no longer locks"
rg -Fq 'ordinaryBackgroundAlwaysLocksRegardlessOfSessionOwnership' "$android_lock_policy_test" || fail "Android ordinary background lock regression is missing"
rg -Fq 'DEFER_FOR_DOCUMENT_INTERACTION' "$android_lock_policy" || fail "Android document-picker grace policy is missing"
rg -Fq 'MobileAutoLockPolicy.shouldLockOnBackground' "$ios_app_session" || fail "iOS background auto-lock policy is not applied"
rg -Fq 'testMobileBackgroundLockRequiresAuthenticatedConfiguredAccount' "$ORBIT_ROOT/OrbitTermCheckedFFITests/ApplicationOperationLifecyclePolicyTests.swift" || fail "iOS background auto-lock regression is missing"
rg -Fq 'isAuthenticated && hasMasterPassword' "$ios_lifecycle_policy" || fail "iOS background auto-lock predicate changed without parity review"
rg -Fq 'set: { _ in }' "$ios_root_content" || fail "iOS sync conflict must require an explicit choice"
! rg -Fq 'Button("取消", role: .cancel)' "$ios_root_content" || fail "iOS sync conflict reintroduced an implicit cancel choice"
! rg -Fq '终端在线' "$ORBIT_ROOT/OrbitTerm/App/MobileSessionViews.swift" "$android_session" || fail "mobile session header reintroduced ambiguous online wording"

for notice in '终端内容已复制，将在 60 秒后自动清除。' '主机密钥指纹已复制，将在 60 秒后自动清除。'; do
  rg -Fq "$notice" "$ios_clipboard" || fail "iOS sensitive clipboard notice is missing: $notice"
  rg -Fq "$notice" "$android_clipboard" || fail "Android sensitive clipboard notice is missing: $notice"
done
rg -Fq 'options[.localOnly] = true' "$ios_clipboard" || fail "iOS timed clipboard content is no longer local-only"
rg -Fq 'options[.expirationDate]' "$ios_clipboard" || fail "iOS timed clipboard content lost its system expiration"
rg -Fq 'android.content.extra.IS_SENSITIVE' "$android_clipboard" || fail "Android timed clipboard content lost its sensitive marker"
rg -Fq 'testCredentialsAndPrivateKeysAreRejected' "$ios_clipboard_test" || fail "iOS clipboard rejection regression is missing"
rg -Fq 'credentialsAndPrivateKeysCannotEnterTheClipboard' "$android_clipboard_test" || fail "Android clipboard rejection regression is missing"
! rg -q 'setPrimaryClip\(' "$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/main" "$ORBIT_ROOT/clients/android/OrbitTermAndroid/feature/src/main" || fail "Android feature code bypasses the centralized clipboard policy"
! rg -q 'UIPasteboard\.general\.(string|setItems)' "$ORBIT_ROOT/OrbitTerm/App" "$ORBIT_ROOT/OrbitTerm/Features" || fail "iOS feature code bypasses the centralized clipboard policy"

rg -Fq 'UIApplication.userDidTakeScreenshotNotification' "$ios_sensitive_screen" || fail "iOS screenshot-sensitive-input cleanup is missing"
rg -Fq 'testSensitiveCoverIsShownOutsideActiveSceneOrDuringCapture' "$ios_clipboard_test" || fail "iOS sensitive-screen visibility regression is missing"
rg -Fq 'WindowManager.LayoutParams.FLAG_SECURE' "$android_main_activity" || fail "Android sensitive-screen protection is missing"

rg -Fq '.setVisibility(Notification.VISIBILITY_PRIVATE)' "$android_notification" || fail "Android foreground notification is no longer private"
rg -Fq '.setPublicVersion(publicVersion)' "$android_notification" || fail "Android foreground notification lost its redacted lock-screen version"
rg -Fq 'publicLockScreenVersionContainsNoSessionDetails' "$android_notification_test" || fail "Android notification-redaction regression is missing"

for forbidden in 'password' 'passphrase' 'privatekey' 'token'; do
  rg -Fq "$forbidden" "$ios_deep_link" || fail "iOS deep-link credential denylist is missing: $forbidden"
  rg -Fq "$forbidden" "$android_deep_link" || fail "Android deep-link credential denylist is missing: $forbidden"
done
rg -Fq 'testDeepLinksRejectEmbeddedCredentialsAndOversizedFields' "$ios_input_test" || fail "iOS unsafe deep-link regression is missing"
rg -Fq 'testLockedOrReplacedReviewDoesNotConsumePendingDeepLink' "$ios_input_test" || fail "iOS pending deep-link lifecycle regression is missing"
rg -Fq 'invalid deep links are rejected' "$android_deep_link_test" || fail "Android unsafe deep-link regression is missing"
rg -Fq 'deepLinkEditingServer = existing' "$ios_root_content" || fail "iOS existing deep-link asset no longer opens explicit review"
! rg -Fq '已识别现有资产，正在连接' "$ios_root_content" || fail "iOS deep links reintroduced automatic connection"
rg -Fq 'onReviewReady' "$android_assets_view_model" || fail "Android deep links are consumed before the review editor is ready"
rg -Fq 'handleIncomingIntent' "$android_main_activity" || fail "Android does not sanitize its retained external intent"

rg -Fq 'syncIncrementalPageSize = 100' "$ios_resource_budget" || fail "Apple sync delivery slice budget changed without parity review"
rg -Fq 'shouldYieldSyncDelivery' "$ios_sync_queue" || fail "Apple sync queue no longer yields at its bounded slice"
rg -Fq 'testSyncDeliveryYieldsAtConfiguredSliceBoundary' "$ios_resource_test" || fail "Apple sync slice stress regression is missing"
rg -Fq 'permitsSyncContinuation' "$ios_sync_queue" || fail "Apple sync continuation no longer revalidates account and network state"
rg -Fq 'testSyncContinuationStopsAfterNetworkLossLockOrAccountSwitch' "$ios_resource_test" || fail "Apple sync interruption regression is missing"
rg -Fq 'SYNC_OUTBOX_MAX_OPERATIONS_PER_RUN = 100' "$android_resource_budget" || fail "Android outbox slice budget changed without parity review"
rg -Fq 'ExistingWorkPolicy.APPEND_OR_REPLACE' "$android_sync_work" || fail "Android normal outbox backlog no longer uses a successful continuation chain"
rg -Uq '@Synchronized\s+fun enqueueOutboxContinuation' "$android_sync_work" || fail "Android continuation and logout are no longer serialized"
rg -Uq '@Synchronized\s+fun cancel' "$android_sync_work" || fail "Android logout no longer serializes against continuation scheduling"
rg -Fq 'setRequiredNetworkType(NetworkType.CONNECTED)' "$android_sync_work" || fail "Android sync continuation lost its network constraint"
rg -Fq 'listBatch(accountScope: String, limit: Int)' "$android_outbox_dao" || fail "Android outbox reverted to an unbounded read"
rg -Fq 'backlogReadsOneStableBoundedFifoPageWithoutDeletingRemainder' "$android_outbox_test" || fail "Android outbox FIFO page regression is missing"
rg -Fq 'processEquivalentDatabaseReopenPreservesUnfinishedBacklogAndAccountIsolation' "$android_outbox_test" || fail "Android process-interruption persistence regression is missing"
rg -Fq 'process restart lock and account switch cannot reuse an old continuation lease' "$ORBIT_ROOT/clients/android/OrbitTermAndroid/app/src/test/java/com/orbitterm/android/app/SyncWorkContractTest.kt" || fail "Android stale continuation lease regression is missing"

rg -Fq 'Idempotency-Key' "$ios_request_identity" || fail "Apple sync requests lost their stable idempotency header"
rg -Fq 'testMutationReplayFollowsOperationIDAcrossResponseLoss' "$ios_request_identity_test" || fail "Apple unknown-result mutation replay regression is missing"
rg -Fq 'Idempotency-Key' "$android_api" || fail "Android sync requests lost their stable idempotency header"
rg -Fq 'V8_TO_V9' "$android_migrations" || fail "Android pending intents no longer receive a durable replay identity"
rg -Fq 'migratesPendingVersion8IntentWithOneDurableReplayIdentity' "$android_migration_test" || fail "Android replay-identity migration regression is missing"
rg -Fq 'lateResponseCannotDeleteANewerCoalescedIntent' "$android_outbox_test" || fail "Android late-response queue isolation regression is missing"
rg -Fq 'accepted upload with lost response is recognized without persisting a secret digest' "$android_conflict_test" || fail "Android unknown upload-result reconciliation regression is missing"
rg -Fq 'unknown_result_queued' "$ios_diagnostics" || fail "Apple sync observability lost its allow-listed unknown-result event"
rg -Fq 'testSyncEventExportContainsOnlyAllowListedAggregateFields' "$ios_diagnostics_test" || fail "Apple sync diagnostic privacy regression is missing"
rg -Fq 'object PrivacySafeSyncMetrics' "$android_sync_diagnostics" || fail "Android aggregate sync diagnostics are missing"
rg -Fq 'metrics retain only allow-listed event counts' "$android_sync_diagnostics_test" || fail "Android sync diagnostic privacy regression is missing"
rg -Fq 'delivery_blocked' "$ios_diagnostics" || fail "Apple blocked-delivery diagnostics are missing"
rg -Fq 'delivery_blocked' "$android_sync_diagnostics" || fail "Android blocked-delivery diagnostics are missing"
rg -Fq 'maximumServiceUnavailableAttempts' "$ios_sync_recovery_policy" || fail "Apple ambiguous service failures lost their retry bound"
rg -Fq 'testConfigurationProtocolAndUnknownFailuresAreBlocked' "$ios_sync_recovery_test" || fail "Apple permanent-failure isolation regression is missing"
rg -Fq 'MAX_REMOTE_REJECTION_ATTEMPTS' "$android_sync_recovery_policy" || fail "Android ambiguous service failures lost their retry bound"
rg -Fq 'unknown and invalid work is isolated instead of spinning' "$android_sync_recovery_test" || fail "Android permanent-failure isolation regression is missing"
rg -Fq 'V9_TO_V10' "$android_migrations" || fail "Android durable outbox disposition migration is missing"
rg -Fq 'migratesVersion9IntentAsReadyWithoutInventingFailureState' "$android_migration_test" || fail "Android disposition migration regression is missing"
rg -Fq 'blockedIntentIsDurableExcludedAndDiscardedOnlyByExplicitBlockedQuery' "$android_outbox_test" || fail "Android blocked-item discard isolation regression is missing"
for recovery_action in '重新尝试受阻项目' '丢弃受阻项目'; do
  rg -Fq "$recovery_action" "$ios_settings" || fail "Apple blocked-sync action is missing: $recovery_action"
  rg -Fq "$recovery_action" "$android_main_screen" || fail "Android blocked-sync action is missing: $recovery_action"
done
for status_contract in 'statusCode == 401' 'statusCode == 408' 'statusCode == 425 || statusCode == 429' 'statusCode in 500..599' 'statusCode in 400..499'; do
  rg -Fq "$status_contract" "$android_http_policy" || fail "Android HTTP sync contract is missing: $status_contract"
done
for status_contract in 'case 401:' 'case 408, 425, 429, 500 ... 599:' 'case 400 ... 499:'; do
  rg -Fq "$status_contract" "$ios_http_policy" || fail "Apple HTTP sync contract is missing: $status_contract"
done
rg -Fq 'MAX_RETRY_AFTER_SECONDS = 3_600L' "$android_http_policy" || fail "Android Retry-After clamp is missing"
rg -Fq 'maximumRetryAfter: TimeInterval = 3_600' "$ios_http_policy" || fail "Apple Retry-After clamp is missing"
rg -Fq 'expectSuccess = true' "$android_api" || fail "Android no longer classifies non-2xx before decoding its body"
rg -Fq 'ResponseException' "$android_api" || fail "Android HTTP status mapping is disconnected from the API client"
rg -Fq 'effectiveRetryDelay' "$ios_sync_queue" || fail "Apple queue no longer honors server-advised retry delay"
rg -Fq 'V10_TO_V11' "$android_migrations" || fail "Android durable Retry-After migration is missing"
rg -Fq 'retryAfterSurvivesStorageAndPreventsEarlySelection' "$android_outbox_test" || fail "Android durable Retry-After regression is missing"
rg -Fq 'retry after accepts delta and http date and clamps untrusted values' "$android_http_policy_test" || fail "Android Retry-After parser regression is missing"
rg -Fq 'testRetryAfterAcceptsDeltaAndHTTPDateAndClampsUntrustedValues' "$ios_http_policy_test" || fail "Apple Retry-After parser regression is missing"
! rg -q 'message[.](contains|lowercased).*conflict|localizedDescription[.]lowercased' "$ios_sync_conflict" || fail "Apple conflict classification depends on untrusted error text"

pass "Android/iOS source parity contracts"
