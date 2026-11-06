# Codex probe input regression tests

`codex-probe-inputs.groovy` compiles the real read-only validator from
`app/codex-probe.gradle`. Its 20 cases use a synthetic, non-executed ELF header and
temporary canonical manifests, so the tests do not depend on a downloaded Codex
package or the current production binary pin. Rejections must match their expected
failure reason. The case-alias regression is explicitly skipped on case-sensitive
filesystems. Fixtures are removed after the run.

From the repository root, with JDK 17 and this project's Gradle wrapper already
cached, run:

```sh
python3 - <<'PY'
import os
from pathlib import Path
import re
import shutil
import subprocess

repo = Path.cwd()
android = repo / "apps/gpui/android"
properties = (android / "gradle/wrapper/gradle-wrapper.properties").read_text()
match = re.search(r"gradle-([^/]+)-(bin|all)\.zip", properties)
if not match:
    raise SystemExit("Cannot identify the pinned Gradle wrapper distribution")
version, kind = match.groups()
cache = Path(os.environ.get("GRADLE_USER_HOME", str(Path.home() / ".gradle")))
libraries = sorted((cache / "wrapper/dists" / f"gradle-{version}-{kind}")
                   .glob(f"*/gradle-{version}/lib"))
if not libraries:
    raise SystemExit("Pinned Gradle wrapper is not cached; use the normal Android setup first")
java = str(Path(os.environ["JAVA_HOME"]) / "bin/java") if os.environ.get("JAVA_HOME") else shutil.which("java")
if not java:
    raise SystemExit("JDK 17 is required")
subprocess.run([java, "-cp", str(libraries[0] / "*"), "groovy.ui.GroovyMain",
                str(android / "tests/codex-probe-inputs.groovy"), str(repo)], check=True)
PY
```

This uses only the wrapper's cached Groovy libraries. It does not invoke Gradle,
install dependencies, download packages, build APKs, or execute any CLI binary.
It checks input validation; debug/release packaging still needs Gradle and APK
inspection in the Android build checks.
