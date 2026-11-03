import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';
import vm from 'node:vm';

const source = await readFile(process.env.WORKER_TEST_SOURCE || new URL('../_worker.js', import.meta.url), 'utf8');
const worker = (await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)).default;
const TEMPLATE_ROOT = 'https://raw.githubusercontent.com/DustinWin/ruleset_geodata/main/rule_templates/';
const FULL = TEMPLATE_ROOT + 'DustinWin_Full.ini';
const LITE = TEMPLATE_ROOT + 'DustinWin_Lite.ini';
const CUSTOM = 'https://config.example.com/custom.ini?theme=one&mode=two';
const LEGACY = ['acl4ssr-multimode', 'acl4ssr-full', 'enihsyou', 'clashcustomrule'];
const NODE = 'vless://00000000-0000-4000-8000-000000000001@origin.example.com:443?security=tls&type=ws#fixture';

async function conversion(params = {}, env = {}, legacyRoute = false) {
  const originalFetch = globalThis.fetch;
  let converterRequest;
  globalThis.fetch = async input => {
    const url = new URL(typeof input === 'string' ? input : input.url);
    if (url.href === 'https://fixture.example/ips.csv') return new Response('');
    if (url.href === 'https://fixture.example/fixed.txt') return new Response('192.0.2.1:443#fixture');
    assert.equal(url.hostname, 'converter.example.com');
    converterRequest = url;
    return new Response('proxies:\n  - name: fixture\n');
  };
  try {
    const url = new URL('http://localhost:8787/sub');
    const nodeParams = legacyRoute ? { host: 'origin.example.com', uuid: '00000000-0000-4000-8000-000000000001' } : { node64: Buffer.from(NODE).toString('base64url') };
    for (const [key, value] of Object.entries({ ...nodeParams, format: 'clash', ...params })) url.searchParams.set(key, value);
    const response = await worker.fetch(new Request(url), {
      BEST_IP_CSV: 'https://fixture.example/ips.csv',
      FIXED_ADDRESSES_URL: 'https://fixture.example/fixed.txt',
      SUBAPI: 'https://converter.example.com', ADD: '192.0.2.1:443#fixture', ...env
    });
    return { status: response.status, body: await response.text(), converterRequest };
  } finally {
    globalThis.fetch = originalFetch;
  }
}

test('新默认与 Full/Lite 预设使用当前 DustinWin URL', async () => {
  for (const [params, expected] of [[{}, FULL], [{ configPreset: 'dustinwin-full' }, FULL], [{ configPreset: 'dustinwin-lite' }, LITE]]) {
    const result = await conversion(params);
    assert.equal(result.status, 200, result.body);
    assert.equal(result.converterRequest.searchParams.get('config'), expected);
  }
});

test('旧订阅 URL 的四个 preset ID 迁移到 Full，不再使用旧模板', async () => {
  for (const configPreset of LEGACY) {
    const result = await conversion({ configPreset });
    assert.equal(result.status, 200, result.body);
    assert.equal(result.converterRequest.searchParams.get('config'), FULL);
  }
});

test('显式 URL、preset 和 SUBCONFIG 保持优先级，自定义旧 URL 不被改写', async () => {
  const oldExplicit = 'https://raw.githubusercontent.com/cmliu/ACL4SSR/main/Clash/config/ACL4SSR_Online_Full_MultiMode.ini';
  for (const [params, env, expected] of [
    [{}, { SUBCONFIG: CUSTOM }, CUSTOM],
    [{ configPreset: 'dustinwin-lite' }, { SUBCONFIG: CUSTOM }, LITE],
    [{ config: CUSTOM, configPreset: 'dustinwin-lite' }, { SUBCONFIG: oldExplicit }, CUSTOM],
    [{ config: oldExplicit, configPreset: 'acl4ssr-full' }, {}, oldExplicit],
    [{}, { SUBCONFIG: oldExplicit }, oldExplicit],
    [{}, {}, FULL]
  ]) {
    const result = await conversion(params, env);
    assert.equal(result.status, 200, result.body);
    assert.equal(result.converterRequest.searchParams.get('config'), expected);
  }
});

test('旧 host/uuid 转换入口也使用新默认，环境覆盖不会污染下个请求', async () => {
  for (const [env, expected] of [[{}, FULL], [{ SUBCONFIG: CUSTOM }, CUSTOM], [{}, FULL]]) {
    const result = await conversion({}, env, true);
    assert.equal(result.status, 200, result.body);
    assert.equal(result.converterRequest.searchParams.get('config'), expected);
  }
});

test('未知 preset 与原型属性不会成为配置 URL，非法自定义协议仍被拒绝', async () => {
  for (const configPreset of ['missing-preset', '__proto__', 'constructor', 'toString']) {
    const result = await conversion({ configPreset });
    assert.equal(result.status, 400);
    assert.match(result.body, /未知的 configPreset/);
    assert.equal(result.converterRequest, undefined);
  }
  for (const config of ['not-a-url', 'javascript:alert(1)', 'file:///tmp/config.ini']) {
    const result = await conversion({ config });
    assert.equal(result.status, 400);
    assert.match(result.body, /config /);
    assert.equal(result.converterRequest, undefined);
  }
});

async function homepage(env = {}) {
  const response = await worker.fetch(new Request('http://localhost:8787/'), env);
  assert.equal(response.status, 200);
  return response.text();
}

function pageRuntime(html, savedState = {}) {
  const select = html.match(/<select id="configPreset"[^>]*>([\s\S]*?)<\/select>/)[1];
  const options = [...select.matchAll(/<option value="([^"]*)">/g)].map(match => ({ value: match[1] }));
  const elements = Object.fromEntries(['link', 'format', 'configPreset', 'configUrl', 'configGroup', 'result', 'qrcode'].map(id => [id, { value: '', style: {} }]));
  elements.format.value = 'base64';
  elements.configPreset.options = options;
  let storage = typeof savedState === 'string' ? savedState : JSON.stringify(savedState);
  let onReady;
  const alerts = [];
  const QRCode = function () {};
  QRCode.CorrectLevel = { L: 1 };
  const context = vm.createContext({
    document: { getElementById: id => elements[id], addEventListener() {} },
    window: { addEventListener(name, callback) { if (name === 'DOMContentLoaded') onReady = callback; }, location: { hostname: 'subscription.example.com', search: '?token=fixture-token' } },
    localStorage: { getItem() { return storage; }, setItem(key, value) { assert.equal(key, 'worker-vless2sub-form-v1'); storage = value; } },
    URLSearchParams, atob, btoa, QRCode, alert(message) { alerts.push(message); }
  });
  for (const [, script] of html.matchAll(/<script>([\s\S]*?)<\/script>/g)) vm.runInContext(script, context);
  assert.equal(typeof onReady, 'function');
  onReady();
  return { context, elements, alerts, restore: onReady, stored: () => JSON.parse(storage) };
}

test('首页只列出 Full、Lite 和自定义，环境覆盖时默认标签不冒充 Full', async () => {
  const html = await homepage();
  const page = pageRuntime(html);
  assert.deepEqual(page.elements.configPreset.options.map(option => option.value), ['', 'dustinwin-full', 'dustinwin-lite', 'custom']);
  assert.match(html, /默认配置（DustinWin Full）/);
  assert.match(html, /其他客户端需确认兼容性/);
  const customHtml = await homepage({ SUBCONFIG: CUSTOM });
  assert.match(customHtml, /默认配置（部署环境指定）/);
  assert.doesNotMatch(customHtml, /默认配置（DustinWin Full）/);
  assert.match(await homepage(), /默认配置（DustinWin Full）/);
});

test('浏览器 v1 旧选择迁移并保存；再次加载及生成链接使用新 preset', async () => {
  const html = await homepage();
  for (const configPreset of LEGACY) {
    const page = pageRuntime(html, { link: NODE, format: 'clash', configPreset, configUrl: CUSTOM });
    assert.equal(page.elements.configPreset.value, 'dustinwin-full');
    assert.equal(page.stored().configPreset, 'dustinwin-full');
    assert.equal(page.stored().configUrl, CUSTOM);
    page.restore();
    vm.runInContext('generateLink()', page.context);
    const generated = new URL(page.elements.result.value);
    assert.equal(generated.searchParams.get('configPreset'), 'dustinwin-full');
    assert.equal(generated.searchParams.get('token'), 'fixture-token');
    assert.equal(Buffer.from(generated.searchParams.get('node64'), 'base64url').toString(), NODE);
    assert.equal(page.elements.configUrl.style.display, 'none');
    assert.deepEqual(page.alerts, []);
  }
});

test('自定义 URL 与新 Lite 选择恢复正常，反复切换及 Base64 隐藏不串配置', async () => {
  const page = pageRuntime(await homepage(), { link: NODE, format: 'clash', configPreset: 'custom', configUrl: CUSTOM });
  assert.equal(page.elements.configPreset.value, 'custom');
  assert.equal(page.elements.configUrl.value, CUSTOM);
  assert.equal(page.elements.configUrl.style.display, 'block');
  vm.runInContext('generateLink()', page.context);
  assert.equal(new URL(page.elements.result.value).searchParams.get('config'), CUSTOM);
  page.elements.configPreset.value = 'dustinwin-lite';
  vm.runInContext('toggleCustomConfig(); saveFormState(); generateLink()', page.context);
  assert.equal(page.elements.configUrl.style.display, 'none');
  assert.equal(page.stored().configPreset, 'dustinwin-lite');
  assert.equal(new URL(page.elements.result.value).searchParams.get('configPreset'), 'dustinwin-lite');
  page.restore();
  assert.equal(page.elements.configPreset.value, 'dustinwin-lite');
  page.elements.format.value = 'base64';
  vm.runInContext('updateConfigVisibility(); generateLink()', page.context);
  assert.equal(page.elements.configGroup.style.display, 'none');
  const base64Url = new URL(page.elements.result.value);
  assert.equal(base64Url.searchParams.has('config'), false);
  assert.equal(base64Url.searchParams.has('configPreset'), false);
  assert.deepEqual(page.alerts, []);
});

test('损坏或未知旧存储可安全回退默认，不清除已填自定义 URL', async () => {
  const html = await homepage();
  for (const saved of ['not-json', { configPreset: 'unknown-preset', configUrl: CUSTOM }]) {
    const page = pageRuntime(html, saved);
    assert.equal(page.elements.configPreset.value, '');
    assert.equal(page.elements.configUrl.style.display, 'none');
    if (typeof saved !== 'string') assert.equal(page.elements.configUrl.value, CUSTOM);
  }
});
