import { mkdir, writeFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { initialize, loadConfig, fingerprint } from '../apps/bridge/dist/config.js';
import { Store } from '../apps/bridge/dist/store.js';

process.env.BRIDGE_DATA_DIR ??= resolve('.local', 'integration-host');
let config;
try { config = await loadConfig(); }
catch (error) { if (error.code !== 'ENOENT') throw error; config = await initialize('https://127.0.0.1:8787'); }
const project = resolve('.local', 'android-integration-project');
await mkdir(project, { recursive: true });
const store = new Store(join(config.dataDir, 'bridge.sqlite'), false);
const pair = store.createPair();
await writeFile(resolve('.local', 'integration.json'), JSON.stringify({ BRIDGE_URL: 'https://10.0.2.2:8787', BRIDGE_PAIR_CODE: pair.code, BRIDGE_PIN: await fingerprint(config), BRIDGE_PROJECT: project }));
store.close();
console.log('One-use emulator pairing material written to .local/integration.json (expires in 5 minutes).');
