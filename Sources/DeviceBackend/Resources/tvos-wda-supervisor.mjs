// SPDX-License-Identifier: Apache-2.0
import {pathToFileURL} from 'node:url';

function parseArguments(argv) {
  const result = {};
  for (let index = 0; index < argv.length; index += 2) {
    const key = argv[index];
    const value = argv[index + 1];
    if (!key?.startsWith('--') || value == null) {
      throw new Error(`Expected --name value arguments; got ${argv.slice(index).join(' ')}`);
    }
    result[key.slice(2)] = value;
  }
  return result;
}

const options = parseArguments(process.argv.slice(2));
const required = [
  'module',
  'udid',
  'runner-bundle-id',
  'target-bundle-id',
  'xctest-bundle-id',
  'local-port',
  'remote-port',
  'timeout-ms',
];
for (const key of required) {
  if (!options[key]) {
    throw new Error(`Missing required --${key}`);
  }
}

const localPort = Number.parseInt(options['local-port'], 10);
const remotePort = Number.parseInt(options['remote-port'], 10);
const timeoutMs = Number.parseInt(options['timeout-ms'], 10);
for (const [name, value] of [
  ['local-port', localPort],
  ['remote-port', remotePort],
  ['timeout-ms', timeoutMs],
]) {
  if (!Number.isSafeInteger(value) || value <= 0) {
    throw new Error(`--${name} must be a positive integer`);
  }
}

const remoteXPC = await import(pathToFileURL(options.module).href);
const {DevicePortForwarder, XCTestRunner, connectViaTunnel} = remoteXPC;
if (!DevicePortForwarder || !XCTestRunner || !connectViaTunnel) {
  throw new Error(
    `appium-ios-remotexpc at ${options.module} does not export ` +
      'DevicePortForwarder, XCTestRunner, and connectViaTunnel',
  );
}

const forwarder = new DevicePortForwarder(localPort, remotePort, {
  primaryConnector: () => connectViaTunnel(options.udid, remotePort),
});
const runner = new XCTestRunner({
  udid: options.udid,
  testRunnerBundleId: options['runner-bundle-id'],
  appUnderTestBundleId: options['target-bundle-id'],
  xctestBundleId: options['xctest-bundle-id'],
  timeoutMs,
  launchEnvironment: {
    USE_PORT: String(remotePort),
    MJPEG_SERVER_PORT: String(remotePort + 1000),
    WDA_PRODUCT_BUNDLE_IDENTIFIER: options['runner-bundle-id'],
  },
  killExisting: true,
  testType: 'ui',
});

runner.on('step', (stage) => {
  process.stdout.write(`[sim-use-wda] ${stage}\n`);
});
if (process.env.SIM_USE_WDA_SUPERVISOR_VERBOSE === '1') {
  runner.on('xctest', (event) => {
    process.stdout.write(`[sim-use-wda:xctest] ${JSON.stringify(event)}\n`);
  });
}
forwarder.on('upstreamConnectError', (error) => {
  process.stderr.write(`[sim-use-wda:forwarder] ${error?.stack ?? String(error)}\n`);
});

let closing = false;
async function close(signal) {
  if (closing) {
    return;
  }
  closing = true;
  process.stdout.write(`[sim-use-wda] closing (${signal})\n`);
  await runner.close().catch((error) => {
    process.stderr.write(`[sim-use-wda] runner cleanup: ${error?.stack ?? String(error)}\n`);
  });
  await forwarder.stop().catch((error) => {
    process.stderr.write(`[sim-use-wda] forwarder cleanup: ${error?.stack ?? String(error)}\n`);
  });
}

for (const signal of ['SIGINT', 'SIGTERM', 'SIGHUP']) {
  process.on(signal, () => {
    void close(signal).finally(() => process.exit(0));
  });
}

await forwarder.start();
process.stdout.write(
  `[sim-use-wda] forwarding http://127.0.0.1:${localPort} ` +
    `to ${options.udid}:${remotePort}\n`,
);

try {
  const result = await runner.run();
  process.stdout.write(`[sim-use-wda] result ${JSON.stringify(result)}\n`);
  process.exitCode = result.status === 'failed' ? 1 : 0;
} catch (error) {
  process.stderr.write(`${error?.stack ?? String(error)}\n`);
  process.exitCode = 1;
} finally {
  await close('runner-finished');
}
