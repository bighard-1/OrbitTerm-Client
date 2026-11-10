use std::cell::Cell;
use std::rc::Rc;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum BackgroundSyncAction {
    ApplyStaged,
    RetryQueue,
    Pull,
    WaitForRetry,
    WaitForResolution,
}

pub(crate) fn choose_background_sync_action(
    staged_unresolved: Option<usize>,
    has_pending: bool,
    has_due_retryable: bool,
    needs_deleted_asset_resolution: bool,
) -> BackgroundSyncAction {
    if staged_unresolved == Some(0) {
        BackgroundSyncAction::ApplyStaged
    } else if has_due_retryable {
        BackgroundSyncAction::RetryQueue
    } else if staged_unresolved.is_some() {
        BackgroundSyncAction::WaitForResolution
    } else if !has_pending || needs_deleted_asset_resolution {
        BackgroundSyncAction::Pull
    } else {
        BackgroundSyncAction::WaitForRetry
    }
}

#[derive(Clone, Default)]
pub(crate) struct SyncSchedulerGate {
    inner: Rc<SyncSchedulerGateInner>,
}

#[derive(Default)]
struct SyncSchedulerGateInner {
    background_busy: Cell<bool>,
    dialog_open: Cell<bool>,
    security_busy: Cell<bool>,
    logout_in_flight: Cell<bool>,
    logout_unresolved: Cell<bool>,
}

thread_local! {
    static SHARED_SYNC_SCHEDULER: SyncSchedulerGate = SyncSchedulerGate::default();
}

impl SyncSchedulerGate {
    pub(crate) fn shared() -> Self {
        SHARED_SYNC_SCHEDULER.with(Clone::clone)
    }

    pub(crate) fn try_begin_background(&self) -> bool {
        if self.inner.dialog_open.get()
            || self.inner.security_busy.get()
            || self.inner.logout_unresolved.get()
            || self.inner.background_busy.replace(true)
        {
            return false;
        }
        true
    }

    pub(crate) fn finish_background(&self) {
        self.inner.background_busy.set(false);
    }

    pub(crate) fn try_open_dialog(&self) -> bool {
        if self.inner.security_busy.get()
            || self.inner.logout_in_flight.get()
            || self.inner.dialog_open.replace(true)
        {
            return false;
        }
        true
    }

    pub(crate) fn close_dialog(&self) {
        self.inner.dialog_open.set(false);
    }

    pub(crate) fn background_busy(&self) -> bool {
        self.inner.background_busy.get()
    }

    pub(crate) fn try_begin_security(&self) -> bool {
        if self.inner.background_busy.get()
            || self.inner.dialog_open.get()
            || self.inner.logout_unresolved.get()
            || self.inner.security_busy.replace(true)
        {
            return false;
        }
        true
    }

    pub(crate) fn finish_security(&self) {
        self.inner.security_busy.set(false);
    }

    pub(crate) fn try_begin_logout(&self) -> bool {
        if self.inner.logout_in_flight.replace(true) {
            return false;
        }
        self.inner.logout_unresolved.set(true);
        true
    }

    pub(crate) fn finish_logout(&self) {
        self.inner.logout_in_flight.set(false);
        self.inner.logout_unresolved.set(false);
    }

    pub(crate) fn fail_logout(&self) {
        self.inner.logout_in_flight.set(false);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn blocked_tombstone_does_not_starve_unrelated_due_upload() {
        assert_eq!(
            choose_background_sync_action(None, true, true, true),
            BackgroundSyncAction::RetryQueue
        );
        assert_eq!(
            choose_background_sync_action(None, true, false, true),
            BackgroundSyncAction::Pull
        );
    }

    #[test]
    fn unresolved_staged_preview_allows_queue_but_guards_cursor() {
        assert_eq!(
            choose_background_sync_action(Some(1), true, true, true),
            BackgroundSyncAction::RetryQueue
        );
        assert_eq!(
            choose_background_sync_action(Some(1), true, false, true),
            BackgroundSyncAction::WaitForResolution
        );
        assert_eq!(
            choose_background_sync_action(Some(1), false, false, false),
            BackgroundSyncAction::WaitForResolution
        );
    }

    #[test]
    fn resolved_staged_preview_finishes_before_queue_or_pull() {
        assert_eq!(
            choose_background_sync_action(Some(0), true, true, false),
            BackgroundSyncAction::ApplyStaged
        );
    }

    #[test]
    fn regular_queue_waits_for_backoff_and_empty_queue_pulls() {
        assert_eq!(
            choose_background_sync_action(None, true, false, false),
            BackgroundSyncAction::WaitForRetry
        );
        assert_eq!(
            choose_background_sync_action(None, false, false, false),
            BackgroundSyncAction::Pull
        );
    }

    #[test]
    fn background_work_is_single_flight() {
        let gate = SyncSchedulerGate::default();
        assert!(gate.try_begin_background());
        assert!(!gate.try_begin_background());
        gate.finish_background();
        assert!(gate.try_begin_background());
    }

    #[test]
    fn account_security_waits_for_manual_sync_dialog_to_close() {
        let gate = SyncSchedulerGate::default();
        assert!(gate.try_open_dialog());
        assert!(!gate.try_begin_security());
        gate.close_dialog();
        assert!(gate.try_begin_security());
    }

    #[test]
    fn open_dialog_suppresses_background_work_until_closed() {
        let gate = SyncSchedulerGate::default();
        assert!(gate.try_open_dialog());
        assert!(!gate.try_open_dialog());
        assert!(!gate.try_begin_background());
        gate.close_dialog();
        assert!(gate.try_begin_background());
    }

    #[test]
    fn security_change_and_background_refresh_are_mutually_exclusive() {
        let gate = SyncSchedulerGate::default();
        assert!(gate.try_begin_background());
        assert!(!gate.try_begin_security());
        gate.finish_background();
        assert!(gate.try_begin_security());
        assert!(!gate.try_begin_background());
        assert!(!gate.try_begin_security());
        gate.finish_security();
        assert!(gate.try_begin_background());
    }

    #[test]
    fn logout_stays_exclusive_when_an_older_security_operation_finishes() {
        let gate = SyncSchedulerGate::default();
        assert!(gate.try_begin_security());
        assert!(gate.try_begin_logout());
        gate.finish_security();
        assert!(!gate.try_begin_background());
        assert!(!gate.try_begin_security());
        assert!(!gate.try_open_dialog());
        gate.finish_logout();
        assert!(gate.try_begin_background());
    }

    #[test]
    fn failed_logout_can_be_retried_without_resuming_background() {
        let gate = SyncSchedulerGate::default();
        assert!(gate.try_begin_logout());
        assert!(!gate.try_begin_logout());
        gate.fail_logout();
        assert!(!gate.try_begin_background());
        assert!(gate.try_open_dialog());
        gate.close_dialog();
        assert!(gate.try_begin_logout());
        gate.finish_logout();
        assert!(gate.try_begin_background());
    }

    #[test]
    fn windows_on_the_main_context_share_one_sync_gate() {
        let first = SyncSchedulerGate::shared();
        let second = SyncSchedulerGate::shared();
        assert!(first.try_begin_background());
        assert!(!second.try_begin_background());
        first.finish_background();
    }
}
