import assert from 'node:assert/strict';
import test from 'node:test';

import {
  appcastChannelVersion,
  metadataState,
  renderCask,
  updateAppcastDisplayVersion,
  validateCaskAdvance,
} from './distribution-metadata.mjs';

const digest = 'a'.repeat(64);

function item(version, channel = 'stable') {
  const channelElement = channel === 'stable' ? '' : `<sparkle:channel>${channel}</sparkle:channel>`;
  return `<item>${channelElement}<sparkle:shortVersionString>${version}</sparkle:shortVersionString><enclosure url="Palmos-v${version}.dmg" /></item>`;
}

test('renders channel-specific, immutable Palmos Casks', () => {
  assert.match(renderCask('1.0.0', digest), /^cask "palmos" do/m);
  assert.match(renderCask('1.0.0-beta.1', digest), /^cask "palmos@beta" do/m);
  assert.match(renderCask('1.0.0-alpha.1', digest), /^cask "palmos@alpha" do/m);
  assert.match(renderCask('1.0.0', digest), /Palmos-v#\{version\}\.dmg/);
});

test('rejects Cask downgrades but allows idempotent versions', () => {
  const current = renderCask('1.0.0-beta.2', digest);
  assert.doesNotThrow(() => validateCaskAdvance(current, '1.0.0-beta.2'));
  assert.throws(() => validateCaskAdvance(current, '1.0.0-beta.1'));
  assert.throws(() => validateCaskAdvance(`${current}version "1.0.0-beta.2"\n`, '1.0.0-beta.2'));
});

test('selects the newest appcast version within its channel', () => {
  const source = `<rss><channel>${item('1.0.0-beta.1', 'beta')}${item('1.0.0-beta.2', 'beta')}${item('1.0.0')}</channel></rss>`;
  assert.equal(appcastChannelVersion(source, 'beta'), '1.0.0-beta.2');
  assert.equal(appcastChannelVersion(source, 'stable'), '1.0.0');
});

test('allows only exact idempotent metadata recovery', () => {
  const version = '1.0.0-beta.2';
  const appcast = `<rss><channel>${item(version, 'beta')}</channel></rss>`;
  const cask = renderCask(version, digest);
  assert.equal(metadataState({
    appcastSource: appcast,
    caskSource: cask,
    versionValue: version,
    channel: 'beta',
    dmgName: `Palmos-v${version}.dmg`,
    dmgSHA256: digest,
  }), 'idempotent');
  assert.throws(() => metadataState({
    appcastSource: appcast,
    caskSource: cask,
    versionValue: '1.0.0-beta.1',
    channel: 'beta',
    dmgName: 'Palmos-v1.0.0-beta.1.dmg',
    dmgSHA256: digest,
  }));
});

test('refuses incomplete or inconsistent metadata recovery', () => {
  const version = '1.0.0';
  assert.throws(() => metadataState({
    appcastSource: `<rss><channel>${item(version)}</channel></rss>`,
    caskSource: null,
    versionValue: version,
    channel: 'stable',
    dmgName: `Palmos-v${version}.dmg`,
    dmgSHA256: digest,
  }));
  assert.throws(() => metadataState({
    appcastSource: `<rss><channel>${item('1.0.0')}</channel></rss>`,
    caskSource: renderCask('1.0.1', digest),
    versionValue: '1.0.2',
    channel: 'stable',
    dmgName: 'Palmos-v1.0.2.dmg',
    dmgSHA256: digest,
  }));
});

test('updates only the generated archive item display version', () => {
  const source = `<rss><channel>${item('0.9.0')}${item('1.0.0-beta.1', 'beta')}</channel></rss>`;
  const updated = updateAppcastDisplayVersion(source, '1.0.0-beta.1', 'Palmos-v1.0.0-beta.1.dmg');
  assert.match(updated, /<sparkle:shortVersionString>0\.9\.0<\/sparkle:shortVersionString>/);
  assert.match(updated, /<sparkle:shortVersionString>1\.0\.0-beta\.1<\/sparkle:shortVersionString>/);
});
