use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

#[derive(Clone, Default)]
pub(crate) struct ConnectCancellation(Arc<AtomicBool>);

impl ConnectCancellation {
    pub fn cancel(&self) {
        self.0.store(true, Ordering::Release);
    }

    pub fn is_cancelled(&self) -> bool {
        self.0.load(Ordering::Acquire)
    }
}

/// A worker owns a successful connection until the matching workspace adopts it.
/// Dropping a stale result, failed send, or unread receiver must release it.
pub(crate) struct PendingConnection<T, F: FnOnce(T) = fn(T)> {
    value: Option<T>,
    cleanup: Option<F>,
}

impl<T, F: FnOnce(T)> PendingConnection<T, F> {
    pub fn new(value: T, cleanup: F) -> Self {
        Self {
            value: Some(value),
            cleanup: Some(cleanup),
        }
    }

    pub fn value(&self) -> &T {
        self.value.as_ref().expect("unclaimed connection")
    }

    pub fn value_mut(&mut self) -> &mut T {
        self.value.as_mut().expect("unclaimed connection")
    }

    pub fn claim(mut self) -> T {
        self.value.take().expect("unclaimed connection")
    }
}

impl<T, F: FnOnce(T)> Drop for PendingConnection<T, F> {
    fn drop(&mut self) {
        if let (Some(value), Some(cleanup)) = (self.value.take(), self.cleanup.take()) {
            cleanup(value);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{mpsc, Arc, Mutex};

    #[test]
    fn cancellation_reaches_the_worker_without_cancelling_a_replacement() {
        let original = ConnectCancellation::default();
        let worker = original.clone();
        let replacement = ConnectCancellation::default();
        original.cancel();
        assert!(std::thread::spawn(move || worker.is_cancelled())
            .join()
            .unwrap());
        assert!(!replacement.is_cancelled());
    }

    #[test]
    fn abandoned_result_releases_all_acquired_handles_once() {
        let released = Arc::new(Mutex::new(Vec::new()));
        let observed = released.clone();
        let mut result = PendingConnection::new(vec![41], move |ids| {
            observed.lock().unwrap().extend(ids);
        });
        result.value_mut().push(42);
        assert_eq!(result.value(), &[41, 42]);
        drop(result);
        assert_eq!(*released.lock().unwrap(), [41, 42]);
    }

    #[test]
    fn adopted_result_transfers_ownership_without_cleanup() {
        let result = PendingConnection::new(41, |_| panic!("adopted handle released"));
        assert_eq!(result.claim(), 41);
    }

    #[test]
    fn cancellation_before_worker_send_releases_the_result() {
        let released = Arc::new(Mutex::new(Vec::new()));
        let observed = released.clone();
        let (sender, receiver) = mpsc::channel();
        drop(receiver);
        let result = PendingConnection::new(41, move |id| observed.lock().unwrap().push(id));
        let failed_send = sender.send(result);
        assert!(failed_send.is_err());
        drop(failed_send);
        assert_eq!(*released.lock().unwrap(), [41]);
    }

    #[test]
    fn cancellation_after_worker_send_releases_an_unread_result() {
        let released = Arc::new(Mutex::new(Vec::new()));
        let observed = released.clone();
        let (sender, receiver) = mpsc::channel();
        let result = PendingConnection::new(41, move |id| observed.lock().unwrap().push(id));
        assert!(sender.send(result).is_ok());
        drop(receiver);
        assert_eq!(*released.lock().unwrap(), [41]);
    }
}
