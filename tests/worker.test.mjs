import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(process.env.WORKER_TEST_SOURCE || new URL('../_worker.js', import.meta.url), 'utf8');
const worker = (await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)).default;

test('首页在 Node 运行时返回页面，不抛出摘要算法错误', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = () => {
    throw new Error('首页不应访问外部服务');
  };

  try {
    const response = await worker.fetch(new Request('http://localhost:8787/'), {});
    assert.equal(response.status, 200);
    assert.match(response.headers.get('content-type'), /text\/html/i);
    assert.match(await response.text(), /优选订阅生成器/);
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('转换请求使用有效的临时 UUID，并在响应中恢复原 UUID', async () => {
  const originalFetch = globalThis.fetch;
  const originalUuid = '00000000-0000-4000-8000-000000000001';
  let converterRequest;
  let temporaryUuid;
  globalThis.fetch = async input => {
    converterRequest = new URL(typeof input === 'string' ? input : input.url);
    assert.equal(converterRequest.hostname, 'converter.example.com');
    const subscription = new URL(converterRequest.searchParams.get('url'));
    temporaryUuid = subscription.searchParams.get('uuid');
    return new Response(`proxies:\n  - uuid: ${temporaryUuid}\n`);
  };

  try {
    const request = new Request(`http://localhost:8787/sub?host=origin.example.com&uuid=${originalUuid}&format=clash`);
    const response = await worker.fetch(request, {
      SUBAPI: 'https://converter.example.com',
      SUBCONFIG: 'https://config.example.com/config.ini',
      ADD: '192.0.2.1:443#fixture'
    });
    assert.ok(converterRequest);
    assert.match(temporaryUuid, /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i);
    assert.equal(response.status, 200);
    assert.match(await response.text(), new RegExp(originalUuid));
  } finally {
    globalThis.fetch = originalFetch;
  }
});
