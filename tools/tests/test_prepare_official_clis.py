#!/usr/bin/env python3
"""Offline behavior tests for explicit CLI package preparation (Python 3.9)."""

import base64
import contextlib
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "prepare-official-clis.py"
SPEC = importlib.util.spec_from_file_location("prepare_official_clis", SCRIPT)
prepare = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(prepare)


def elf_bytes(label):
    header = bytearray(64)
    header[:6] = b"\x7fELF\x02\x01"
    header[18:20] = b"\xb7\x00"
    return bytes(header) + label.encode("ascii")


def write_archive(path, member_name, data):
    with tarfile.open(path, "w:gz") as archive:
        member = tarfile.TarInfo(member_name)
        member.size = len(data)
        member.mode = 0o755
        archive.addfile(member, io.BytesIO(data))


def integrity(path):
    return "sha512-" + base64.b64encode(hashlib.sha512(path.read_bytes()).digest()).decode()


def file_contents(directory):
    return {
        str(path.relative_to(directory)): path.read_bytes()
        for path in directory.rglob("*")
        if path.is_file()
    }


class OfficialCliPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="rish-cli-tests-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.output = self.root / "published"
        self.cache = self.root / "cache"
        self.manifest_path = self.root / "input-manifest.json"
        self.downloads = {}
        self.binaries = {}
        self.manifest = {
            "schema_version": 1,
            "target": "linux-arm64-musl",
            "packages": {},
        }
        for engine, output_name in [
            ("codex", "libcodex.so"),
            ("claude-code", "libclaude_code.so"),
        ]:
            data = elf_bytes(engine)
            archive = self.root / (engine + ".tgz")
            binary = "package/bin/" + engine
            write_archive(archive, binary, data)
            url = "https://downloads.invalid/" + archive.name
            self.downloads[url] = archive
            self.binaries[output_name] = data
            self.manifest["packages"][engine] = {
                "name": "@fixture/" + engine,
                "version": "1.0.0",
                "tarball": url,
                "integrity": integrity(archive),
                "binary": binary,
                "output": output_name,
                "requires_musl_loader": engine == "claude-code",
            }
        self.loader_bytes = elf_bytes("musl-loader")
        loader_archive = self.root / "musl.apk"
        write_archive(loader_archive, "lib/ld-musl-aarch64.so.1", self.loader_bytes)
        loader_url = "https://downloads.invalid/musl.apk"
        self.downloads[loader_url] = loader_archive
        self.manifest["musl_loader"] = {
            "version": "1.0.0",
            "url": loader_url,
            "apk_sha256": hashlib.sha256(loader_archive.read_bytes()).hexdigest(),
            "loader_sha256": hashlib.sha256(self.loader_bytes).hexdigest(),
            "binary": "lib/ld-musl-aarch64.so.1",
            "output": "libmusl_loader.so",
        }
        self.write_manifest()
        self.requested_urls = []
        self.network = mock.patch.object(
            prepare.urllib.request, "urlopen", side_effect=AssertionError("real network forbidden")
        )
        self.network.start()
        self.addCleanup(self.network.stop)
        self.download_mock = mock.patch.object(prepare, "download", side_effect=self.fake_download)
        self.download_mock.start()
        self.addCleanup(self.download_mock.stop)

    def write_manifest(self):
        self.manifest_path.write_text(json.dumps(self.manifest))

    def fake_download(self, url, destination):
        self.requested_urls.append(url)
        self.assertIn(url, self.downloads, "unexpected package download")
        destination = Path(destination)
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(self.downloads[url], destination)

    def invoke(self, engines=("codex",), output=None, cache=None, use_default_cache=False):
        args = ["--output", str(output or self.output), "--manifest", str(self.manifest_path)]
        if not use_default_cache:
            args.extend(["--cache", str(cache or self.cache)])
        for engine in engines:
            args.extend(["--engine", engine])
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            prepare.main(args)

    def seed_previous_output(self):
        abi = self.output / "arm64-v8a"
        abi.mkdir(parents=True)
        (abi / "libclaude_code.so").write_bytes(self.binaries["libclaude_code.so"])
        (abi / "libmusl_loader.so").write_bytes(self.loader_bytes)
        previous = dict(self.manifest)
        previous["selected_engines"] = ["claude-code"]
        previous["packages"] = {"claude-code": self.manifest["packages"]["claude-code"]}
        (self.output / "manifest.json").write_text(json.dumps(previous))
        return file_contents(self.output)

    def assert_codex_bundle(self):
        files = file_contents(self.output)
        self.assertEqual(
            set(files),
            {"manifest.json", "arm64-v8a/libcodex.so"},
        )
        self.assertEqual(files["arm64-v8a/libcodex.so"], self.binaries["libcodex.so"])
        manifest = json.loads(files["manifest.json"])
        self.assertEqual(manifest["schema_version"], 1)
        self.assertEqual(manifest["target"], "linux-arm64-musl")
        self.assertEqual(manifest["selected_engines"], ["codex"])
        expected_package = dict(self.manifest["packages"]["codex"])
        expected_package["binary_sha256"] = hashlib.sha256(self.binaries["libcodex.so"]).hexdigest()
        self.assertEqual(manifest["packages"], {"codex": expected_package})
        self.assertNotIn("musl_loader", manifest)
        for binary in (self.output / "arm64-v8a").iterdir():
            self.assertEqual(binary.stat().st_mode & 0o777, 0o755)

    def test_missing_and_unknown_engine_are_rejected_before_download(self):
        for engines in [(), ("not-an-engine",), ("codex", "not-an-engine")]:
            with self.subTest(engines=engines), self.assertRaises(SystemExit):
                self.invoke(engines)
            self.assertEqual(self.requested_urls, [])
            self.assertFalse(self.output.exists())

    def test_codex_only_downloads_and_publishes_codex_without_loader(self):
        self.invoke()
        self.assertEqual(
            set(self.requested_urls),
            {self.manifest["packages"]["codex"]["tarball"]},
        )
        self.assertEqual(len(self.requested_urls), 1)
        self.assert_codex_bundle()

    def test_duplicate_selection_is_deduplicated(self):
        self.invoke(("codex", "codex"))
        self.assertEqual(len(self.requested_urls), 1)
        self.assert_codex_bundle()

    def test_static_manifest_can_omit_loader_entirely(self):
        self.manifest["packages"] = {"codex": self.manifest["packages"]["codex"]}
        del self.manifest["musl_loader"]
        self.write_manifest()
        self.invoke()
        self.assert_codex_bundle()
        self.assertEqual(self.requested_urls, [self.manifest["packages"]["codex"]["tarball"]])

    def test_legacy_manifest_without_loader_flag_still_requires_loader(self):
        for package in self.manifest["packages"].values():
            del package["requires_musl_loader"]
        self.write_manifest()
        # The previous receipt also has no flag, exercising replacement of an
        # older published bundle as well as preparation from an older source.
        self.seed_previous_output()
        self.invoke()
        self.assertEqual(
            set(self.requested_urls),
            {self.manifest["packages"]["codex"]["tarball"], self.manifest["musl_loader"]["url"]},
        )
        self.assertEqual(
            set(file_contents(self.output)),
            {"manifest.json", "arm64-v8a/libcodex.so", "arm64-v8a/libmusl_loader.so"},
        )
        receipt = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(receipt["musl_loader"], self.manifest["musl_loader"])
        self.assertEqual((self.output / "arm64-v8a/libmusl_loader.so").read_bytes(), self.loader_bytes)

    def test_required_or_legacy_loader_cannot_be_missing(self):
        package = self.manifest["packages"]["claude-code"]
        self.manifest["packages"] = {"claude-code": package}
        del self.manifest["musl_loader"]
        for requirement in [True, None]:
            with self.subTest(requirement=requirement):
                if requirement is None:
                    del package["requires_musl_loader"]
                self.write_manifest()
                with self.assertRaises(SystemExit):
                    self.invoke(("claude-code",))
                self.assertEqual(self.requested_urls, [])
                self.assertFalse(self.output.exists())

    def test_both_engines_require_explicit_selection(self):
        self.invoke(("codex", "claude-code"))
        manifest = json.loads((self.output / "manifest.json").read_text())
        self.assertEqual(manifest["selected_engines"], ["claude-code", "codex"])
        expected = {}
        for engine, package in self.manifest["packages"].items():
            expected[engine] = dict(package)
            expected[engine]["binary_sha256"] = hashlib.sha256(
                self.binaries[package["output"]]
            ).hexdigest()
        self.assertEqual(manifest["packages"], expected)
        self.assertEqual(set(self.requested_urls), set(self.downloads))
        self.assertEqual(
            {p.name for p in (self.output / "arm64-v8a").iterdir()},
            {"libcodex.so", "libclaude_code.so", "libmusl_loader.so"},
        )

    def test_replacing_output_removes_unselected_old_binary(self):
        self.seed_previous_output()
        self.invoke()
        self.assert_codex_bundle()

    def test_unowned_output_is_rejected_without_changing_files(self):
        self.output.mkdir()
        (self.output / "unrelated.txt").write_bytes(b"must not be replaced")
        before = file_contents(self.output)
        with self.assertRaises(SystemExit):
            self.invoke()
        self.assertEqual(file_contents(self.output), before)
        self.assertEqual(self.requested_urls, [])

    def test_owned_output_with_unknown_file_or_directory_is_rejected(self):
        before = self.seed_previous_output()
        for relative in ["notes.txt", "arm64-v8a/unrelated.so", "unknown-directory/note"]:
            with self.subTest(relative=relative):
                extra = self.output / relative
                extra.parent.mkdir(parents=True, exist_ok=True)
                extra.write_bytes(b"must not be deleted")
                contaminated = file_contents(self.output)
                with self.assertRaises(SystemExit):
                    self.invoke()
                self.assertEqual(file_contents(self.output), contaminated)
                self.assertEqual(self.requested_urls, [])
                extra.unlink()
                if relative.startswith("unknown-directory/"):
                    extra.parent.rmdir()
        self.assertEqual(file_contents(self.output), before)

    def test_incomplete_ownership_receipt_is_rejected_without_changing_output(self):
        self.seed_previous_output()
        receipt_path = self.output / "manifest.json"
        original = receipt_path.read_text()
        for record, field in [
            ("package", "integrity"),
            ("package", "name"),
            ("package", "version"),
            ("loader", "loader_sha256"),
        ]:
            with self.subTest(record=record, field=field):
                receipt = json.loads(original)
                if record == "package":
                    del receipt["packages"]["claude-code"][field]
                else:
                    del receipt["musl_loader"][field]
                receipt_path.write_text(json.dumps(receipt))
                before = file_contents(self.output)
                with self.assertRaises(SystemExit):
                    self.invoke()
                self.assertEqual(file_contents(self.output), before)
                self.assertEqual(self.requested_urls, [])
        receipt_path.write_text(original)

    def test_legacy_download_cache_migrates_and_prevents_redownload(self):
        self.seed_previous_output()
        legacy = self.output / ".downloads"
        legacy.mkdir()
        for archive in self.downloads.values():
            shutil.copyfile(archive, legacy / archive.name)
        self.invoke(use_default_cache=True)
        self.assertEqual(self.requested_urls, [])
        self.assert_codex_bundle()
        migrated = self.output.with_name(self.output.name + ".downloads")
        self.assertEqual(
            {path.name for path in migrated.iterdir()},
            {archive.name for archive in self.downloads.values()},
        )

    def test_legacy_cache_dangling_symlinks_are_rejected_before_any_move(self):
        self.seed_previous_output()
        legacy = self.output / ".downloads"
        archive = self.downloads[self.manifest["packages"]["codex"]["tarball"]]
        for location in ["destination-entry", "legacy-directory"]:
            with self.subTest(location=location):
                outside = self.root / ("outside-cache-" + location)
                if location == "destination-entry":
                    legacy.mkdir()
                    shutil.copyfile(archive, legacy / archive.name)
                    self.cache.mkdir()
                    link = self.cache / archive.name
                    link.symlink_to(outside)
                else:
                    link = legacy
                    link.symlink_to(outside, target_is_directory=True)
                before = file_contents(self.output)
                self.assertFalse(outside.exists())
                with mock.patch.object(prepare.shutil, "move") as move:
                    with self.assertRaises(SystemExit):
                        self.invoke()
                    move.assert_not_called()
                self.assertEqual(file_contents(self.output), before)
                self.assertTrue(link.is_symlink())
                self.assertEqual(link.readlink(), outside)
                self.assertFalse(outside.exists())
                self.assertEqual(self.requested_urls, [])
                if legacy.is_symlink():
                    legacy.unlink()
                else:
                    shutil.rmtree(legacy)
                shutil.rmtree(self.cache, ignore_errors=True)

    def test_integrity_failure_preserves_previous_output(self):
        before = self.seed_previous_output()
        self.manifest["packages"]["codex"]["integrity"] = "sha512-incorrect"
        self.write_manifest()
        with self.assertRaises(SystemExit):
            self.invoke()
        self.assertEqual(file_contents(self.output), before)
        self.assertNotIn(self.manifest["musl_loader"]["url"], self.requested_urls)

    def test_binary_hash_pin_is_enforced_after_archive_integrity(self):
        before = self.seed_previous_output()
        package = self.manifest["packages"]["codex"]
        with self.subTest(pin="incorrect"):
            package["binary_sha256"] = "0" * 64
            self.write_manifest()
            with self.assertRaises(SystemExit):
                self.invoke()
            self.assertEqual(file_contents(self.output), before)
            self.assertEqual(self.requested_urls, [package["tarball"]])
            self.assertNotIn(self.manifest["musl_loader"]["url"], self.requested_urls)
        with self.subTest(pin="correct"):
            package["binary_sha256"] = hashlib.sha256(self.binaries["libcodex.so"]).hexdigest()
            self.write_manifest()
            self.invoke()
            self.assert_codex_bundle()
            receipt = json.loads((self.output / "manifest.json").read_text())
            self.assertEqual(
                receipt["packages"]["codex"]["binary_sha256"], package["binary_sha256"]
            )

    def test_wrong_architecture_preserves_previous_output(self):
        before = self.seed_previous_output()
        package = self.manifest["packages"]["codex"]
        archive = self.downloads[package["tarball"]]
        invalid = bytearray(elf_bytes("x86-64"))
        invalid[18:20] = b"\x3e\x00"
        write_archive(archive, package["binary"], bytes(invalid))
        package["integrity"] = integrity(archive)
        self.write_manifest()
        with self.assertRaises(SystemExit):
            self.invoke()
        self.assertEqual(file_contents(self.output), before)

    def test_loader_hash_failure_preserves_previous_output(self):
        before = self.seed_previous_output()
        self.manifest["musl_loader"]["loader_sha256"] = "0" * 64
        self.write_manifest()
        with self.assertRaises(SystemExit):
            self.invoke(("claude-code",))
        self.assertEqual(file_contents(self.output), before)

    def test_publication_rename_failure_restores_previous_output(self):
        before = self.seed_previous_output()
        failure = {"injected": False}

        def fail_publication_once(real_rename):
            def rename(source, destination, *args, **kwargs):
                if Path(destination).resolve() == self.output.resolve() and not failure["injected"]:
                    failure["injected"] = True
                    raise OSError("simulated publication rename failure")
                return real_rename(source, destination, *args, **kwargs)
            return rename

        # Both POSIX rename APIs can implement directory publication. Fail only
        # the new tree's rename; allow a subsequent old-tree rollback to run.
        with mock.patch.object(prepare.os, "replace", side_effect=fail_publication_once(os.replace)), \
                mock.patch.object(prepare.os, "rename", side_effect=fail_publication_once(os.rename)):
            with self.assertRaises(OSError):
                self.invoke()
        self.assertTrue(failure["injected"], "test must reach directory publication")
        self.assertEqual(file_contents(self.output), before)

    def test_first_run_failure_does_not_publish_a_manifest_or_binary(self):
        self.manifest["musl_loader"]["apk_sha256"] = "0" * 64
        self.write_manifest()
        with self.assertRaises(SystemExit):
            self.invoke(("claude-code",))
        self.assertFalse(self.output.exists())

    def test_output_and_cache_must_remain_outside_repository(self):
        inside = SCRIPT.parents[1] / "never-created-cli-test-output"
        for output, cache in [(inside, self.cache), (self.output, inside)]:
            with self.subTest(output=output, cache=cache), self.assertRaises(SystemExit):
                self.invoke(output=output, cache=cache)
            self.assertEqual(self.requested_urls, [])
            self.assertFalse(inside.exists())

    def test_case_alias_of_repository_is_rejected_when_filesystem_supports_it(self):
        repository = prepare.REPOSITORY
        alias = repository.with_name(repository.name.swapcase())
        if not alias.exists() or not alias.samefile(repository):
            self.skipTest("filesystem does not provide a case alias for the repository")
        inside = alias / ("never-created-cli-case-alias-" + self.root.name)
        self.assertFalse(inside.exists())
        # Check the guard before main: a regression must fail here, without
        # allowing the preparation path to create anything inside the checkout.
        self.assertTrue(prepare.is_within(inside.resolve(), repository))
        for output, cache in [(inside, self.cache), (self.output, inside)]:
            with self.subTest(output=output, cache=cache):
                with mock.patch.object(prepare, "download") as download:
                    with self.assertRaises(SystemExit):
                        self.invoke(output=output, cache=cache)
                    download.assert_not_called()
                self.assertFalse(inside.exists())
                self.assertFalse(self.output.exists())

    def test_cache_cannot_be_inside_published_tree(self):
        for cache in [self.output, self.output / ".downloads"]:
            with self.subTest(cache=cache), self.assertRaises(SystemExit):
                self.invoke(cache=cache)
            self.assertEqual(self.requested_urls, [])
            self.assertFalse(self.output.exists())

    def test_default_cache_is_a_sibling_not_part_of_published_tree(self):
        self.invoke(use_default_cache=True)
        self.assert_codex_bundle()
        self.assertTrue(self.output.with_name(self.output.name + ".downloads").is_dir())

    def test_unsafe_tar_paths_and_links_preserve_previous_output(self):
        before = self.seed_previous_output()
        for name, member_type, linkname in [
            ("../escaped", tarfile.REGTYPE, ""),
            ("/absolute", tarfile.REGTYPE, ""),
            ("package/link", tarfile.SYMTYPE, "../../escaped"),
            ("package/link", tarfile.LNKTYPE, "package/bin/codex"),
        ]:
            with self.subTest(name=name, member_type=member_type):
                shutil.rmtree(self.cache, ignore_errors=True)
                package = self.manifest["packages"]["codex"]
                archive = self.downloads[package["tarball"]]
                with tarfile.open(archive, "w:gz") as tar:
                    member = tarfile.TarInfo(name)
                    member.type = member_type
                    member.linkname = linkname
                    member.size = 0
                    tar.addfile(member)
                package["integrity"] = integrity(archive)
                self.write_manifest()
                with self.assertRaises(SystemExit):
                    self.invoke()
                self.assertEqual(file_contents(self.output), before)
                self.assertFalse((self.root / "escaped").exists())


if __name__ == "__main__":
    unittest.main()
