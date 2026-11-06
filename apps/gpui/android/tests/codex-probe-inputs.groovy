import groovy.json.JsonOutput
import groovy.json.JsonSlurper
import java.nio.file.Files
import java.security.MessageDigest

// Run with the Groovy jars already included in the cached Gradle wrapper;
// see README.md beside this file. No Gradle tasks or CLI executables run.
assert args.length == 1 : "Usage: codex-probe-inputs.groovy <repository-root>"
File sourceRepository = new File(args[0]).canonicalFile
File helper = new File(sourceRepository, "apps/gpui/android/app/codex-probe.gradle")
assert helper.isFile() : "Cannot find ${helper}"
String source = helper.getText("UTF-8")
String boundary = "// Keep all variant wiring below the validator"
assert source.count(boundary) == 1 : "The validator/Gradle boundary must remain explicit"
def loader = new GroovyClassLoader(getClass().classLoader)
loader.parseClass(source.substring(0, source.indexOf(boundary)))
Class validator = loader.loadClass("CodexProbeInputs")

// This 64-byte synthetic ELF header is never executed. Its independently fixed
// digest makes byte corruption distinguishable from an unsupported architecture.
byte[] arm64Elf = ("7f454c46020101000000000000000000" +
    "0200b700010000000000000000000000" +
    "00000000000000000000000000000000" +
    "00000000000000000000000000000000").decodeHex()
String fixtureSha256 = "33c7deae2cc9a60b11ec6bd7a4d96b0c360cc19026914a20ba204466182d308f"
def sha256 = { byte[] bytes ->
    MessageDigest.getInstance("SHA-256").digest(bytes).encodeHex().toString()
}
assert arm64Elf.length == 64 && sha256(arm64Elf) == fixtureSha256

// Canonicalize the temporary root: macOS commonly exposes its temp directory
// through /var -> /private/var, which is intentionally rejected by the validator.
File temporary = Files.createTempDirectory("rish-codex-probe-test-").toRealPath().toFile()
File fixtureRepository = new File(temporary, "checkout")
assert fixtureRepository.mkdir()
int passed = 0
int skipped = 0

def fixture = { String name ->
    File prepared = new File(temporary, name)
    assert new File(prepared, "arm64-v8a").mkdirs()
    new File(prepared, "arm64-v8a/libcodex.so").bytes = arm64Elf
    Map canonical = [
        schema_version: 1,
        target: "linux-arm64-musl",
        packages: [codex: [
            name: "@openai/codex",
            version: "fixture-pinned-version",
            tarball: "https://example.invalid/never-downloaded.tgz",
            binary: "package/vendor/aarch64-unknown-linux-musl/bin/codex",
            output: "libcodex.so",
            requires_musl_loader: false,
            binary_sha256: fixtureSha256,
        ]],
    ]
    Map receipt = new JsonSlurper().parseText(JsonOutput.toJson(canonical))
    receipt.selected_engines = ["codex"]
    [directory: prepared, repository: fixtureRepository,
        canonicalFile: new File(fixtureRepository, "${name}-canonical.json"),
        canonical: canonical, receipt: receipt, abis: ["arm64-v8a"]]
}

def writeManifests = { state ->
    state.canonicalFile.setText(JsonOutput.toJson(state.canonical), "UTF-8")
    new File(state.directory, "manifest.json").setText(JsonOutput.toJson(state.receipt), "UTF-8")
}
def validate = { state ->
    validator.validate(state.directory, state.repository, state.canonicalFile, state.abis)
}
def reject = { String name, String expectedReason, Closure mutate ->
    def state = fixture(name)
    mutate(state)
    writeManifests(state)
    IllegalArgumentException rejection = null
    try {
        validate(state)
    } catch (IllegalArgumentException error) {
        rejection = error
    }
    assert rejection != null : "${name}: unexpectedly accepted"
    assert rejection.message.contains(expectedReason) :
        "${name}: rejected for the wrong reason: ${rejection.message}"
    passed++
    println "PASS ${name}"
}

try {
    def valid = fixture("valid-static-codex")
    writeManifests(valid)
    assert validate(valid) == valid.receipt
    assert sha256(new File(valid.directory, "arm64-v8a/libcodex.so").bytes) == fixtureSha256
    passed++
    println "PASS valid-static-codex"

    reject("multiple-abis", "requires exactly the arm64-v8a ABI") {
        it.abis = ["arm64-v8a", "x86_64"]
    }
    reject("prepared-inside-checkout", "must be outside the repository") {
        it.repository = temporary
    }
    reject("extra-selected-engine", "only the Codex engine is accepted") {
        it.receipt.selected_engines += "other-engine"
    }
    reject("extra-package", "only the Codex engine is accepted") {
        it.receipt.packages["other-engine"] = [:]
    }
    reject("metadata-drift", "Codex metadata does not match") {
        it.receipt.packages.codex.version = "unreviewed-version"
    }
    reject("unexpected-loader-metadata", "unexpected manifest fields") {
        it.receipt.musl_loader = [version: "unexpected-loader"]
    }
    reject("missing-canonical-pin", "canonical SHA-256 is missing or invalid") {
        // Matching receipt metadata must not make a missing trust anchor valid.
        it.canonical.packages.codex.remove("binary_sha256")
        it.receipt.packages.codex.remove("binary_sha256")
    }
    reject("binary-corruption", "SHA-256 mismatch") {
        new File(it.directory, "arm64-v8a/libcodex.so").append("corruption", "UTF-8")
    }
    reject("unexpected-loader-binary", "unexpected directory entries") {
        new File(it.directory, "arm64-v8a/libmusl_loader.so").bytes = arm64Elf
    }
    reject("extra-binary", "unexpected directory entries") {
        new File(it.directory, "arm64-v8a/libextra.so").bytes = arm64Elf
    }
    reject("download-cache-inside-inputs", "unexpected directory entries") {
        assert new File(it.directory, ".downloads").mkdir()
    }
    reject("extra-abi-directory", "unexpected directory entries") {
        assert new File(it.directory, "x86_64").mkdir()
    }
    reject("unknown-receipt-field", "unexpected manifest fields") {
        it.receipt.unreviewed_field = true
    }
    reject("symlink-binary", "symbolic links are not accepted") { state ->
        File target = new File(temporary, "binary-link-target")
        target.bytes = arm64Elf
        def link = new File(state.directory, "arm64-v8a/libcodex.so").toPath()
        Files.delete(link)
        Files.createSymbolicLink(link, target.toPath())
    }
    reject("symlink-input-root", "symbolic links are not accepted") { state ->
        def link = new File(temporary, "linked-input-root").toPath()
        Files.createSymbolicLink(link, state.directory.toPath())
        state.directory = link.toFile()
    }
    reject("pinned-wrong-machine", "expected an ELF64 little-endian AArch64 binary") { state ->
        // Repin a well-formed x86-64 header so this fails on architecture, not SHA.
        byte[] x86Elf = Arrays.copyOf(arm64Elf, arm64Elf.length)
        x86Elf[18] = 62
        new File(state.directory, "arm64-v8a/libcodex.so").bytes = x86Elf
        state.canonical.packages.codex.binary_sha256 = sha256(x86Elf)
        state.receipt.packages.codex.binary_sha256 = sha256(x86Elf)
    }
    reject("dynamic-codex-contract", "requires the pinned static binary") {
        it.canonical.packages.codex.requires_musl_loader = true
        it.receipt.packages.codex.requires_musl_loader = true
    }
    reject("unspecified-loader-contract", "requires the pinned static binary") {
        it.canonical.packages.codex.remove("requires_musl_loader")
        it.receipt.packages.codex.remove("requires_musl_loader")
    }

    // Case aliases are an actual macOS bypass regression, not a portable fake:
    // exercise them only when this filesystem resolves both names to one inode.
    File caseAlias = new File(temporary, "CHECKOUT")
    if (caseAlias.exists() && Files.isSameFile(caseAlias.toPath(), fixtureRepository.toPath())) {
        reject("checkout-case-alias", "must be outside the repository") { state ->
            File nested = new File(fixtureRepository, "aliased-inputs")
            Files.move(state.directory.toPath(), nested.toPath())
            state.directory = new File(caseAlias, nested.name)
        }
    } else {
        skipped++
        println "SKIP checkout-case-alias (case-sensitive filesystem)"
    }
    assert passed + skipped == 20
    println "RESULT: ${passed} passed, ${skipped} skipped"
} finally {
    // Files.walk does not follow symlinks; remove only our unique fixture tree.
    Files.walk(temporary.toPath()).withCloseable { paths ->
        paths.sorted(Comparator.reverseOrder()).forEach { Files.delete(it) }
    }
    loader.close()
}
