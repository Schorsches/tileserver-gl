/**
 * Remove install-time-only packages from node_modules in the runtime image.
 *
 * Several production dependencies exist purely to run at install or build time
 * and are never imported by the running server:
 *
 *   @acalcutt/node-pre-gyp[-github]  fetches maplibre's prebuilt binary. The
 *                                    Alpine image compiles that addon itself
 *                                    and installs it with --ignore-scripts, so
 *                                    this never runs.
 *   npm-run-all                      drives @maplibre/maplibre-gl-native's own
 *                                    package scripts.
 *   copyfiles                        implements the `prepare` script, which has
 *                                    already run in the builder stage.
 *
 * They drag in tar, glob, brace-expansion, ip-address and shell-quote, which
 * are a standing source of scanner findings in an image that can never use
 * them.
 *
 * Rather than hardcode a delete list that silently rots as dependencies change,
 * this walks package-lock.json from the real runtime roots and removes whatever
 * is unreachable. Node's resolution rules are followed, so a nested copy is
 * kept whenever something still needs it.
 *
 * Usage: node prune-runtime-modules.mjs <app-dir> [--dry-run]
 */
import { readFileSync, rmSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const INSTALL_ONLY = new Set([
  '@acalcutt/node-pre-gyp',
  '@acalcutt/node-pre-gyp-github',
  'npm-run-all',
  'copyfiles',
  // sqlite3 and canvas declare their build machinery as ordinary runtime
  // dependencies. sqlite3/lib requires only `bindings`, its own binding and
  // node builtins; nothing here is reachable once the addons are compiled.
  // These three pull in cacache, make-fetch-happen, socks, ip-address, glob,
  // minimatch and brace-expansion behind them.
  'node-gyp',
  'prebuild-install',
  'tar',
  // Edge-scoped rule: `parent>child` drops one dependency edge rather than a
  // package name globally. @maplibre/maplibre-gl-native declares minimatch for
  // its own package scripts, but its index.js requires nothing except
  // ./lib/node-v<abi>/mbgl -- and minimatch is too common a name to exclude
  // everywhere.
  '@maplibre/maplibre-gl-native>minimatch',
]);

/** Package name for an installed path, e.g. a/node_modules/@scope/pkg -> @scope/pkg */
function nameOf(path) {
  const last = path.split('node_modules/').pop();
  return last || path;
}

const appDir = process.argv[2];
const dryRun = process.argv.includes('--dry-run');
if (!appDir) {
  console.error('usage: prune-runtime-modules.mjs <app-dir> [--dry-run]');
  process.exit(1);
}

const lock = JSON.parse(
  readFileSync(join(appDir, 'package-lock.json'), 'utf8'),
);
const pkg = JSON.parse(readFileSync(join(appDir, 'package.json'), 'utf8'));
const entries = lock.packages || {};

/** Resolve `name` as required from the package installed at `fromPath`, the way node does. */
function resolve(fromPath, name) {
  const segments = fromPath === '' ? [] : fromPath.split('/node_modules/');
  for (let i = segments.length; i >= 0; i--) {
    const prefix = segments.slice(0, i).join('/node_modules/');
    const candidate = (prefix ? `${prefix}/` : '') + `node_modules/${name}`;
    if (entries[candidate]) return candidate;
  }
  return null;
}

const reachable = new Set();
const queue = [];

for (const name of Object.keys(pkg.dependencies || {})) {
  if (INSTALL_ONLY.has(name)) continue;
  const path = resolve('', name);
  if (path) queue.push(path);
}

while (queue.length) {
  const path = queue.pop();
  if (reachable.has(path)) continue;
  reachable.add(path);
  const entry = entries[path] || {};
  const owner = nameOf(path);
  // devDependencies are already absent; peers and optionals may legitimately be
  // loaded at runtime (sharp reaches its platform binary through optional deps).
  const deps = {
    ...(entry.dependencies || {}),
    ...(entry.optionalDependencies || {}),
    ...(entry.peerDependencies || {}),
  };
  for (const name of Object.keys(deps)) {
    if (INSTALL_ONLY.has(name) || INSTALL_ONLY.has(`${owner}>${name}`))
      continue;
    const next = resolve(path, name);
    if (next) queue.push(next);
  }
}

let removed = 0;
const candidates = Object.keys(entries)
  .filter((p) => p.startsWith('node_modules/') && !reachable.has(p))
  // Deleting a parent removes its nested copies, so skip paths already covered.
  .sort();

const deleted = [];
for (const path of candidates) {
  if (deleted.some((d) => path.startsWith(`${d}/`))) continue;
  const abs = join(appDir, path);
  if (!existsSync(abs)) continue;
  deleted.push(path);
  removed++;
  if (!dryRun) rmSync(abs, { recursive: true, force: true });
}

console.log(
  `${dryRun ? 'would prune' : 'pruned'} ${removed} install-time package(s) from node_modules`,
);
for (const d of deleted.slice(0, 40)) console.log(`  - ${d}`);
if (deleted.length > 40) console.log(`  ... and ${deleted.length - 40} more`);
