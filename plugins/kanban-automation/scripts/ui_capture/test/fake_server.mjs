#!/usr/bin/env node
// Stand-in for a project's `server_command`, used only by run_tests.sh.
// Launcher mode (the default) mimics a `-d`-style daemonizing server: it
// forks a detached listener child and returns. `--behavior` picks which of
// the launcher's real-world failure shapes to reproduce; the listener
// child itself is controlled by `--delay` (seconds before it starts
// answering 200) and `--die-after` (seconds before it exits on its own).
import http from 'node:http';
import { spawn } from 'node:child_process';
import fs from 'node:fs';

function argVal(name, def) {
  const i = process.argv.indexOf(name);
  return i >= 0 && i + 1 < process.argv.length ? process.argv[i + 1] : def;
}

const mode = argVal('--mode', 'launch');
const port = Number(argVal('--port'));
const healthPath = argVal('--health-path', '/health');
const delay = Number(argVal('--delay', '0'));
const dieAfter = Number(argVal('--die-after', '0'));

if (mode === 'listen') {
  const startedAt = Date.now();
  const server = http.createServer((req, res) => {
    if (req.url === healthPath) {
      if (Date.now() - startedAt >= delay * 1000) {
        res.writeHead(200);
        res.end('ok');
      } else {
        res.writeHead(503);
        res.end('not ready');
      }
    } else {
      res.writeHead(404);
      res.end();
    }
  });
  server.listen(port, '127.0.0.1');
  if (dieAfter > 0) {
    setTimeout(() => process.exit(1), dieAfter * 1000);
  }
} else {
  const behavior = argVal('--behavior', 'normal');
  const pidfile = argVal('--pidfile');
  const self = process.argv[1];

  if (behavior === 'exit-nonzero-no-listener') {
    // The command itself fails before backgrounding anything.
    process.exit(1);
  }

  const child = spawn(
    process.execPath,
    [self, '--mode', 'listen', '--port', String(port), '--health-path', healthPath,
     '--delay', String(delay), '--die-after', String(dieAfter)],
    { detached: true, stdio: 'ignore' },
  );
  child.unref();

  switch (behavior) {
    case 'normal':
    case 'slow-health':
    case 'crash-quick':
      fs.writeFileSync(pidfile, String(child.pid));
      process.exit(0);
      break;
    case 'write-pidfile-then-fail':
      // Backgrounded fine, but the launcher's own post-check fails.
      fs.writeFileSync(pidfile, String(child.pid));
      process.exit(1);
      break;
    case 'never-pidfile':
      // Forgot to write the pidfile; exits as if nothing were wrong.
      process.exit(0);
      break;
    default:
      process.exit(1);
  }
}
