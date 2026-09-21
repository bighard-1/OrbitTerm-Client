use std::cell::Cell;
use std::rc::Rc;

#[derive(Clone, Default)]
pub(crate) struct SyncSchedulerGate {
    inner: Rc<SyncSchedulerGateInner>,
}

#[derive(Default)]
struct SyncSchedulerGateInner {
    background_busy: Cell<bool>,
    dialog_open: Cell<bool>,
}

impl SyncSchedulerGate {
    pub(crate) fn try_begin_background(&self) -> bool {
        if self.inner.dialog_open.get() || self.inner.background_busy.replace(true) {
            return false;
        }
        true
    }

    pub(crate) fn finish_background(&self) {
        self.inner.background_busy.set(false);
    }

    pub(crate) fn try_open_dialog(&self) -> bool {
        if self.inner.dialog_open.replace(true) {
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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn background_work_is_single_flight() {
        let gate = SyncSchedulerGate::default();
        assert!(gate.try_begin_background());
        assert!(!gate.try_begin_background());
        gate.finish_background();
        assert!(gate.try_begin_background());
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
}
