import assert from 'node:assert/strict';
import test from 'node:test';

import {
  buildDiscordPayload,
  buildNotification,
  escapeDiscordMarkdown,
  extractReleaseHighlights,
  sendDiscordNotification,
  truncate,
} from './discord-notify.mjs';

const repository = { full_name: 'owner/Palmos' };
const sender = { login: 'developer' };

test('normalizes whitespace, truncates, and escapes untrusted Markdown', () => {
  assert.equal(truncate('line one\nline two', 30), 'line one line two');
  assert.equal(truncate('A'.repeat(10), 5), 'AAAA…');
  assert.equal(escapeDiscordMarkdown('**bold** [link] <@123>'), '\\*\\*bold\\*\\* \\[link\\] \\<@123\\>');
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
  assert.equal(pullRequest.color, 0x57F287);
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
  assert.equal(mainCI.color, 0x57F287);

  const releaseFailure = buildNotification('workflow_run', {
    repository,
    workflow_run: { name: 'Release', conclusion: 'failure', head_branch: 'main' },
  });
  assert.equal(releaseFailure.color, 0xED4245);
});

test('reports CI request and suppresses Release planning request', () => {
  const sha = 'a'.repeat(40);
  const ciRequested = buildNotification('workflow_run', {
    repository,
    action: 'requested',
    workflow_run: {
      name: 'CI',
      event: 'pull_request',
      head_branch: 'feature',
      head_sha: sha,
      run_number: 12,
      html_url: 'https://github.com/owner/Palmos/actions/runs/12',
    },
  });
  assert.equal(ciRequested.title, 'Palmos CI 已触发');
  assert.equal(ciRequested.color, 0x5865F2);
  assert.ok(ciRequested.details.includes('提交：aaaaaaa'));

  assert.equal(buildNotification('workflow_run', {
    repository,
    action: 'requested',
    workflow_run: { name: 'Release', head_branch: 'main' },
  }), null);
});

test('extracts at most three release highlights', () => {
  assert.deepEqual(extractReleaseHighlights('- One\n- Two\nText\n* Three\n- Four'), [
    '• One',
    '• Two',
    '• Three',
  ]);
});

test('builds a Discord release embed with Palmos packaging facts and safe links', () => {
  const notification = buildNotification('release', {
    repository,
    sender,
    release: {
      tag_name: 'v1.1.0-beta.1',
      prerelease: true,
      html_url: 'https://github.com/owner/Palmos/releases/tag/v1.1.0-beta.1',
      body: '- Added **automation**.',
      assets: [{
        name: 'Palmos-v1.1.0-beta.1.dmg',
        browser_download_url: 'https://github.com/owner/Palmos/releases/download/v1.1.0-beta.1/Palmos-v1.1.0-beta.1.dmg',
      }],
    },
  });
  const payload = buildDiscordPayload(notification);
  assert.equal(payload.username, 'Palmos');
  assert.deepEqual(payload.allowed_mentions, { parse: [] });
  assert.equal(payload.embeds.length, 1);
  assert.equal(payload.embeds[0].color, 0x57F287);
  assert.equal(payload.embeds[0].url, notification.button.url);
  assert.match(payload.embeds[0].description, /SMART Helper：已随 App 签名打包/);
  assert.ok(payload.embeds[0].description.includes('• Added \\*\\*automation\\*\\*.'));
  assert.match(payload.embeds[0].description, /\[查看版本\]\(https:\/\/github\.com\/owner\/Palmos\/releases\/tag\/v1\.1\.0-beta\.1\)/);
  assert.match(payload.embeds[0].description, /\[下载 DMG\]/);
  assert.equal('components' in payload, false);
});

test('escapes event text and prevents Discord mentions', () => {
  const notification = buildNotification('issue_comment', {
    repository,
    sender,
    issue: { number: 2, title: '[click](https://attacker.invalid)' },
    comment: { body: '**@everyone** <@123>' },
  });
  const payload = buildDiscordPayload(notification);
  assert.match(payload.embeds[0].description, /\\\[click\\\]\\\(https:\/\/attacker\.invalid\\\)/);
  assert.match(payload.embeds[0].description, /\\\*\\\*@everyone\\\*\\\* \\<@123\\>/);
  assert.deepEqual(payload.allowed_mentions.parse, []);
});

test('builds a packaging-started dispatch with Palmos packaging facts', () => {
  const notification = buildNotification('repository_dispatch', {
    repository,
    sender,
    action: 'release_started',
    client_payload: {
      version: '0.1.0-beta.4',
      prerelease: true,
      dmg_name: 'Palmos-v0.1.0-beta.4.dmg',
      sha: 'a'.repeat(40),
      run_url: 'https://github.com/owner/Palmos/actions/runs/12',
    },
  });
  assert.equal(notification.title, 'Palmos 0.1.0-beta.4 开始打包');
  assert.equal(notification.color, 0x5865F2);
  assert.ok(notification.details.includes('架构：arm64'));
  assert.ok(notification.details.includes('SMART Helper：将随 App 签名打包'));
  assert.ok(notification.details.includes('提交：aaaaaaa'));
  assert.equal(notification.button.url, 'https://github.com/owner/Palmos/actions/runs/12');
  assert.equal(buildNotification('repository_dispatch', { action: 'other_event' }), null);
});

test('accepts any Discord 2xx response and preserves wait=true', async () => {
  let endpoint;
  await sendDiscordNotification({}, 'https://discord.com/api/webhooks/id/token?thread_id=1', {
    fetchImplementation: async (url) => {
      endpoint = url;
      return { status: 204 };
    },
  });
  assert.equal(endpoint, 'https://discord.com/api/webhooks/id/token?thread_id=1&wait=true');
});

test('retries 429 using Retry-After, retries 5xx with backoff, and retries network failures', async () => {
  const waits = [];
  const responses = [
    { status: 429, headers: { get: () => '1.5' } },
    { status: 500 },
    { status: 200 },
  ];
  await sendDiscordNotification({}, 'https://discord.com/api/webhooks/id/token', {
    fetchImplementation: async () => responses.shift(),
    wait: async (milliseconds) => { waits.push(milliseconds); },
  });
  assert.deepEqual(waits, [1_500, 500]);

  let attempts = 0;
  await sendDiscordNotification({}, 'https://discord.com/api/webhooks/id/token', {
    fetchImplementation: async () => {
      attempts += 1;
      if (attempts === 1) throw new Error('offline');
      return { status: 200 };
    },
    wait: async () => {},
  });
  assert.equal(attempts, 2);
});

test('uses retry_after response data for 429 and does not retry permanent Discord responses', async () => {
  const waits = [];
  const responses = [
    { status: 429, headers: { get: () => null }, json: async () => ({ retry_after: 0.25 }) },
    { status: 201 },
  ];
  await sendDiscordNotification({}, 'https://discord.com/api/webhooks/id/token', {
    fetchImplementation: async () => responses.shift(),
    wait: async (milliseconds) => { waits.push(milliseconds); },
  });
  assert.deepEqual(waits, [250]);

  let attempts = 0;
  await assert.rejects(sendDiscordNotification({}, 'https://discord.com/api/webhooks/id/token', {
    fetchImplementation: async () => {
      attempts += 1;
      return { status: 400 };
    },
    wait: async () => {},
  }));
  assert.equal(attempts, 1);
});

test('rejects an invalid webhook URL without echoing its value', async () => {
  const invalidWebhook = 'not-a-url-with-secret-token';
  await assert.rejects(
    sendDiscordNotification({}, invalidWebhook),
    (error) => error.message === 'DISCORD_WEBHOOK_URL is invalid.' && !error.message.includes(invalidWebhook),
  );
});
