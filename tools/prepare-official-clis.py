#!/usr/bin/env python3
"""Download, verify, and stage the optional official Android CLI binaries.

The output is an Android jniLibs directory. Files are copied byte-for-byte;
the .so names are packaging names only, allowing AGP to extract executables
into ApplicationInfo.nativeLibraryDir. This script never writes into source.
"""

import argparse
import base64
import hashlib
import json
import os
import pathlib
import shutil
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request


ROOT = pathlib.Path(__file__).resolve().parent
MANIFEST = ROOT / "official-cli-manifest.json"
REPOSITORY = ROOT.parent


def sha512(path: pathlib.Path) -> bytes:
    digest = hashlib.sha512()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.digest()


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url: str, destination: pathlib.Path) -> None:
    destination.parent.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(url, timeout=60) as source, destination.open("wb") as target:
        shutil.copyfileobj(source, target, length=1024 * 1024)


def verify_integrity(path: pathlib.Path, integrity: str) -> None:
    algorithm, encoded = integrity.split("-", 1)
    if algorithm != "sha512" or base64.b64encode(sha512(path)).decode() != encoded:
        raise SystemExit(f"integrity mismatch: {path}")


def safe_extract_tar(archive: pathlib.Path, destination: pathlib.Path) -> None:
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            target = (destination / member.name).resolve()
            if not str(target).startswith(str(destination.resolve()) + os.sep):
                raise SystemExit(f"unsafe archive path: {member.name}")
            if member.issym() or member.islnk():
                raise SystemExit(f"links are not accepted in CLI archive: {member.name}")
            if not member.isdir() and not member.isfile():
                raise SystemExit(f"special archive member is not accepted: {member.name}")
        # All paths and member types were validated above. Avoid the newer
        # `filter=` parameter so the script remains usable with Python 3.9.
        tar.extractall(destination)


def verify_aarch64_elf(path: pathlib.Path) -> None:
    with path.open("rb") as stream:
        header = stream.read(20)
    # ELF64 little endian, EM_AARCH64 (183).
    if len(header) < 20 or header[:4] != b"\x7fELF" or header[4] != 2 or header[5] != 1 or header[18:20] != b"\xb7\x00":
        raise SystemExit(f"expected unmodified aarch64 ELF: {path}")


def validate_manifest(manifest: dict) -> None:
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1 or manifest.get("target") != "linux-arm64-musl":
        raise SystemExit("unsupported CLI manifest")
    packages = manifest.get("packages")
    loader = manifest.get("musl_loader")
    if not isinstance(packages, dict) or not packages:
        raise SystemExit("CLI manifest needs packages")
    if "musl_loader" in manifest and not isinstance(loader, dict):
        raise SystemExit("invalid musl loader manifest")

    def text(record, key):
        value = record.get(key)
        if not isinstance(value, str) or not value:
            raise SystemExit(f"CLI manifest needs a nonempty {key}")
        return value

    def checksum(record, key):
        value = text(record, key)
        if len(value) != 64 or any(character not in "0123456789abcdef" for character in value):
            raise SystemExit(f"CLI manifest needs a SHA-256 {key}")

    outputs = set()
    for record in list(packages.values()) + ([loader] if loader is not None else []):
        if not isinstance(record, dict):
            raise SystemExit("invalid CLI manifest record")
        text(record, "version")
        output = text(record, "output")
        binary = pathlib.PurePosixPath(text(record, "binary"))
        if pathlib.PurePosixPath(output).name != output or not output.endswith(".so"):
            raise SystemExit("CLI output must be a .so basename")
        if output in outputs:
            raise SystemExit("duplicate CLI output name")
        outputs.add(output)
        if not binary.parts or binary.is_absolute() or ".." in binary.parts:
            raise SystemExit("CLI binary must be a relative archive path")
    for package in packages.values():
        if not isinstance(package.get("requires_musl_loader", True), bool):
            raise SystemExit("requires_musl_loader must be a boolean")
        text(package, "name")
        text(package, "tarball")
        integrity = text(package, "integrity")
        try:
            algorithm, encoded = integrity.split("-", 1)
            if algorithm != "sha512" or len(base64.b64decode(encoded, validate=True)) != 64:
                raise ValueError("expected SHA-512")
        except ValueError as error:
            raise SystemExit("CLI manifest needs a SHA-512 package integrity") from error
        if "binary_sha256" in package:
            checksum(package, "binary_sha256")
    if any(package.get("requires_musl_loader", True) for package in packages.values()) and loader is None:
        raise SystemExit("selected CLI packages require a musl loader manifest")
    if loader is not None:
        text(loader, "url")
        checksum(loader, "apk_sha256")
        checksum(loader, "loader_sha256")


def is_within(path: pathlib.Path, parent: pathlib.Path) -> bool:
    if path == parent or parent in path.parents:
        return True
    # resolve() follows symlinks but preserves case aliases on macOS. Compare
    # existing ancestors by filesystem identity even when the output is new.
    for ancestor in (path, *path.parents):
        try:
            if ancestor.samefile(parent):
                return True
        except FileNotFoundError:
            continue
    return False


def validate_output(output: pathlib.Path, manifest: dict) -> None:
    """Only replace an empty directory or a complete output owned by this tool."""
    if not output.exists():
        return
    if not output.is_dir() or output.is_symlink():
        raise SystemExit("output must be a dedicated CLI directory")
    children = {path.name for path in output.iterdir()}
    if not children:
        return
    if not children <= {"manifest.json", "arm64-v8a", ".downloads"}:
        raise SystemExit("refusing to replace output containing unrelated files")
    receipt_path = output / "manifest.json"
    abi = output / "arm64-v8a"
    if receipt_path.is_symlink() or not receipt_path.is_file() or abi.is_symlink() or not abi.is_dir():
        raise SystemExit("existing output has no valid CLI ownership manifest")
    try:
        receipt = json.loads(receipt_path.read_text())
        validate_manifest(receipt)
    except (ValueError, OSError, TypeError, AttributeError, SystemExit) as error:
        raise SystemExit("existing output has no valid CLI ownership manifest") from error
    known = manifest["packages"]
    if not set(receipt["packages"]) <= set(known) or any(
        package["output"] != known[engine]["output"]
        for engine, package in receipt["packages"].items()
    ):
        raise SystemExit("existing output is not a recognized CLI package set")
    receipt_loader = receipt.get("musl_loader")
    # Legacy receipts included this loader even for static binaries. Recognize
    # its established packaging name when the new static-only manifest omits it.
    known_loader_output = manifest.get("musl_loader", {}).get("output", "libmusl_loader.so")
    if receipt_loader is not None and receipt_loader["output"] != known_loader_output:
        raise SystemExit("existing output is not a recognized CLI loader")
    selected = receipt.get("selected_engines")
    if selected is not None and selected != sorted(receipt["packages"]):
        raise SystemExit("existing output selection differs from its packages")
    expected = {package["output"] for package in receipt["packages"].values()}
    if receipt_loader is not None:
        expected.add(receipt_loader["output"])
    if {path.name for path in abi.iterdir()} != expected or any(
        path.is_symlink() or not path.is_file() for path in abi.iterdir()
    ):
        raise SystemExit("existing output does not contain exactly its declared CLI files")
    legacy_cache = output / ".downloads"
    if legacy_cache.is_symlink() or (legacy_cache.exists() and (
        not legacy_cache.is_dir() or any(
            path.is_symlink() or not path.is_file() for path in legacy_cache.iterdir()
        )
    )):
        raise SystemExit("existing output contains an unrecognized download cache")


def migrate_legacy_cache(output: pathlib.Path, cache: pathlib.Path) -> None:
    legacy = output / ".downloads"
    if not legacy.exists():
        return
    cache.mkdir(parents=True, exist_ok=True)
    for source in legacy.iterdir():
        target = cache / source.name
        if target.is_symlink():
            raise SystemExit(f"conflicting legacy download cache entry: {source.name}")
        if target.exists():
            if not target.is_file() or sha256(source) != sha256(target):
                raise SystemExit(f"conflicting legacy download cache entry: {source.name}")
            source.unlink()
        else:
            shutil.move(str(source), str(target))
    legacy.rmdir()


def cached_archive(url: str, cache: pathlib.Path, verify) -> pathlib.Path:
    name = pathlib.PurePosixPath(urllib.parse.urlparse(url).path).name
    if not name or name in (".", ".."):
        raise SystemExit("archive URL has no filename")
    archive = cache / name
    if archive.is_symlink() or (archive.exists() and not archive.is_file()):
        raise SystemExit(f"invalid cache entry: {archive}")
    if archive.exists():
        verify(archive)
        return archive
    cache.mkdir(parents=True, exist_ok=True)
    # A failed download or checksum never becomes a reusable cache entry.
    with tempfile.TemporaryDirectory(prefix=".download-", dir=cache) as temporary:
        downloaded = pathlib.Path(temporary) / name
        download(url, downloaded)
        verify(downloaded)
        os.replace(downloaded, archive)
    return archive


def publish(staged: pathlib.Path, output: pathlib.Path, manifest: dict) -> None:
    # Check ownership again immediately before the only published-tree mutation.
    validate_output(output, manifest)
    backup = None
    if output.exists():
        backup = pathlib.Path(tempfile.mkdtemp(prefix=f".{output.name}.previous-", dir=output.parent))
        os.replace(output, backup)
    try:
        os.replace(staged, output)
    except BaseException:
        if backup is not None:
            os.replace(backup, output)
        raise
    if backup is not None:
        try:
            shutil.rmtree(backup)
        except OSError as error:
            # The complete new tree is already published; retain the backup on
            # cleanup failure rather than report an ambiguous failed preparation.
            print(f"warning: old CLI output retained at {backup}: {error}", file=sys.stderr)


def main(argv=None) -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=pathlib.Path, required=True, help="dedicated jniLibs root outside source")
    parser.add_argument("--engine", action="append", required=True, help="engine to prepare; repeat to explicitly select several")
    parser.add_argument("--cache", type=pathlib.Path, help="download cache (default: adjacent <output-name>.downloads)")
    parser.add_argument("--manifest", type=pathlib.Path, default=MANIFEST)
    args = parser.parse_args(argv)
    manifest = json.loads(args.manifest.read_text())
    validate_manifest(manifest)
    selected = sorted(set(args.engine))
    unknown = set(selected) - set(manifest["packages"])
    if unknown:
        parser.error(f"unknown engine(s): {', '.join(sorted(unknown))}")
    if args.output.is_symlink():
        raise SystemExit("output may not be a symlink")
    output = args.output.resolve()
    cache_path = args.cache or output.with_name(output.name + ".downloads")
    if cache_path.is_symlink():
        raise SystemExit("cache may not be a symlink")
    cache = cache_path.resolve()
    if cache.exists() and not cache.is_dir():
        raise SystemExit("cache must be a directory")
    if is_within(output, REPOSITORY) or is_within(cache, REPOSITORY):
        raise SystemExit("CLI output and cache must be outside the source checkout")
    if is_within(cache, output) or is_within(output, cache):
        raise SystemExit("CLI output and cache must be separate directories")
    validate_output(output, manifest)
    migrate_legacy_cache(output, cache)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=f".{output.name}.prepare-", dir=output.parent) as temporary:
        staging = pathlib.Path(temporary)
        prepared = staging / "prepared"
        abi = prepared / "arm64-v8a"
        abi.mkdir(parents=True)
        receipt = {key: manifest[key] for key in ("schema_version", "target")}
        receipt.update(selected_engines=selected, packages={})
        for index, engine in enumerate(selected):
            package = manifest["packages"][engine]
            archive = cached_archive(
                package["tarball"], cache,
                lambda path: verify_integrity(path, package["integrity"]),
            )
            extracted = staging / f"package-{index}"
            safe_extract_tar(archive, extracted)
            source = extracted / package["binary"]
            verify_aarch64_elf(source)
            binary_hash = sha256(source)
            if "binary_sha256" in package and package["binary_sha256"] != binary_hash:
                raise SystemExit(f"binary checksum mismatch: {source}")
            shutil.copyfile(source, abi / package["output"])
            os.chmod(abi / package["output"], 0o755)
            receipt["packages"][engine] = dict(package, binary_sha256=binary_hash)

        if any(package.get("requires_musl_loader", True) for package in receipt["packages"].values()):
            loader = manifest["musl_loader"]
            def verify_apk(path):
                if sha256(path) != loader["apk_sha256"]:
                    raise SystemExit(f"checksum mismatch: {path}")
            apk = cached_archive(loader["url"], cache, verify_apk)
            # Read only the regular loader member; never extract APK symlinks.
            source = staging / "ld-musl-aarch64.so.1"
            with tarfile.open(apk) as package:
                member = package.getmember(loader["binary"])
                if not member.isfile():
                    raise SystemExit(f"loader is not a regular APK member: {loader['binary']}")
                extracted = package.extractfile(member)
                if extracted is None:
                    raise SystemExit(f"loader could not be read: {loader['binary']}")
                with source.open("wb") as target:
                    shutil.copyfileobj(extracted, target, length=1024 * 1024)
            if sha256(source) != loader["loader_sha256"]:
                raise SystemExit(f"loader checksum mismatch: {source}")
            verify_aarch64_elf(source)
            shutil.copyfile(source, abi / loader["output"])
            os.chmod(abi / loader["output"], 0o755)
            receipt["musl_loader"] = loader

        (prepared / "manifest.json").write_text(json.dumps(receipt, indent=2) + "\n")
        publish(prepared, output, manifest)
    print(output)


if __name__ == "__main__":
    main()
