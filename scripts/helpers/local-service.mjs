import { writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createEnergyServer } from '../../server/server.mjs';

const directory = process.argv[2];
if (!directory) {
  console.error('An isolated test directory is required.');
  process.exit(1);
}

const { server, host } = createEnergyServer({
  host: '127.0.0.1',
  dbPath: join(directory, 'myenergy.sqlite'),
  allowDevelopmentAuth: true
});

let stopping = false;
function stop(exitCode = 0) {
  if (stopping) return;
  stopping = true;
  process.exitCode = exitCode;
  const timeout = setTimeout(() => process.exit(exitCode || 1), 5000);
  timeout.unref();
  server.close(() => clearTimeout(timeout));
  server.closeAllConnections();
}
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => stop());
server.on('error', () => {
  console.error('The isolated sync service could not start.');
  stop(1);
});
server.listen(0, host, () => {
  try {
    const { port } = server.address();
    writeFileSync(join(directory, 'service-url'), `http://${host}:${port}\n`, { mode: 0o600, flag: 'wx' });
  } catch {
    console.error('The isolated sync service could not publish its local address.');
    stop(1);
  }
});
