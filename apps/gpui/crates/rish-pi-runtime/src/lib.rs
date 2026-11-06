//! Real Pi Agent Core running in a bounded, no-JIT QuickJS interpreter.
//! Native Rish retains transcript contents and sole effect authority. Pi
//! schedules model calls and opaque tool capabilities, never filesystem IO.
mod spec;
pub use spec::*;
#[cfg(feature = "engine")]
mod engine;
#[cfg(feature = "engine")]
pub use engine::*;
