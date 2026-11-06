//! Native-thread surface readiness and bounded retry after a failed InitWindow.
//! This policy has no Android/GPU dependencies so failure paths can be tested
//! without adding a production fault-injection API.
use std::time::{Duration, Instant};

const RETRY_DELAY: Duration = Duration::from_millis(250);

#[derive(Default)]
pub(crate) struct SurfaceLifecycle {
    ready: bool,
    pending: bool,
    retry_at: Option<Instant>,
}

impl SurfaceLifecycle {
    pub fn request_init(&mut self) {
        self.ready = false;
        self.pending = true;
        self.retry_at = None;
    }

    pub fn terminate(&mut self) {
        *self = Self::default();
    }

    pub fn begin_init(&mut self, now: Instant) -> bool {
        if !self.pending || self.retry_at.is_some_and(|deadline| now < deadline) {
            return false;
        }
        self.pending = false;
        true
    }

    pub fn finish_init(&mut self, succeeded: bool, now: Instant) {
        self.ready = succeeded;
        self.pending = !succeeded;
        self.retry_at = (!succeeded).then_some(now + RETRY_DELAY);
    }

    pub fn is_ready(&self) -> bool {
        self.ready
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn failed_replacement_is_not_ready_and_retries_without_another_init_event() {
        let now = Instant::now();
        let mut state = SurfaceLifecycle::default();
        state.request_init();
        assert!(state.begin_init(now));
        state.finish_init(false, now);
        assert!(!state.is_ready());
        assert!(!state.begin_init(now + RETRY_DELAY / 2));
        assert!(state.begin_init(now + RETRY_DELAY));
        state.finish_init(true, now + RETRY_DELAY);
        assert!(state.is_ready());
        assert!(!state.begin_init(now + RETRY_DELAY * 2));
    }

    #[test]
    fn terminate_cancels_queued_init_and_retry_until_a_new_window_arrives() {
        for failed in [false, true] {
            let now = Instant::now();
            let mut state = SurfaceLifecycle::default();
            state.request_init();
            if failed {
                assert!(state.begin_init(now));
                state.finish_init(false, now);
            }
            state.terminate();
            assert!(!state.is_ready());
            assert!(!state.begin_init(now + RETRY_DELAY * 2));
            state.request_init();
            assert!(state.begin_init(now + RETRY_DELAY * 2));
        }
    }

    #[test]
    fn replacement_revokes_readiness_before_work_and_a_new_window_skips_old_backoff() {
        let now = Instant::now();
        let mut state = SurfaceLifecycle::default();
        state.finish_init(true, now);
        state.request_init();
        assert!(!state.is_ready());
        assert!(state.begin_init(now));
        state.finish_init(false, now);
        state.request_init();
        assert!(state.begin_init(now));
        assert!(!state.is_ready());
    }
}
