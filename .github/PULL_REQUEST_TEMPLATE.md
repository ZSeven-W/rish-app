## What changed?

<!-- Describe the concrete problem and resulting behavior. -->

## Validation

<!-- List the checks actually run and their results. Explain any skipped checks. -->

- [ ] `node scripts/verify-source-checkout.mjs`
- [ ] `apps/gpui/scripts/check.sh core`
- [ ] `apps/gpui/scripts/check.sh desktop`
- [ ] `cargo test --locked --manifest-path apps/gpui/Cargo.toml --lib`

<!-- For native changes, include the relevant iOS/Android host checks and the
     simulator/device, binary, and interaction tested. Compilation alone does
     not establish native runtime or provider acceptance. -->

## Limits

<!-- Note remaining platform coverage, native artifact prerequisites, or
     migration gaps that matter for this change. -->
