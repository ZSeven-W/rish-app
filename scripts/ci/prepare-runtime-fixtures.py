#!/usr/bin/env python3
"""Download exactly the six pinned release packages for real iOS execution tests."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import time
from urllib.parse import urlsplit
from urllib.request import HTTPRedirectHandler, Request, build_opener

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('environment_package', ROOT / 'scripts/runtime-environments/package.py')
package = importlib.util.module_from_spec(spec)
spec.loader.exec_module(package)


def https(url):
    if not isinstance(url, str) or len(url) > 4096 or any(ord(c) < 33 for c in url):
        raise ValueError('invalid package URL')
    parsed = urlsplit(url)
    if parsed.scheme != 'https' or not parsed.hostname or parsed.username or parsed.password or parsed.fragment:
        raise ValueError('package URL must be credential-free HTTPS')
    return url


class HTTPSRedirects(HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        https(new_url)
        return super().redirect_request(request, file, code, message, headers, new_url)


def catalog_records(value):
    if not isinstance(value, dict) or set(value) != {'schema_version', 'environments'} or type(value['schema_version']) is not int or value['schema_version'] != 1:
        raise ValueError('invalid runtime catalog')
    records = value['environments']
    if not isinstance(records, list) or len(records) != 6:
        raise ValueError('the live release gate requires all six language packages')
    families, identifiers = set(), set()
    for record in records:
        if not isinstance(record, dict) or set(record) != {'manifest', 'url', 'package_sha256', 'package_bytes'}:
            raise ValueError('invalid catalog record')
        manifest = package.validate_manifest(record['manifest'])
        https(record['url'])
        if not isinstance(record['package_sha256'], str) or re.fullmatch('[0-9a-f]{64}', record['package_sha256']) is None:
            raise ValueError('invalid package digest')
        if type(record['package_bytes']) is not int or not 13 <= record['package_bytes'] <= 768 * 1024 * 1024:
            raise ValueError('invalid package size')
        if manifest['family'] in families or manifest['environment_id'] in identifiers:
            raise ValueError('duplicate language or environment')
        families.add(manifest['family']); identifiers.add(manifest['environment_id'])
    if families != package.FAMILIES:
        raise ValueError('missing language fixture')
    return records


def digest_file(path):
    digest = hashlib.sha256()
    with path.open('rb') as file:
        while data := file.read(1024 * 1024):
            digest.update(data)
    return digest.hexdigest()


def validate_fixture_catalog(fixture, catalog):
    """Refuse stale integration fixtures before claiming current release coverage."""
    records = catalog_records(catalog)
    if (not isinstance(fixture, dict) or set(fixture) != {'schema_version', 'packages'}
            or type(fixture['schema_version']) is not int or fixture['schema_version'] != 1
            or not isinstance(fixture['packages'], list) or len(fixture['packages']) != 6):
        raise ValueError('invalid runtime fixture manifest')
    expected = {r['manifest']['family']: {
        'family': r['manifest']['family'],
        'file': r['manifest']['environment_id'] + '.rishenv',
        'environment_id': r['manifest']['environment_id'],
        'package_sha256': r['package_sha256'], 'package_bytes': r['package_bytes'],
    } for r in records}
    seen = set()
    for record in fixture['packages']:
        if not isinstance(record, dict) or not isinstance(record.get('family'), str):
            raise ValueError('invalid runtime fixture record')
        family = record['family']
        if family in seen or record != expected.get(family):
            raise ValueError('runtime fixture differs from current catalog: ' + family)
        seen.add(family)
    return True


def fetch(record, destination, *, offline=False):
    if destination.is_symlink():
        raise ValueError('package cache must not contain symlinks')
    if destination.is_file() and destination.stat().st_size == record['package_bytes'] and digest_file(destination) == record['package_sha256']:
        return
    if offline:
        raise RuntimeError(f"Verified offline package missing: {record['manifest']['environment_id']}")
    partial = destination.with_suffix('.partial')
    if partial.exists() or partial.is_symlink():
        partial.unlink()
    opener = build_opener(HTTPSRedirects())
    for attempt in range(3):
        try:
            total = 0; digest = hashlib.sha256()
            request = Request(record['url'], headers={'User-Agent': 'rish-runtime-release-gate/1'})
            with opener.open(request, timeout=60) as response, partial.open('xb') as file:
                partial.chmod(0o600)
                https(response.url)
                if response.status != 200:
                    raise ValueError('package server did not return a file')
                while data := response.read(1024 * 1024):
                    total += len(data)
                    if total > record['package_bytes']:
                        raise ValueError('package exceeds pinned size')
                    digest.update(data); file.write(data)
            if total != record['package_bytes'] or digest.hexdigest() != record['package_sha256']:
                raise ValueError('downloaded package failed integrity verification')
            partial.replace(destination)
            return
        except Exception:
            partial.unlink(missing_ok=True)
            if attempt == 2:
                raise RuntimeError(f"Could not fetch verified environment {record['manifest']['environment_id']}") from None
            time.sleep(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--catalog', type=Path, default=ROOT / 'runtime-environments/catalog.json')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--offline', action='store_true', help='Require existing hash-matched packages; never download')
    args = parser.parse_args()
    records = catalog_records(json.loads(args.catalog.read_text(), object_pairs_hook=package.unique_object))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    kernel = next((ROOT / 'modules/rish/shared/GuestAssets').glob('vmlinuz-virt-*'))
    kernel_sha = digest_file(kernel)
    fixtures = []
    for record in records:
        manifest = record['manifest']
        path = output / (manifest['environment_id'] + '.rishenv')
        fetch(record, path, offline=args.offline)
        verified = package.verify(path, expected_kernel=kernel_sha)
        if verified != {key: record[key] for key in ['manifest', 'package_sha256', 'package_bytes']}:
            raise ValueError('package and catalog differ')
        fixtures.append({'family': manifest['family'], 'file': path.name,
                         'environment_id': manifest['environment_id'],
                         'package_sha256': record['package_sha256'], 'package_bytes': record['package_bytes']})
        print(f"Verified {manifest['family']} {manifest['version']}", flush=True)
    temporary = output / 'fixture.json.partial'
    temporary.write_text(json.dumps({'schema_version': 1, 'packages': fixtures}, indent=2) + '\n')
    temporary.replace(output / 'fixture.json')


if __name__ == '__main__':
    main()
