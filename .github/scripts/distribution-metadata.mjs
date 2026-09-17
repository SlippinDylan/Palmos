import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { compareVersions, parseVersion } from './release-manifest.mjs';

const SHA256_PATTERN = /^[0-9a-f]{64}$/;

function caskToken(version) {
  switch (version.channel) {
  case 'stable': return 'palmos';
  case 'beta': return 'palmos@beta';
  case 'alpha': return 'palmos@alpha';
  default: throw new Error(`Unsupported Homebrew channel: ${version.channel}.`);
  }
}

export function renderCask(versionValue, sha256) {
  const version = parseVersion(versionValue);
  if (!SHA256_PATTERN.test(sha256)) {
    throw new Error('DMG_SHA256 must be a lowercase SHA-256 digest.');
  }

  return `cask "${caskToken(version)}" do
  version "${version.value}"
  sha256 "${sha256}"

  url "https://github.com/SlippinDylan/Palmos/releases/download/v#{version}/Palmos-v#{version}.dmg"
  name "Palmos"
  desc "Menu-bar monitor for external physical storage devices"
  homepage "https://github.com/SlippinDylan/Palmos"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :tahoe

  app "Palmos.app"
end
`;
}

export function caskVersion(source) {
  const matches = [...source.matchAll(/^\s*version\s+"([^"]+)"\s*$/gm)];
  if (matches.length !== 1) throw new Error('Existing Cask must contain one literal version stanza.');
  return parseVersion(matches[0][1]).value;
}

export function validateCaskAdvance(source, versionValue) {
  const existingVersion = caskVersion(source);
  if (compareVersions(versionValue, existingVersion) < 0) {
    throw new Error(`Refusing to downgrade Cask from ${existingVersion} to ${versionValue}.`);
  }
}

function appcastItems(source) {
  return [...source.matchAll(/<item(?:\s[^>]*)?>[\s\S]*?<\/item>/g)];
}

function itemChannel(item) {
  const match = /<sparkle:channel>([^<]+)<\/sparkle:channel>/.exec(item);
  return match?.[1] ?? 'stable';
}

function itemVersion(item) {
  const match = /<sparkle:shortVersionString>([^<]+)<\/sparkle:shortVersionString>/.exec(item);
  if (!match) throw new Error('appcast item is missing sparkle:shortVersionString.');
  return parseVersion(match[1]).value;
}

export function appcastChannelVersion(source, channel) {
  const versions = appcastItems(source)
    .filter((item) => itemChannel(item[0]) === channel)
    .map((item) => itemVersion(item[0]));
  if (versions.length === 0) return null;
  return versions.sort((left, right) => compareVersions(right, left))[0];
}

export function updateAppcastDisplayVersion(source, versionValue, dmgName) {
  const version = parseVersion(versionValue);
  const matches = appcastItems(source).filter((item) => item[0].includes(dmgName));
  if (matches.length !== 1) {
    throw new Error(`appcast must contain exactly one item for ${dmgName}.`);
  }

  const item = matches[0];
  const shortVersionPattern = /<sparkle:shortVersionString>[^<]*<\/sparkle:shortVersionString>/g;
  if ([...item[0].matchAll(shortVersionPattern)].length !== 1) {
    throw new Error(`appcast item for ${dmgName} must contain one short version.`);
  }

  const updatedItem = item[0].replace(
    shortVersionPattern,
    `<sparkle:shortVersionString>${version.value}</sparkle:shortVersionString>`,
  );
  return `${source.slice(0, item.index)}${updatedItem}${source.slice(item.index + item[0].length)}`;
}

export function metadataState({ appcastSource, caskSource, versionValue, channel, dmgName, dmgSHA256 }) {
  const appcastVersion = appcastSource ? appcastChannelVersion(appcastSource, channel) : null;
  const existingCaskVersion = caskSource ? caskVersion(caskSource) : null;

  if (!appcastVersion && !existingCaskVersion) return 'generate';
  if (!appcastVersion || !existingCaskVersion) {
    throw new Error('Distribution metadata is incomplete; refusing an unsafe partial recovery.');
  }

  const appcastComparison = compareVersions(versionValue, appcastVersion);
  const caskComparison = compareVersions(versionValue, existingCaskVersion);
  if (appcastComparison < 0) {
    throw new Error(`Refusing to downgrade appcast from ${appcastVersion} to ${versionValue}.`);
  }
  if (caskComparison < 0) {
    throw new Error(`Refusing to downgrade Cask from ${existingCaskVersion} to ${versionValue}.`);
  }
  if (appcastComparison === 0 && caskComparison === 0) {
    const matchingItems = appcastItems(appcastSource).filter((item) => (
      itemChannel(item[0]) === channel && itemVersion(item[0]) === versionValue && item[0].includes(dmgName)
    ));
    if (matchingItems.length !== 1 || caskSource !== renderCask(versionValue, dmgSHA256)) {
      throw new Error('Existing metadata for this version does not match the immutable GitHub Release.');
    }
    return 'idempotent';
  }
  if (compareVersions(appcastVersion, existingCaskVersion) !== 0) {
    throw new Error('appcast and Cask release history disagree; refusing unsafe recovery.');
  }
  return 'generate';
}

async function main() {
  const command = process.argv[2];
  const version = process.env.VERSION ?? '';

  if (command === 'cask') {
    const existingCaskPath = process.env.EXISTING_CASK_PATH;
    if (existingCaskPath) {
      validateCaskAdvance(await readFile(existingCaskPath, 'utf8'), version);
    }
    process.stdout.write(renderCask(version, process.env.DMG_SHA256 ?? ''));
    return;
  }

  if (command === 'appcast') {
    const path = process.argv[3];
    if (!path) throw new Error('appcast command requires an appcast path.');
    const source = await readFile(path, 'utf8');
    await writeFile(path, updateAppcastDisplayVersion(source, version, process.env.DMG_NAME ?? ''), 'utf8');
    return;
  }

  if (command === 'state') {
    const appcastPath = process.argv[3];
    const caskPath = process.argv[4];
    if (!appcastPath || !caskPath) throw new Error('state command requires appcast and Cask paths.');
    const [appcastSource, caskSource] = await Promise.all([
      readFile(appcastPath, 'utf8').catch((error) => error.code === 'ENOENT' ? null : Promise.reject(error)),
      readFile(caskPath, 'utf8').catch((error) => error.code === 'ENOENT' ? null : Promise.reject(error)),
    ]);
    process.stdout.write(`${metadataState({
      appcastSource,
      caskSource,
      versionValue: version,
      channel: process.env.CHANNEL ?? '',
      dmgName: process.env.DMG_NAME ?? '',
      dmgSHA256: process.env.DMG_SHA256 ?? '',
    })}\n`);
    return;
  }

  throw new Error(`Unknown command: ${command ?? ''}.`);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  main().catch((error) => {
    console.error(`::error::Distribution metadata failed: ${error.message}`);
    process.exitCode = 1;
  });
}
