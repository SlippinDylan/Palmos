import { readFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const PRODUCT_NAME = 'Palmos';
const MAX_TITLE_LENGTH = 120;
const MAX_CONTENT_LENGTH = 280;
const MAX_CHANGELOG_ITEMS = 3;
const SHA_PATTERN = /^[0-9a-f]{40}$/i;

const COLORS = {
  blue: 0x5865F2,
  green: 0x57F287,
  red: 0xED4245,
  grey: 0x99AAB5,
};

const RESULT_COLORS = new Map([
  ['success', COLORS.green],
  ['failure', COLORS.red],
  ['timed_out', COLORS.red],
  ['action_required', COLORS.red],
  ['cancelled', COLORS.grey],
  ['skipped', COLORS.grey],
  ['neutral', COLORS.grey],
  ['stale', COLORS.grey],
]);

export function truncate(value, maximumLength) {
  const normalized = String(value ?? '').replace(/\s+/g, ' ').trim();
  if (normalized.length <= maximumLength) return normalized;
  return `${normalized.slice(0, maximumLength - 1)}…`;
}

export function escapeDiscordMarkdown(value) {
  return String(value ?? '').replace(/([\\`*_{}\[\]()<>#+=|~>-])/g, '\\$1');
}

function requiredEnvironment(name) {
  const value = process.env[name];
  if (!value) throw new Error(`${name} is not configured.`);
  return value;
}

function repositoryName(event) {
  return event.repository?.full_name ?? process.env.GITHUB_REPOSITORY ?? '未知仓库';
}

function actorName(event) {
  return event.workflow_run?.actor?.login
    ?? event.release?.author?.login
    ?? event.sender?.login
    ?? process.env.GITHUB_ACTOR
    ?? '未知用户';
}

function repositoryUrl(event) {
  const server = (process.env.GITHUB_SERVER_URL ?? 'https://github.com').replace(/\/$/, '');
  return `${server}/${repositoryName(event)}`;
}

function safeGitHubUrl(value, fallback) {
  try {
    const candidate = new URL(value);
    const server = new URL(process.env.GITHUB_SERVER_URL ?? 'https://github.com');
    if (candidate.protocol === 'https:' && candidate.hostname === server.hostname) return candidate.href;
  } catch {
    // Invalid event URLs fall back to the repository instead of reaching the webhook.
  }
  return fallback;
}

function shortSha(value) {
  return SHA_PATTERN.test(value ?? '') ? value.slice(0, 7) : '未知';
}

function commonDetails(event, values) {
  return [
    `仓库：${truncate(repositoryName(event), MAX_TITLE_LENGTH)}`,
    `操作者：${truncate(actorName(event), MAX_TITLE_LENGTH)}`,
    ...values.filter(Boolean).map((value) => truncate(value, MAX_CONTENT_LENGTH)),
  ];
}

function buildPush(event) {
  const repoUrl = repositoryUrl(event);
  const branch = String(event.ref ?? '').replace(/^refs\/heads\//, '') || '未知分支';
  const commits = Array.isArray(event.commits) ? event.commits : [];
  const sha = event.after;
  const commitUrl = SHA_PATTERN.test(sha ?? '') ? `${repoUrl}/commit/${sha}` : repoUrl;

  return {
    title: `${PRODUCT_NAME} 代码已推送`,
    details: commonDetails(event, [
      `分支：${branch}`,
      `提交：${event.size ?? (commits.length || (event.head_commit ? 1 : 0))} 个`,
      `最新：${shortSha(sha)} ${truncate(event.head_commit?.message, MAX_CONTENT_LENGTH) || '无提交说明'}`,
    ]),
    button: { text: '查看提交', url: commitUrl },
    color: COLORS.blue,
  };
}

function pullRequestTitle(action, merged) {
  if (action === 'closed' && merged) return `${PRODUCT_NAME} PR 已合并`;
  const titles = {
    opened: `${PRODUCT_NAME} PR 已创建`,
    reopened: `${PRODUCT_NAME} PR 已重新打开`,
    ready_for_review: `${PRODUCT_NAME} PR 已可审查`,
    review_requested: `${PRODUCT_NAME} PR 请求审查`,
    closed: `${PRODUCT_NAME} PR 已关闭`,
  };
  return titles[action] ?? `${PRODUCT_NAME} PR 已更新`;
}

function buildPullRequest(event) {
  const repoUrl = repositoryUrl(event);
  const pullRequest = event.pull_request ?? {};
  const reviewer = event.requested_reviewer?.login ?? event.requested_team?.name;
  return {
    title: pullRequestTitle(event.action, pullRequest.merged),
    details: commonDetails(event, [
      `PR #${pullRequest.number ?? event.number ?? '未知'}：${truncate(pullRequest.title, MAX_TITLE_LENGTH)}`,
      `状态：${pullRequest.merged ? '已合并' : pullRequest.draft ? '草稿' : pullRequest.state ?? '未知'}`,
      reviewer ? `审查人：${reviewer}` : '',
    ]),
    button: { text: '查看 PR', url: safeGitHubUrl(pullRequest.html_url, repoUrl) },
    color: pullRequest.merged ? COLORS.green : event.action === 'closed' ? COLORS.grey : COLORS.blue,
  };
}

function issueAction(action) {
  return {
    opened: '已创建',
    reopened: '已重新打开',
    closed: '已关闭',
    assigned: '已分配',
  }[action] ?? '已更新';
}

function buildIssue(event) {
  const repoUrl = repositoryUrl(event);
  const issue = event.issue ?? {};
  return {
    title: `${PRODUCT_NAME} Issue ${issueAction(event.action)}`,
    details: commonDetails(event, [
      `Issue #${issue.number ?? '未知'}：${truncate(issue.title, MAX_TITLE_LENGTH)}`,
      event.assignee?.login ? `负责人：${event.assignee.login}` : '',
    ]),
    button: { text: '查看 Issue', url: safeGitHubUrl(issue.html_url, repoUrl) },
    color: event.action === 'closed' ? COLORS.grey : COLORS.blue,
  };
}

function buildIssueComment(event) {
  const repoUrl = repositoryUrl(event);
  const issue = event.issue ?? {};
  const comment = event.comment ?? {};
  const kind = issue.pull_request ? 'PR' : 'Issue';
  return {
    title: `${PRODUCT_NAME} ${kind} 有新评论`,
    details: commonDetails(event, [
      `${kind} #${issue.number ?? '未知'}：${truncate(issue.title, MAX_TITLE_LENGTH)}`,
      `评论：${truncate(comment.body, MAX_CONTENT_LENGTH) || '（无文字内容）'}`,
    ]),
    button: { text: '查看评论', url: safeGitHubUrl(comment.html_url, repoUrl) },
    color: COLORS.blue,
  };
}

function buildReview(event) {
  const repoUrl = repositoryUrl(event);
  const pullRequest = event.pull_request ?? {};
  const review = event.review ?? {};
  const state = String(review.state ?? '未知').toLowerCase();
  return {
    title: `${PRODUCT_NAME} PR 收到审查`,
    details: commonDetails(event, [
      `PR #${pullRequest.number ?? event.number ?? '未知'}：${truncate(pullRequest.title, MAX_TITLE_LENGTH)}`,
      `结论：${state}`,
      review.body ? `内容：${truncate(review.body, MAX_CONTENT_LENGTH)}` : '',
    ]),
    button: { text: '查看 PR', url: safeGitHubUrl(pullRequest.html_url, repoUrl) },
    color: state === 'approved' ? COLORS.green : state === 'changes_requested' ? COLORS.red : COLORS.blue,
  };
}

function conclusionLabel(conclusion) {
  return {
    success: '成功',
    failure: '失败',
    cancelled: '已取消',
    timed_out: '超时',
    action_required: '需要人工处理',
    skipped: '已跳过',
    neutral: '已结束',
    stale: '已过期',
  }[conclusion] ?? '结果未知';
}

function buildWorkflowRun(event) {
  const repoUrl = repositoryUrl(event);
  const run = event.workflow_run ?? {};
  const action = String(event.action ?? '').toLowerCase();
  const conclusion = String(run.conclusion ?? '').toLowerCase();

  if (action === 'requested') {
    if (run.name !== 'CI') return null;
    return {
      title: `${PRODUCT_NAME} CI 已触发`,
      details: commonDetails(event, [
        `分支：${run.head_branch ?? '未知'}`,
        `提交：${shortSha(run.head_sha)}`,
        `运行：#${run.run_number ?? '未知'}`,
        `触发：${run.event ?? '未知'}`,
      ]),
      button: { text: '查看运行', url: safeGitHubUrl(run.html_url, repoUrl) },
      color: COLORS.blue,
    };
  }

  if (run.name === 'Release' && conclusion === 'success') return null;
  if (run.name === 'CI' && conclusion === 'success' && run.event !== 'pull_request' && run.head_branch !== 'main') {
    return null;
  }

  const workflowLabel = run.name === 'Release' ? '版本发布' : 'CI';
  return {
    title: `${PRODUCT_NAME} ${workflowLabel}${conclusionLabel(conclusion)}`,
    details: commonDetails(event, [
      `分支：${run.head_branch ?? '未知'}`,
      `提交：${shortSha(run.head_sha)}`,
      `运行：#${run.run_number ?? '未知'}`,
      `结果：${conclusionLabel(conclusion)}`,
    ]),
    button: { text: '查看运行', url: safeGitHubUrl(run.html_url, repoUrl) },
    color: RESULT_COLORS.get(conclusion) ?? COLORS.blue,
  };
}

export function extractReleaseHighlights(body) {
  return String(body ?? '')
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => /^[-*] /.test(line))
    .slice(0, MAX_CHANGELOG_ITEMS)
    .map((line) => truncate(line.replace(/^[-*] /, '• '), MAX_CONTENT_LENGTH));
}

function releaseDetails(event, release) {
  return commonDetails(event, [
    `类型：${release.prerelease ? 'Pre-release' : 'Stable'}`,
    release.dmgName ? `制品：${release.dmgName}` : '',
    '架构：arm64',
    '签名：Apple Development（未公证）',
    'SMART Helper：已随 App 签名打包',
    ...extractReleaseHighlights(release.body),
  ]);
}

function buildRelease(event) {
  const repoUrl = repositoryUrl(event);
  const release = event.release ?? {};
  const version = String(release.tag_name ?? '未知版本').replace(/^v/, '');
  const asset = release.assets?.find((candidate) => String(candidate.name ?? '').endsWith('.dmg'));
  return {
    title: `${PRODUCT_NAME} ${version} 发布成功`,
    details: releaseDetails(event, {
      prerelease: release.prerelease,
      dmgName: asset?.name,
      body: release.body,
    }),
    button: { text: '查看版本', url: safeGitHubUrl(release.html_url, repoUrl) },
    secondaryButton: asset
      ? { text: '下载 DMG', url: safeGitHubUrl(asset.browser_download_url, repoUrl) }
      : null,
    color: COLORS.green,
  };
}

function buildReleaseStarted(event) {
  const repoUrl = repositoryUrl(event);
  const payload = event.client_payload ?? {};
  return {
    title: `${PRODUCT_NAME} ${payload.version ?? '未知版本'} 开始打包`,
    details: commonDetails(event, [
      `类型：${payload.prerelease ? 'Pre-release' : 'Stable'}`,
      payload.dmg_name ? `制品：${payload.dmg_name}` : '',
      '架构：arm64',
      'SMART Helper：将随 App 签名打包',
      `提交：${shortSha(payload.sha)}`,
    ]),
    button: { text: '查看运行', url: safeGitHubUrl(payload.run_url, repoUrl) },
    color: COLORS.blue,
  };
}

function buildRepositoryDispatch(event) {
  return event.action === 'release_started' ? buildReleaseStarted(event) : null;
}

const BUILDERS = {
  push: buildPush,
  pull_request_target: buildPullRequest,
  issues: buildIssue,
  issue_comment: buildIssueComment,
  pull_request_review: buildReview,
  workflow_run: buildWorkflowRun,
  release: buildRelease,
  repository_dispatch: buildRepositoryDispatch,
};

export function buildNotification(eventName, event) {
  const builder = BUILDERS[eventName];
  return builder ? builder(event) : null;
}

function markdownLink(button) {
  const url = button.url.replace(/([\\()])/g, '\\$1');
  return `[${escapeDiscordMarkdown(button.text)}](${url})`;
}

export function buildDiscordPayload(notification) {
  const actions = [notification.button, notification.secondaryButton]
    .filter(Boolean)
    .map(markdownLink)
    .join(' · ');
  const description = [
    notification.details.map(escapeDiscordMarkdown).join('\n'),
    actions,
  ].filter(Boolean).join('\n\n');

  return {
    username: PRODUCT_NAME,
    allowed_mentions: { parse: [] },
    embeds: [{
      title: escapeDiscordMarkdown(truncate(notification.title, MAX_TITLE_LENGTH)),
      url: notification.button.url,
      description,
      color: notification.color,
    }],
  };
}

function retryableStatus(status) {
  return status === 429 || status >= 500;
}

function retryAfterMilliseconds(value) {
  if (value === null || value === undefined || value === '') return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds) && seconds >= 0) return Math.ceil(seconds * 1_000);
  const retryAt = Date.parse(value);
  return Number.isNaN(retryAt) ? null : Math.max(0, retryAt - Date.now());
}

async function retryDelay(response, fallback) {
  const headerDelay = retryAfterMilliseconds(response.headers?.get?.('Retry-After'));
  if (headerDelay !== null) return headerDelay;

  try {
    const body = await response.json?.();
    const bodyDelay = retryAfterMilliseconds(body?.retry_after);
    if (bodyDelay !== null) return bodyDelay;
  } catch {
    // A malformed retry body falls back to bounded exponential backoff.
  }
  return fallback;
}

function discordWebhookUrl(webhook) {
  let url;
  try {
    url = new URL(webhook);
  } catch {
    throw new Error('DISCORD_WEBHOOK_URL is invalid.');
  }
  url.searchParams.set('wait', 'true');
  return url.href;
}

export async function sendDiscordNotification(payload, webhook, options = {}) {
  const fetchImplementation = options.fetchImplementation ?? fetch;
  const wait = options.wait ?? ((milliseconds) => new Promise((resolveWait) => setTimeout(resolveWait, milliseconds)));
  const attempts = options.attempts ?? 3;
  const endpoint = discordWebhookUrl(webhook);
  let lastError;

  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    const fallbackDelay = 250 * (2 ** (attempt - 1));
    let response;
    try {
      response = await fetchImplementation(endpoint, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
        body: JSON.stringify(payload),
        signal: AbortSignal.timeout(10_000),
      });
    } catch {
      lastError = new Error('Discord request failed.');
      if (attempt < attempts) {
        await wait(fallbackDelay);
        continue;
      }
      throw lastError;
    }

    if (response.status >= 200 && response.status < 300) return;

    lastError = new Error(`Discord request returned HTTP ${response.status}.`);
    if (retryableStatus(response.status) && attempt < attempts) {
      await wait(response.status === 429 ? await retryDelay(response, fallbackDelay) : fallbackDelay);
      continue;
    }
    throw lastError;
  }

  throw lastError;
}

async function main() {
  const webhook = requiredEnvironment('DISCORD_WEBHOOK_URL');
  const eventName = requiredEnvironment('GITHUB_EVENT_NAME');
  const eventPath = requiredEnvironment('GITHUB_EVENT_PATH');
  const event = JSON.parse(await readFile(eventPath, 'utf8'));
  const notification = buildNotification(eventName, event);
  if (!notification) return;

  await sendDiscordNotification(buildDiscordPayload(notification), webhook);
}

if (process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1])) {
  main().catch((error) => {
    console.error(`::error::Discord notification failed: ${error.message}`);
    process.exitCode = 1;
  });
}
