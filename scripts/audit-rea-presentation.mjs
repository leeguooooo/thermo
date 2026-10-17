// REA profile comparison. Raw schemas stay in an owned private audit directory.
// Usage: node scripts/audit-rea-presentation.mjs OWNED_AUDIT_DIRECTORY [--exercise-owned-har]
import { spawn } from 'node:child_process';
import { createInterface } from 'node:readline';
import { readFile, writeFile, access } from 'node:fs/promises';
import { join } from 'node:path';
import { createHash } from 'node:crypto';

const root = process.argv[2];
await access(join(root, '.owned-audit'));
const launch = JSON.parse(await readFile(join(root, 'launch.json'), 'utf8'));
const exercise = process.argv.includes('--exercise-owned-har');
if (exercise) {
  const har = { log: { version: '1.2', creator: { name: 'thermo-owned-fixture', version: '1' }, entries: [{
    startedDateTime: '2026-01-01T00:00:00.000Z', time: 1,
    request: { method: 'GET', url: 'https://example.invalid/diagnostic', httpVersion: 'HTTP/1.1', cookies: [], headers: [], queryString: [], headersSize: -1, bodySize: 0 },
    response: { status: 200, statusText: 'OK', httpVersion: 'HTTP/1.1', cookies: [], headers: [], content: { size: 11, mimeType: 'application/json', text: '{\"ok\":true}' }, redirectURL: '', headersSize: -1, bodySize: 11 },
    cache: {}, timings: { send: 0, wait: 1, receive: 0 }
  }] } };
  await writeFile(join(root, 'owned-network.har'), JSON.stringify(har), { flag: 'wx', mode: 0o600 });
}
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === 'object') return Object.fromEntries(Object.keys(value).sort().map(k => [k, canonical(value[k])]));
  return value;
}
const json = value => JSON.stringify(canonical(value));
const hash = value => createHash('sha256').update(json(value)).digest('hex');

async function capture(profile) {
  const child = spawn(launch.command, launch.args, {
    env: { ...process.env, ...launch.env, REA_MCP_INPUT_SCHEMA_PROFILE: 'full', REA_MCP_OUTPUT_SCHEMA_PROFILE: profile },
    cwd: root, stdio: ['pipe', 'pipe', 'ignore'],
  });
  const lines = createInterface({ input: child.stdout });
  const pending = new Map();
  let sequence = 0;
  const exited = new Promise(resolve => child.once('exit', resolve));
  child.once('error', error => { for (const p of pending.values()) p.reject(error); });
  lines.on('line', line => {
    try {
      if (Buffer.byteLength(line) > 8 * 1024 * 1024) throw new Error('Oversized MCP frame');
      const message = JSON.parse(line);
      if (message.method && 'id' in message) {
        child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id: message.id, ...(message.method === 'ping' ? { result: {} } : { error: { code: -32601, message: 'Unsupported by metadata audit' } }) }) + '\n');
      } else if (pending.has(message.id)) {
        const p = pending.get(message.id); pending.delete(message.id); clearTimeout(p.timer);
        message.error ? p.reject(new Error('MCP returned a protocol error')) : p.resolve(message.result);
      }
    } catch (error) { for (const p of pending.values()) p.reject(error); }
  });
  lines.once('close', () => { for (const p of pending.values()) p.reject(new Error('MCP stream closed before response')); });
  const request = (method, params) => new Promise((resolve, reject) => {
    const id = profile + '-' + ++sequence;
    const timer = setTimeout(() => { pending.delete(id); reject(new Error('Metadata request timed out')); }, 20000);
    pending.set(id, { resolve, reject, timer });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', id, method, params }) + '\n');
  });
  try {
    const initialized = await request('initialize', { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'thermo-owned-catalog-audit', version: '1' } });
    child.stdin.write(JSON.stringify({ jsonrpc: '2.0', method: 'notifications/initialized' }) + '\n');
    const tools = [];
    let cursor;
    for (let page = 0; page < 100; page++) {
      const result = await request('tools/list', cursor ? { cursor } : {});
      if (!Array.isArray(result.tools)) throw new Error('Invalid tools/list');
      tools.push(...result.tools);
      if (tools.length > 10000) throw new Error('Tool count limit exceeded');
      cursor = result.nextCursor;
      if (!cursor) break;
      if (page === 99) throw new Error('Incomplete pagination');
    }
    await writeFile(join(root, profile + '-catalog-private.json'), JSON.stringify({ initialized, tools }), { flag: 'wx', mode: 0o600 });
    let probe;
    if (exercise) {
      if (!tools.some(t => t.name === 'inspect_web_network_capture')) throw new Error('Offline capture tool unavailable');
      probe = await request('tools/call', { name: 'inspect_web_network_capture', arguments: { capture_path: join(root, 'owned-network.har'), format: 'har', detail: 'complete' } });
      await writeFile(join(root, profile + '-probe-private.json'), JSON.stringify(probe), { flag: 'wx', mode: 0o600 });
      if (probe.isError) throw new Error('Owned HAR probe returned an error');
    }
    return { initialized, tools, probe };
  } finally {
    for (const p of pending.values()) clearTimeout(p.timer);
    child.stdin.end();
    const wait = ms => new Promise(resolve => setTimeout(resolve, ms));
    await Promise.race([exited, wait(500)]);
    if (child.exitCode === null && child.signalCode === null) { child.kill('SIGTERM'); await Promise.race([exited, wait(2000)]); }
    if (child.exitCode === null && child.signalCode === null) { child.kill('SIGKILL'); await exited; }
    lines.close();
  }
}

const full = await capture('full');
const off = await capture('off');
const stripOutput = tool => { const { outputSchema, ...rest } = tool; return rest; };
const fullMap = new Map(full.tools.map(t => [t.name, t]));
const offMap = new Map(off.tools.map(t => [t.name, t]));
if (json([...fullMap.keys()].sort()) !== json([...offMap.keys()].sort())) throw new Error('Tool names differ');
const mismatched = full.tools.filter(t => hash(stripOutput(t)) !== hash(stripOutput(offMap.get(t.name)))).map(t => t.name);
if (mismatched.length) throw new Error('Fields other than outputSchema changed: ' + mismatched.join(', '));
if (off.tools.some(t => 'outputSchema' in t)) throw new Error('Output schema still present');
const report = { tools: full.tools.length, toolNamesUnchanged: true, allOtherToolFieldsUnchanged: true,
  fullDefinitionBytes: Buffer.byteLength(json(full.tools)), offDefinitionBytes: Buffer.byteLength(json(off.tools)),
  fullServerInfo: full.initialized.serverInfo, offServerInfo: off.initialized.serverInfo,
  namesAndInputsSHA256: hash(full.tools.map(stripOutput).sort((a,b) => a.name.localeCompare(b.name))),
  noBusinessCalls: !exercise, ownedOfflineHarProbe: exercise, userConfigModified: false, rawSchemasKeptPrivate: true,
  probeStructuredContentKeys: exercise ? [full, off].map(r => Object.keys(r.probe.structuredContent ?? {})) : undefined };
await writeFile(join(root, 'metadata-comparison.json'), JSON.stringify(report, null, 2), { flag: 'wx', mode: 0o600 });
console.log(JSON.stringify(report));
