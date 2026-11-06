# Retired `web_proxy` baseline

This directory holds the original Swift/WebKit shell that Rish started from.
It loaded a DSH host over `http://127.0.0.1:3180/` and rendered it in a
`WKWebView`; nothing on the phone ran locally.

It is kept for provenance only:

- no target builds it, no script references it, and no test covers it;
- `run-simulator.sh` builds and launches the GPUI app instead;
- the shipping app lives in `apps/gpui`, with the native runtime in
  `modules/rish`.

The `web_proxy` row in the [runtime boundary table](../../docs/development.md#honest-runtime-boundary)
describes the mode this code implemented, not a current capability.
