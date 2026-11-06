# Android Codex offline probe · 2026-11-06

Base commit: `e46ad3407d527ea26e5793398b501f421aa2602d`. This batch establishes a
bounded development capability check, not a downloadable runtime or task adapter.
Pi remains the only embedded task execution engine. No shared Rust or iOS code
changed, and their earlier test results are not claimed as rerun here.

## Reproducible single-engine preparation

`tools/prepare-official-clis.py` now requires explicit, repeatable `--engine`.
It validates archive SHA-512, AArch64 ELF identity and a pinned binary SHA-256,
then atomically publishes a dedicated directory outside the source checkout.
The receipt contains only selected engines and required dependencies. Downloads
are cached beside the prepared directory; partial or invalid archives never
become reusable cache entries. Legacy owned output/cache directories can migrate,
while unrelated files, symlinks and archive traversal are rejected.

The actual official npm input is `@openai/codex@0.153.4-linux-arm64`:

| Input | Observed value |
| --- | --- |
| Archive | 121,707,000 bytes; SHA-512 matches `tools/official-cli-manifest.json` |
| Executable | 222,567,456 bytes; ELF64 little-endian AArch64 |
| Binary SHA-256 | `4d76e542c222ea8c75861d8c4ade60a1a332a63255ce1c60bdaebf7c2a2869e6` |
| Dynamic dependencies | No `PT_INTERP` or `PT_DYNAMIC`; static binary |

The old pinned Alpine musl URL returned HTTP 404. Codex does not require that
loader, so selecting Codex neither requests nor packages it. The dependent
engine's old loader descriptor remains unverified/blocked; this batch does not
substitute another version or claim that path works. No Claude download, process,
authentication or service request was performed.

## Development packaging and execution boundary

Only explicit `-PrishCodexProbeDir=<prepared-root>` enables the debug probe.
Gradle checks exact package metadata against the canonical manifest, SHA-256,
ABI, the sole `libcodex.so` output and the absence of extra files or symlinks.
It preserves the original executable bytes when packaging. The receipt is a
generated build asset, never source data. The service is internal/nonexported.

Ordinary debug has neither CLI nor receipt and disables the service. Release
omits both artifacts and the service registration even with the property set.
Switching back to ordinary debug after an enabled build is checked for stale
asset/native-library leakage.

The only accepted commands are `codex --version` and `codex app-server --help`.
Each request gets a new empty HOME/CODEX_HOME/XDG/TMP tree; inherited environment
and stdin are removed. Output is capped at 8,192 characters per command, execution
at 15 seconds, and cancellation terminates the child before cleanup. Correlated
atomic receipts cannot be overwritten by an in-flight duplicate request. Service
recreation retains process-wide worker ownership until teardown finishes.

An existing production gap was fixed: the subscription process factory had
treated a packaged executable as permission to run account commands. It now
checks `RISH_OFFICIAL_CLI_ENABLED` before availability, vault restoration and
direct process start. Probe bytes do not enable authentication. Fake factories
remain injectable for the existing tests.

## Observed Android result

On a task-owned read-only Pixel XL API 33 arm64 emulator, airplane mode was on
and Android reported no active default network. The installed app ran the two
commands under UID **10163**, PID **4792**. Both returned exit code **0** in about
105 ms each; the version was `codex-cli 0.153.4`. The installed executable hash
matched the verified input. The enabled-lane test also proved that production
authentication remained unavailable, including direct start rejection before
an authentication home could be created.

The receipt records `capability=available` for these two offline commands and
`execution=unavailable / cli_adapter_unavailable`. It does not start app-server,
initialize its protocol, load an account, call a model or run a task. Physical
devices and other Android versions remain untested. The
[official app-server lifecycle](https://learn.chatgpt.com/docs/app-server) still
needs a separate shared task/tool/approval/cancellation integration.

After the test, no Codex child process, temporary probe home or receipt remained
on the fixture. Test cleanup waits for worker teardown before removing receipts.

## Checks and evidence

- Android JVM tests: **122 passed**, zero failures/errors/skips; 10 new probe
  cases use fake processes, including timeout, cancellation and output limits.
- App-UID enabled probe plus authentication-disabled check: **2 passed**.
- Ordinary-package authentication-disabled check: **1 passed** before the probe.
- Pure Gradle input validator: **20 passed**, including byte tampering, missing
  pins, extra engines/loader, symlinks and macOS case aliases.
- Python preparation regression: **24 passed**, including conditional dependency
  downloads, atomic failure preservation, archive integrity and case aliases.
- Source archive/preflight: **25 passed**.
- Debug, test and unsigned release APKs built. Release was built with the probe
  property set and independently inspected to prove exclusion.
- Restored ordinary debug, including its compact repack, passed the same
  authentication-disabled device check; APK inspection found no CLI/receipt and
  confirmed that the probe service was disabled.

Detailed logs and the final normal-package receipt are recorded in the local
evidence directory below. Reproduction for the app-UID lane is in the
[Android README](../apps/gpui/README.md#android); pure packaging regression commands
are in [the test README](../apps/gpui/android/tests/README.md). Preparation tests:

```sh
python3 -m unittest discover -s tools/tests -p 'test_prepare_official_clis.py' -v
```

| Artifact observed during validation | Bytes | SHA-256 |
| --- | ---: | --- |
| Probe debug APK | 157830045 | `16d87c74149216bf7f979948d3e4f9cd9f9491b0b46ad7692b859d296cd19661` |
| Probe test APK | 1870729 | `a9f6db4ccee5d8b3460051795aa5b25efa30014caa3e687cc77cf8fa157ce46d` |
| Unsigned release with probe property | 28846256 | `0bd8011b2470362417592da248502416a7767eace33ca0978cf282d58cba2fb9` |
| Final ordinary debug APK | 32688724 | `f16eed31063b1f5f3a84c837507641bf86b39c88778c8a532a4bac9e9fd96a36` |
| Final ordinary test APK | 1870729 | `a9d786c362d8bdb9f5d662e08d23aa40aadd0c2098160d015b078f1436efb006` |

Evidence lives at `../output/rish-p0-codex-probe-20261106/`: input verification,
device receipt, network state, manifests, variant hashes and build/test logs.
The probe APK is replaced by the final normal build rather than copied into an
extra artifact directory. The verified archive/prepared executable are retained
for reuse; temporary range downloads and extraction trees are removed. Existing
native libraries and Cargo targets were reused without a Rust rebuild.
Repacking only the ordinary APK removed 26,683,810 bytes of unused incremental
archive space (59,372,534 → 32,688,724 bytes) with unchanged source and reused
native libraries. The task-owned emulator was stopped after QA.
