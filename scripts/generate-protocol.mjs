import { spawnSync } from 'node:child_process';
const command = process.platform === 'win32' ? 'codex.cmd' : 'codex';
const options = { stdio: 'inherit', shell: process.platform === 'win32' };
const version = spawnSync(command, ['--version'], { ...options, stdio: 'pipe', encoding: 'utf8' });
if (version.status !== 0 || version.stdout.trim() !== 'codex-cli 0.155.1') {
  throw new Error('Protocol generation requires exactly codex-cli 0.155.1; do not overwrite the adapter with another version.');
}
for (const [format, output] of [['generate-ts', 'packages/protocol/src/generated'], ['generate-json-schema', 'packages/protocol/schema']]) {
  const result = spawnSync(command, ['app-server', format, '--experimental', '--out', output], options);
  if (result.status !== 0) process.exit(result.status ?? 1);
}
