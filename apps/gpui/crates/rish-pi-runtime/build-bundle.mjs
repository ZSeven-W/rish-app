import { build, version as esbuildVersion } from 'esbuild';
import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const root = dirname(fileURLToPath(import.meta.url));
const check = process.argv.slice(2);
if (check.length > 1 || (check.length === 1 && check[0] !== '--check')) {
  throw new Error('Usage: node build-bundle.mjs [--check]');
}
const provenance = JSON.parse(await readFile(join(root, 'vendor/provenance.json'), 'utf8'));
if (esbuildVersion !== provenance.esbuild) {
  throw new Error(`Expected esbuild ${provenance.esbuild}; run npm ci`);
}
for (const [name, version] of Object.entries(provenance.packages)) {
  const installed = JSON.parse(await readFile(join(root, 'node_modules', name, 'package.json'), 'utf8'));
  if (installed.version !== version) throw new Error(`Expected ${name}@${version}; run npm ci`);
}
const result = await build({
  absWorkingDir: root,
  entryPoints: ['js/bundle-entry.mjs'],
  bundle: true,
  format: 'iife',
  platform: 'browser',
  target: 'es2022',
  minify: true,
  write: false,
  metafile: true,
  logLevel: 'silent',
});
if (result.outputFiles.length !== 1) throw new Error('Expected one self-contained bundle');
const output = Object.values(result.metafile.outputs)[0];
if (output.imports.length !== 0) throw new Error('Bundle must not contain external imports');
const contributors = new Set();
for (const [input, detail] of Object.entries(output.inputs)) {
  if (detail.bytesInOutput === 0) continue;
  const match = input.replaceAll('\\', '/').match(/(?:^|\/)node_modules\/((?:@[^/]+\/)?[^/]+)/);
  if (match) contributors.add(match[1]);
  else if (input !== 'js/bundle-entry.mjs') throw new Error(`Unexpected bundled source: ${input}`);
}
const expectedPackages = Object.keys(provenance.packages).sort();
if (JSON.stringify([...contributors].sort()) !== JSON.stringify(expectedPackages)) {
  throw new Error(`Unexpected bundle contributors: ${[...contributors].join(', ')}`);
}
const bytes = result.outputFiles[0].contents;
const digest = createHash('sha256').update(bytes).digest('hex');
if (digest !== provenance.sha256 || bytes.length !== provenance.bytes) {
  throw new Error(`Bundle differs from reviewed provenance: ${digest} (${bytes.length} bytes)`);
}
const destination = join(root, provenance.file);
if (check.length) {
  if (!Buffer.from(bytes).equals(await readFile(destination))) {
    throw new Error('Vendored bundle does not match the reproducible build');
  }
} else {
  await writeFile(destination, bytes);
}
console.log(`${check.length ? 'Verified' : 'Rebuilt'} ${provenance.file}: ${digest} (${bytes.length} bytes)`);
console.log(`Bundled packages: ${expectedPackages.join(', ')}`);
