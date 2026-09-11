use std::cell::RefCell;
use std::rc::Rc;
use zeroize::Zeroizing;

const UNLOCK_IDLE_TIMEOUT_MS: u64 = 30 * 60 * 1_000;

#[derive(Clone, Default)]
pub(crate) struct SecureSyncSession {
    inner: Rc<RefCell<SecureSyncSessionState>>,
}

#[derive(Default)]
struct SecureSyncSessionState {
    account_fingerprint: Option<String>,
    master_password: Option<Zeroizing<String>>,
    last_used_unix_ms: u64,
    last_pull_unix_ms: u64,
    notification_key: Option<String>,
}

impl SecureSyncSession {
    pub(crate) fn unlock(
        &self,
        account_fingerprint: String,
        master_password: String,
        now_unix_ms: u64,
    ) -> bool {
        if account_fingerprint.is_empty()
            || master_password.is_empty()
            || master_password.len() > 16 * 1024
        {
            return false;
        }
        let mut state = self.inner.borrow_mut();
        state.account_fingerprint = Some(account_fingerprint);
        state.master_password = Some(Zeroizing::new(master_password));
        state.last_used_unix_ms = now_unix_ms;
        state.notification_key = None;
        true
    }

    pub(crate) fn password_for(
        &self,
        account_fingerprint: &str,
        now_unix_ms: u64,
    ) -> Option<Zeroizing<String>> {
        let mut state = self.inner.borrow_mut();
        if state.account_fingerprint.as_deref() != Some(account_fingerprint) {
            return None;
        }
        if now_unix_ms.saturating_sub(state.last_used_unix_ms) > UNLOCK_IDLE_TIMEOUT_MS {
            state.account_fingerprint = None;
            state.master_password = None;
            state.last_used_unix_ms = 0;
            return None;
        }
        state.master_password.clone()
    }

    pub(crate) fn lock(&self) {
        let mut state = self.inner.borrow_mut();
        state.account_fingerprint = None;
        state.master_password = None;
        state.last_used_unix_ms = 0;
        state.last_pull_unix_ms = 0;
        state.notification_key = None;
    }

    pub(crate) fn pull_is_due(&self, now_unix_ms: u64, interval_ms: u64) -> bool {
        now_unix_ms.saturating_sub(self.inner.borrow().last_pull_unix_ms) >= interval_ms
    }

    pub(crate) fn record_pull(&self, now_unix_ms: u64) {
        self.inner.borrow_mut().last_pull_unix_ms = now_unix_ms;
    }

    pub(crate) fn should_notify(&self, key: String) -> bool {
        let mut state = self.inner.borrow_mut();
        if state.notification_key.as_ref() == Some(&key) {
            return false;
        }
        state.notification_key = Some(key);
        true
    }

    pub(crate) fn clear_notification(&self) {
        self.inner.borrow_mut().notification_key = None;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn account_switch_replaces_the_in_memory_unlock() {
        let session = SecureSyncSession::default();
        assert!(session.unlock("account-a".into(), "master-a".into(), 100));
        assert_eq!(
            session
                .password_for("account-a", 200)
                .as_deref()
                .map(String::as_str),
            Some("master-a")
        );
        assert!(session.unlock("account-b".into(), "master-b".into(), 300));
        assert!(session.password_for("account-a", 400).is_none());
        assert_eq!(
            session
                .password_for("account-b", 400)
                .as_deref()
                .map(String::as_str),
            Some("master-b")
        );
    }

    #[test]
    fn unlock_expires_and_explicit_lock_clears_account_scope() {
        let session = SecureSyncSession::default();
        assert!(session.unlock("account-a".into(), "master".into(), 10));
        assert!(session
            .password_for("account-a", 10 + UNLOCK_IDLE_TIMEOUT_MS + 1)
            .is_none());
        assert!(session.password_for("account-a", 11).is_none());
        assert!(session.unlock("account-a".into(), "master".into(), 20));
        session.lock();
        assert!(session.password_for("account-a", 21).is_none());
    }

    #[test]
    fn notification_keys_are_deduplicated_until_health_recovers() {
        let session = SecureSyncSession::default();
        assert!(session.should_notify("conflict:2".into()));
        assert!(!session.should_notify("conflict:2".into()));
        session.clear_notification();
        assert!(session.should_notify("conflict:2".into()));
    }
}
