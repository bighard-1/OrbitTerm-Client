#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(crate) struct SshHandles {
    pub terminals: Vec<u64>,
    pub sftp: Option<u64>,
    pub tunnels: Vec<u64>,
    pub base: Option<u64>,
}

impl SshHandles {
    pub fn is_empty(&self) -> bool {
        self.terminals.is_empty()
            && self.sftp.is_none()
            && self.tunnels.is_empty()
            && self.base.is_none()
    }

    // Keep every unconfirmed handle. A retry must not release an already
    // acknowledged base reference twice, or discard a failed child's owner.
    pub fn release(
        mut self,
        mut terminal: impl FnMut(u64) -> bool,
        mut sftp: impl FnMut(u64) -> bool,
        mut tunnel: impl FnMut(u64) -> bool,
        mut base: impl FnMut(u64) -> bool,
    ) -> Self {
        self.terminals.retain(|id| !terminal(*id));
        if self.sftp.is_some_and(&mut sftp) {
            self.sftp = None;
        }
        self.tunnels.retain(|id| !tunnel(*id));
        if self.terminals.is_empty()
            && self.sftp.is_none()
            && self.tunnels.is_empty()
            && self.base.is_some_and(&mut base)
        {
            self.base = None;
        }
        self
    }
}

pub(crate) struct SshDisconnect {
    pub handles: SshHandles,
    pub running: bool,
    pub remove_tab: bool,
    revision: u64,
}

impl SshDisconnect {
    pub fn new(handles: SshHandles) -> Self {
        Self {
            handles,
            running: false,
            remove_tab: false,
            revision: 0,
        }
    }

    pub fn begin(&mut self, remove_tab: bool) -> Option<(u64, SshHandles)> {
        self.remove_tab |= remove_tab;
        if self.running {
            return None;
        }
        self.revision = self.revision.wrapping_add(1);
        self.running = true;
        Some((self.revision, self.handles.clone()))
    }

    pub fn finish(&mut self, revision: u64, remaining: SshHandles) -> bool {
        if !self.running || revision != self.revision {
            return false;
        }
        self.handles = remaining;
        self.running = false;
        true
    }

    pub fn label(&self) -> &'static str {
        if self.running {
            "正在断开连接…"
        } else {
            "断开未完成"
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    fn handles() -> SshHandles {
        SshHandles {
            terminals: vec![11, 12],
            sftp: Some(23),
            tunnels: vec![31],
            base: Some(41),
        }
    }

    #[test]
    fn release_acknowledges_children_before_the_base() {
        let calls = RefCell::new(Vec::new());
        let done = handles().release(
            |id| {
                calls.borrow_mut().push(id);
                true
            },
            |id| {
                calls.borrow_mut().push(id);
                true
            },
            |id| {
                calls.borrow_mut().push(id);
                true
            },
            |id| {
                calls.borrow_mut().push(id);
                true
            },
        );
        assert!(done.is_empty());
        assert_eq!(*calls.borrow(), [11, 12, 23, 31, 41]);
    }

    #[test]
    fn failed_child_retains_its_owner_and_prevents_base_release() {
        let remaining = handles().release(|id| id != 12, |_| true, |_| false, |_| panic!("base"));
        assert_eq!(remaining.terminals, [12]);
        assert_eq!(remaining.sftp, None);
        assert_eq!(remaining.tunnels, [31]);
        assert_eq!(remaining.base, Some(41));
        let calls = RefCell::new(Vec::new());
        let done = remaining.release(
            |id| {
                calls.borrow_mut().push(id);
                true
            },
            |_| panic!("already released SFTP"),
            |id| {
                calls.borrow_mut().push(id);
                true
            },
            |id| {
                calls.borrow_mut().push(id);
                true
            },
        );
        assert!(done.is_empty());
        assert_eq!(*calls.borrow(), [12, 31, 41]);
    }

    #[test]
    fn failed_base_is_the_only_handle_retried() {
        let remaining = handles().release(|_| true, |_| true, |_| true, |_| false);
        assert_eq!(
            remaining,
            SshHandles {
                base: Some(41),
                ..Default::default()
            }
        );
        assert!(remaining
            .release(|_| panic!(), |_| panic!(), |_| panic!(), |_| true)
            .is_empty());
    }

    #[test]
    fn duplicate_start_keeps_the_original_ownership_and_close_intent() {
        let mut state = SshDisconnect::new(handles());
        let (revision, _) = state.begin(false).unwrap();
        assert!(state.begin(true).is_none());
        assert!(state.running && state.remove_tab);
        assert_eq!(state.handles, handles());
        assert!(state.finish(revision, SshHandles::default()));
        assert!(state.handles.is_empty());
    }

    #[test]
    fn late_or_repeated_completion_cannot_overwrite_a_retry() {
        let mut state = SshDisconnect::new(handles());
        let (first, _) = state.begin(false).unwrap();
        assert!(state.finish(first, handles()));
        let (retry, _) = state.begin(false).unwrap();
        assert!(!state.finish(first, SshHandles::default()));
        assert!(state.running);
        assert_eq!(state.handles, handles());
        assert!(state.finish(retry, SshHandles::default()));
        assert!(!state.finish(retry, handles()));
        assert!(state.handles.is_empty());
    }

    #[test]
    fn interrupted_worker_keeps_handles_for_explicit_retry() {
        let mut state = SshDisconnect::new(handles());
        let (revision, _) = state.begin(false).unwrap();
        assert_eq!(state.label(), "正在断开连接…");
        assert!(state.finish(revision, state.handles.clone()));
        assert_eq!(state.label(), "断开未完成");
        assert_eq!(state.begin(false).unwrap().1, handles());
    }
}
