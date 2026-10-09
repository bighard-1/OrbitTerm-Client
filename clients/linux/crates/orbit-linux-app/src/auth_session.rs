use futures::lock::Mutex;
use orbit_linux_platform::{AuthTokenMaterial, AuthTokenVault, PlatformError};
use std::cell::Cell;
use std::future::Future;
use std::rc::Rc;

/// Main-context generation plus a keyring write gate. A generation check alone
/// cannot protect logout when a libsecret write is already suspended in await.
#[derive(Clone, Default)]
pub(crate) struct AuthSessionCoordinator {
    inner: Rc<AuthSessionInner>,
}

#[derive(Default)]
struct AuthSessionInner {
    generation: Cell<u64>,
    suspended: Cell<bool>,
    logout_active: Cell<bool>,
    logout_pending: Cell<bool>,
    keyring_gate: Mutex<()>,
}

thread_local! {
    static SHARED_AUTH_SESSION: AuthSessionCoordinator = AuthSessionCoordinator::default();
}

impl AuthSessionCoordinator {
    pub(crate) fn shared() -> Self {
        SHARED_AUTH_SESSION.with(Clone::clone)
    }

    pub(crate) fn snapshot(&self) -> u64 {
        self.inner.generation.get()
    }

    pub(crate) fn is_current(&self, generation: u64) -> bool {
        !self.inner.suspended.get() && self.snapshot() == generation
    }

    /// Must run synchronously when the user commits to logout or when a new
    /// credential supersedes older work, before any keyring await.
    pub(crate) fn advance(&self) -> u64 {
        let next = self.snapshot().wrapping_add(1);
        self.inner.generation.set(next);
        next
    }

    pub(crate) fn begin_logout(&self) -> bool {
        if self.inner.logout_active.replace(true) {
            return false;
        }
        self.inner.logout_pending.set(true);
        self.inner.suspended.set(true);
        self.advance();
        true
    }

    pub(crate) fn begin_login(&self) -> Option<u64> {
        if self.inner.logout_pending.get() {
            return None;
        }
        let generation = self.advance();
        self.inner.suspended.set(false);
        Some(generation)
    }

    fn complete_logout(&self, cleared: bool) {
        self.inner.logout_active.set(false);
        if cleared {
            self.inner.logout_pending.set(false);
        }
    }

    pub(crate) async fn store(
        &self,
        vault: &AuthTokenVault,
        material: &AuthTokenMaterial,
        generation: u64,
    ) -> Result<(), PlatformError> {
        self.store_with(generation, || vault.store(material), || vault.clear())
            .await
    }

    /// Read the access token for best-effort remote revocation and clear the
    /// local session as one ordered keyring operation. In particular, do not
    /// await a separate lookup before joining the write gate.
    pub(crate) async fn take_and_clear(
        &self,
        vault: &AuthTokenVault,
    ) -> Result<Option<String>, PlatformError> {
        let _guard = self.inner.keyring_gate.lock().await;
        let remote_access = vault
            .lookup()
            .await
            .ok()
            .flatten()
            .map(|material| material.access_token.clone());
        let result = vault.clear().await;
        self.complete_logout(result.is_ok());
        result.map(|()| remote_access)
    }

    async fn store_with<Store, StoreFuture, Clear, ClearFuture>(
        &self,
        generation: u64,
        store: Store,
        clear: Clear,
    ) -> Result<(), PlatformError>
    where
        Store: FnOnce() -> StoreFuture,
        StoreFuture: Future<Output = Result<(), PlatformError>>,
        Clear: FnOnce() -> ClearFuture,
        ClearFuture: Future<Output = Result<(), PlatformError>>,
    {
        let _guard = self.inner.keyring_gate.lock().await;
        if !self.is_current(generation) {
            return Err(PlatformError::StaleAuthSession);
        }
        let result = store().await;
        if !self.is_current(generation) {
            // A logout may have happened during libsecret's async write. No
            // newer write can start until this clear has completed.
            clear().await?;
            return Err(PlatformError::StaleAuthSession);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use futures::channel::oneshot;
    use futures::executor::LocalPool;
    use futures::task::LocalSpawnExt;
    use std::cell::RefCell;

    #[test]
    fn completed_old_worker_cannot_restore_logged_out_tokens() {
        let coordinator = AuthSessionCoordinator::default();
        let old = coordinator.snapshot();
        assert!(coordinator.begin_logout());
        let writes = Rc::new(Cell::new(0));
        let store_writes = writes.clone();
        let result = futures::executor::block_on(coordinator.store_with(
            old,
            move || async move {
                store_writes.set(store_writes.get() + 1);
                Ok(())
            },
            || async { Ok(()) },
        ));
        assert!(matches!(result, Err(PlatformError::StaleAuthSession)));
        assert_eq!(writes.get(), 0);
    }

    #[test]
    fn logout_during_keyring_write_clears_before_new_session_write() {
        let coordinator = AuthSessionCoordinator::default();
        let old = coordinator.snapshot();
        let keyring = Rc::new(RefCell::new(None::<&'static str>));
        let (started_tx, started_rx) = oneshot::channel();
        let (finish_tx, finish_rx) = oneshot::channel();
        let mut pool = LocalPool::new();
        let spawner = pool.spawner();
        let old_coordinator = coordinator.clone();
        let old_store = keyring.clone();
        let old_clear = keyring.clone();
        spawner
            .spawn_local(async move {
                let result = old_coordinator
                    .store_with(
                        old,
                        move || async move {
                            let _ = started_tx.send(());
                            let _ = finish_rx.await;
                            old_store.replace(Some("old"));
                            Ok(())
                        },
                        move || async move {
                            old_clear.replace(None);
                            Ok(())
                        },
                    )
                    .await;
                assert!(matches!(result, Err(PlatformError::StaleAuthSession)));
            })
            .unwrap();
        pool.run_until(started_rx).unwrap();
        assert!(coordinator.begin_logout());
        assert!(coordinator.begin_login().is_none());
        coordinator.complete_logout(true);
        let new = coordinator.begin_login().unwrap();
        let new_coordinator = coordinator.clone();
        let new_store = keyring.clone();
        spawner
            .spawn_local(async move {
                new_coordinator
                    .store_with(
                        new,
                        move || async move {
                            new_store.replace(Some("new"));
                            Ok(())
                        },
                        || async { Ok(()) },
                    )
                    .await
                    .unwrap();
            })
            .unwrap();
        pool.run_until_stalled();
        assert_eq!(*keyring.borrow(), None);
        finish_tx.send(()).unwrap();
        pool.run();
        assert_eq!(*keyring.borrow(), Some("new"));
    }

    #[test]
    fn logout_blocks_even_new_background_snapshots_until_explicit_login() {
        let coordinator = AuthSessionCoordinator::default();
        assert!(coordinator.begin_logout());
        assert!(!coordinator.is_current(coordinator.snapshot()));
        assert!(coordinator.begin_login().is_none());
        coordinator.complete_logout(true);
        let login = coordinator.begin_login().unwrap();
        assert!(coordinator.is_current(login));
    }

    #[test]
    fn failed_clear_blocks_login_but_allows_logout_retry() {
        let coordinator = AuthSessionCoordinator::default();
        assert!(coordinator.begin_logout());
        assert!(!coordinator.begin_logout());
        coordinator.complete_logout(false);
        assert!(coordinator.begin_login().is_none());
        assert!(coordinator.begin_logout());
        coordinator.complete_logout(true);
        assert!(coordinator.begin_login().is_some());
    }

    #[test]
    fn every_window_on_the_main_context_shares_one_generation() {
        let first = AuthSessionCoordinator::shared();
        let second = AuthSessionCoordinator::shared();
        let before = second.snapshot();
        first.advance();
        assert_ne!(second.snapshot(), before);
    }
}
