import assert from 'node:assert/strict';
import test from 'node:test';

import {
  buildCard,
  buildNotification,
  createFeishuSignature,
  extractReleaseHighlights,
  sendFeishuNotification,
  truncate,
} from './feishu-notify.mjs';

const repository = { full_name: 'owner/Palmos' };
const sender = { login: 'developer' };

test('creates the documented Feishu signature', () => {
  assert.equal(
    createFeishuSignature('1700000000', 'example-secret'),
    'Gs3YRutIJpVN2FvEXKXHU6bEj2pVdSriQ0niig9EbUk=',
  );
});

test('normalizes whitespace and truncates untrusted text', () => {
  assert.equal(truncate('line one\nline two', 30), 'line one line two');
  assert.equal(truncate('A'.repeat(10), 5), 'AAAA…');
});

test('builds push and merged pull request notifications', () => {
  const sha = 'a'.repeat(40);
  const push = buildNotification('push', {
    repository,
    sender,
    ref: 'refs/heads/main',
    after: sha,
    size: 2,
    commits: [{ id: sha }, { id: 'b'.repeat(40) }],
    head_commit: { message: 'feat: release' },
  });
  assert.equal(push.title, 'Palmos 代码已推送');
  assert.match(push.details[3], /提交：2 个/);

  const pullRequest = buildNotification('pull_request_target', {
    repository,
    sender,
    action: 'closed',
    pull_request: { number: 7, title: 'Ship', state: 'closed', merged: true },
  });
  assert.equal(pullRequest.title, 'Palmos PR 已合并');
  assert.equal(pullRequest.color, 'green');
});

test('normalizes every configured collaboration event', () => {
  const cases = [
    ['issues', { repository, sender, action: 'opened', issue: { number: 2, title: 'Issue' } }],
    ['issue_comment', {
      repository,
      sender,
      issue: { number: 2, title: 'Issue' },
      comment: { body: 'Comment' },
    }],
    ['pull_request_review', {
      repository,
      sender,
      pull_request: { number: 3, title: 'PR' },
      review: { state: 'approved' },
    }],
  ];

  for (const [eventName, event] of cases) {
    const notification = buildNotification(eventName, event);
    assert.match(notification.title, /^Palmos /);
    assert.ok(notification.button.url);
  }
});

test('suppresses successful feature CI and successful release workflow runs', () => {
  assert.equal(buildNotification('workflow_run', {
    repository,
    workflow_run: { name: 'CI', conclusion: 'success', event: 'push', head_branch: 'feature' },
  }), null);
  assert.equal(buildNotification('workflow_run', {
    repository,
    workflow_run: { name: 'Release', conclusion: 'success', event: 'workflow_run', head_branch: 'main' },
  }), null);
});

test('reports main CI success and release workflow failure', () => {
  const mainCI = buildNotification('workflow_run', {
    repository,
    workflow_run: { name: 'CI', conclusion: 'success', event: 'push', head_branch: 'main' },
  });
  assert.equal(mainCI.color, 'green');

  const releaseFailure = buildNotification('workflow_run', {
    repository,
    workflow_run: { name: 'Release', conclusion: 'failure', head_branch: 'main' },
  });
  assert.equal(releaseFailure.color, 'red');
});

test('extracts at most three release highlights', () => {
  assert.deepEqual(extractReleaseHighlights('- One\n- Two\nText\n* Three\n- Four'), [
    '• One',
    '• Two',
    '• Three',
  ]);
});

test('builds a release card with Palmos packaging facts', () => {
  const notification = buildNotification('release', {
    repository,
    sender,
    release: {
      tag_name: 'v1.1.0-beta.1',
      prerelease: true,
      html_url: 'https://github.com/owner/Palmos/releases/tag/v1.1.0-beta.1',
      body: '- Added automation.',
      assets: [{
        name: 'Palmos-v1.1.0-beta.1.dmg',
        browser_download_url: 'https://github.com/owner/Palmos/releases/download/v1.1.0-beta.1/Palmos-v1.1.0-beta.1.dmg',
      }],
    },
  });
  const card = buildCard(notification);
  assert.equal(card.header.template, 'green');
  assert.equal(card.elements[1].actions.length, 2);
  assert.ok(notification.details.includes('架构：arm64'));
  assert.ok(notification.details.includes('SMART Helper：已随 App 签名打包'));
});

test('builds an automated release dispatch card', () => {
  const notification = buildNotification('repository_dispatch', {
    repository,
    sender,
    client_payload: {
      version: '1.1.0-beta.1',
      prerelease: true,
      dmg_name: 'Palmos-v1.1.0-beta.1.dmg',
      changelog: '- Added automation.',
      release_url: 'https://github.com/owner/Palmos/releases/tag/v1.1.0-beta.1',
      download_url: 'https://github.com/owner/Palmos/releases/download/v1.1.0-beta.1/Palmos-v1.1.0-beta.1.dmg',
    },
  });
  const card = buildCard(notification);
  assert.equal(notification.title, 'Palmos 1.1.0-beta.1 发布成功');
  assert.equal(card.elements[1].actions.length, 2);
});

test('retries transient Feishu responses and accepts a successful response', async () => {
  const responses = [
    { ok: false, status: 500 },
    { ok: true, status: 200, json: async () => ({ code: 0 }) },
  ];
  let attempts = 0;
  await sendFeishuNotification({}, 'https://example.com', {
    fetchImplementation: async () => {
      attempts += 1;
      return responses.shift();
    },
    wait: async () => {},
  });
  assert.equal(attempts, 2);
});

test('does not retry a permanent Feishu rejection', async () => {
  let attempts = 0;
  await assert.rejects(sendFeishuNotification({}, 'https://example.com', {
    fetchImplementation: async () => {
      attempts += 1;
      return { ok: true, status: 200, json: async () => ({ code: 19001 }) };
    },
    wait: async () => {},
  }));
  assert.equal(attempts, 1);
});
