#!/usr/bin/env python3
import copy
import hashlib
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('fixtures', Path(__file__).resolve().parents[1] / 'ci/prepare-runtime-fixtures.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


def catalog():
    records = []
    for family in fixtures.package.FAMILIES:
        records.append({
            'manifest': {'schema_version': 1, 'environment_id': family + '-test', 'family': family,
                         'display_name': family, 'version': '1.0', 'architecture': 'x86_64',
                         'kernel_sha256': 'a' * 64, 'disk_sha256': 'b' * 64,
                         'disk_bytes': 1048576, 'minimum_memory_mib': 512},
            'url': 'https://example.test/' + family + '.rishenv', 'package_sha256': 'c' * 64, 'package_bytes': 100,
        })
    return {'schema_version': 1, 'environments': records}


class FixtureTests(unittest.TestCase):
    def test_requires_all_families_and_unique_identifiers(self):
        valid = catalog()
        self.assertEqual(len(fixtures.catalog_records(valid)), 6)
        invalid = copy.deepcopy(valid); invalid['environments'].pop()
        with self.assertRaises(ValueError): fixtures.catalog_records(invalid)
        invalid = copy.deepcopy(valid); invalid['environments'][0] = invalid['environments'][1]
        with self.assertRaises(ValueError): fixtures.catalog_records(invalid)

    def test_rejects_missing_digests_bool_sizes_and_credential_urls(self):
        for field, value in [('package_sha256', ''), ('package_bytes', True),
                             ('url', 'http://example.test/a'), ('url', 'https://user:secret@example.test/a')]:
            invalid = catalog(); invalid['environments'][0][field] = value
            with self.assertRaises(ValueError): fixtures.catalog_records(invalid)
        with self.assertRaises(ValueError): fixtures.https('https://example.test/a\n')
        with self.assertRaises(ValueError): fixtures.https('https://example.test/a#secret')

    def test_cached_download_must_match_size_and_digest(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'package.rishenv'
            data = b'verified package bytes'
            path.write_bytes(data)
            record = {'package_bytes': len(data), 'package_sha256': hashlib.sha256(data).hexdigest()}
            with patch.object(fixtures, 'build_opener', side_effect=AssertionError('unexpected network')):
                fixtures.fetch(record, path)
            link = Path(directory) / 'link.rishenv'; link.symlink_to(path)
            with self.assertRaises(ValueError): fixtures.fetch(record, link)

    def test_stream_download_integrity_failure_never_creates_selectable_fixture(self):
        class Response:
            status = 200
            url = 'https://example.test/package'
            def __enter__(self): return self
            def __exit__(self, *_): pass
            def read(self, _):
                result = getattr(self, 'data', b'wrong package')
                self.data = b''
                return result
        class Opener:
            def open(self, *_, **__): return Response()
        record = {'manifest': {'environment_id': 'python-test'}, 'url': Response.url,
                  'package_bytes': 13, 'package_sha256': 'a' * 64}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'package.rishenv'
            with patch.object(fixtures, 'build_opener', return_value=Opener()), patch.object(fixtures.time, 'sleep'):
                with self.assertRaises(RuntimeError): fixtures.fetch(record, path)
            self.assertFalse(path.exists())
            self.assertFalse(path.with_suffix('.partial').exists())

    def test_offline_missing_or_changed_package_never_opens_network(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'package.rishenv'
            record = {'manifest': {'environment_id': 'python-test'},
                      'package_bytes': 13, 'package_sha256': 'a' * 64}
            with patch.object(fixtures, 'build_opener', side_effect=AssertionError('unexpected network')):
                with self.assertRaises(RuntimeError): fixtures.fetch(record, path, offline=True)
                path.write_bytes(b'old package')
                with self.assertRaises(RuntimeError): fixtures.fetch(record, path, offline=True)
            self.assertEqual(path.read_bytes(), b'old package')

    def test_fixture_identity_must_match_current_catalog(self):
        current = catalog()
        fixture = {'schema_version': 1, 'packages': [{
            'family': r['manifest']['family'],
            'file': r['manifest']['environment_id'] + '.rishenv',
            'environment_id': r['manifest']['environment_id'],
            'package_sha256': r['package_sha256'], 'package_bytes': r['package_bytes'],
        } for r in current['environments']]}
        self.assertTrue(fixtures.validate_fixture_catalog(fixture, current))
        for key, value in [('environment_id', 'python-old'), ('package_sha256', 'd' * 64),
                           ('package_bytes', 101), ('file', 'old.rishenv')]:
            stale = copy.deepcopy(fixture); stale['packages'][0][key] = value
            with self.assertRaises(ValueError): fixtures.validate_fixture_catalog(stale, current)
        duplicate = copy.deepcopy(fixture); duplicate['packages'][0] = duplicate['packages'][1]
        with self.assertRaises(ValueError): fixtures.validate_fixture_catalog(duplicate, current)


if __name__ == '__main__':
    unittest.main()
