// SPDX-License-Identifier: Apache-2.0
//
// Runtime-scoped compatibility shim for appium-ios-remotexpc. It changes
// only modules loaded by the sim-use tvOS WDA supervisor process; the
// installed Appium package on disk is never edited.

function sourceText(value) {
  if (typeof value === 'string') {
    return value;
  }
  return Buffer.from(value).toString('utf8');
}

export async function load(url, context, nextLoad) {
  const loaded = await nextLoad(url, context);
  if (loaded.format !== 'module' || loaded.source == null) {
    return loaded;
  }

  let source = sourceText(loaded.source);

  if (url.endsWith('/services/ios/testmanagerd/xcuitest.js')) {
    const idlePattern = /const MAX_CONSECUTIVE_EMPTY_POLLS\s*=\s*60\s*;/;
    if (!idlePattern.test(source)) {
      throw new Error(
        `Unsupported appium-ios-remotexpc XCTest lifecycle at ${url}: ` +
          'the 60-second idle guard was not found',
      );
    }
    source = source.replace(
      idlePattern,
      'const MAX_CONSECUTIVE_EMPTY_POLLS = Number.MAX_SAFE_INTEGER;',
    );
  }

  if (
    url.endsWith('/lib/tunnel/tunnel-availability.js') &&
    process.env.APPIUM_TUNNEL_REGISTRY_PORT
  ) {
    if (!source.includes('process.env.APPIUM_TUNNEL_REGISTRY_PORT')) {
      const registryPattern =
        /const tunnelRegistryPort\s*=\s*await item\.read\(\)\s*;/;
      if (!registryPattern.test(source)) {
        throw new Error(
          `Unsupported appium-ios-remotexpc tunnel registry lookup at ${url}: ` +
            'the strongbox port read was not found',
        );
      }
      source = source.replace(
        registryPattern,
        'const tunnelRegistryPort = process.env.APPIUM_TUNNEL_REGISTRY_PORT ?? (await item.read());',
      );
    }
  }

  return {...loaded, source};
}
