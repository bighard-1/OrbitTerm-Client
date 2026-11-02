use std::sync::mpsc::{Receiver, TryRecvError};

#[derive(Debug, PartialEq, Eq)]
pub(crate) enum PreviewPoll<T, E> {
    Pending,
    Obsolete,
    Completed(Result<T, E>),
    Interrupted,
}

// Validate the original rendered directory before handling any outcome,
// including errors and worker termination. Obsolete callbacks must be silent
// so they cannot replace another workspace's status or open an old editor.
pub(crate) fn poll_preview<C: PartialEq, T, E>(
    expected: &C,
    current: Option<&C>,
    receiver: &Receiver<Result<T, E>>,
) -> PreviewPoll<T, E> {
    if current != Some(expected) {
        return PreviewPoll::Obsolete;
    }
    match receiver.try_recv() {
        Ok(result) => PreviewPoll::Completed(result),
        Err(TryRecvError::Empty) => PreviewPoll::Pending,
        Err(TryRecvError::Disconnected) => PreviewPoll::Interrupted,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::mpsc;

    type Owner = (u64, u64, u64, &'static str, u64);
    const ORIGINAL: Owner = (1, 11, 23, "/original", 7);

    #[test]
    fn current_view_receives_success_and_readable_failure_input() {
        for result in [Ok("preview body"), Err("permission_denied")] {
            let (sender, receiver) = mpsc::channel();
            sender.send(result).unwrap();
            assert_eq!(
                poll_preview(&ORIGINAL, Some(&ORIGINAL), &receiver),
                PreviewPoll::Completed(result)
            );
        }
    }

    #[test]
    fn waiting_and_interrupted_workers_are_distinct_for_the_current_view() {
        let (sender, receiver) = mpsc::channel::<Result<(), ()>>();
        assert_eq!(
            poll_preview(&ORIGINAL, Some(&ORIGINAL), &receiver),
            PreviewPoll::Pending
        );
        drop(sender);
        assert_eq!(
            poll_preview(&ORIGINAL, Some(&ORIGINAL), &receiver),
            PreviewPoll::Interrupted
        );
    }

    #[test]
    fn changed_context_discards_both_late_success_and_late_failure() {
        let contexts = [
            None,
            Some((2, 11, 23, "/original", 7)),
            Some((1, 12, 23, "/original", 7)),
            Some((1, 11, 24, "/original", 7)),
            Some((1, 11, 23, "/other", 7)),
            Some((1, 11, 23, "/original", 8)),
        ];
        for current in contexts {
            for result in [Ok("old preview body"), Err("old failure")] {
                let (sender, receiver) = mpsc::channel();
                sender.send(result).unwrap();
                assert_eq!(
                    poll_preview(&ORIGINAL, current.as_ref(), &receiver),
                    PreviewPoll::Obsolete
                );
            }
        }
    }

    #[test]
    fn leaving_while_waiting_stops_polling_without_touching_the_new_view() {
        let (sender, receiver) = mpsc::channel::<Result<(), ()>>();
        assert_eq!(
            poll_preview(&ORIGINAL, None, &receiver),
            PreviewPoll::Obsolete
        );
        drop(sender);
        assert_eq!(
            poll_preview(&ORIGINAL, None, &receiver),
            PreviewPoll::Obsolete
        );
    }
}
