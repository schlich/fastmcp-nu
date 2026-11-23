// Minimal MCP stdio client using only Node built-ins.
//
// Keeps the server's stdin open and waits for each response before sending
// the next message, so a server that buffers input until EOF times out
// instead of passing. Prints {responses, stray} as JSON, where `stray` holds
// any stdout line that is not a JSON-RPC response to one of our requests.
//
//   node stream_client.mjs requests.json -- command arg...
//
// requests.json is a list of {method, params?, notify?}.
import { spawn } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { createInterface } from 'node:readline';

const argv = process.argv.slice(2);
const sep = argv.indexOf('--');
if (sep !== 1 || argv.length < 3) {
  console.error('usage: node stream_client.mjs requests.json -- command arg...');
  process.exit(2);
}
const steps = JSON.parse(readFileSync(argv[0], 'utf8'));
const [cmd, ...args] = argv.slice(2);
const timeoutMs = Number(process.env.STREAM_CLIENT_TIMEOUT_MS ?? 10000);

const child = spawn(cmd, args, { stdio: ['pipe', 'pipe', 'inherit'] });
const pending = new Map();
const stray = [];
createInterface({ input: child.stdout }).on('line', (line) => {
  let msg;
  try {
    msg = JSON.parse(line);
  } catch {
    stray.push(line);
    return;
  }
  const settle = pending.get(msg.id);
  if (settle) {
    pending.delete(msg.id);
    settle(msg);
  } else {
    stray.push(line);
  }
});

const send = (msg) => child.stdin.write(JSON.stringify(msg) + '\n');

let nextId = 1;
const request = (method, params) =>
  new Promise((resolve, reject) => {
    const id = nextId++;
    const timer = setTimeout(
      () => reject(new Error(`no response to ${method} within ${timeoutMs}ms (is the server waiting for EOF?)`)),
      timeoutMs,
    );
    pending.set(id, (msg) => {
      clearTimeout(timer);
      resolve(msg);
    });
    send({ jsonrpc: '2.0', id, method, params: params ?? {} });
  });

let failed = false;
const responses = [];
try {
  for (const step of steps) {
    if (step.notify) {
      send({ jsonrpc: '2.0', method: step.method, params: step.params ?? {} });
    } else {
      responses.push(await request(step.method, step.params));
    }
  }
} catch (err) {
  console.error(err.message);
  failed = true;
}
child.stdin.end();
child.kill();
process.stdout.write(JSON.stringify({ responses, stray }) + '\n');
process.exit(failed ? 1 : 0);
