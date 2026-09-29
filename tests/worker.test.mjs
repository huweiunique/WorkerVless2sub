import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import test from 'node:test';

const source = await readFile(process.env.WORKER_TEST_SOURCE || new URL('../_worker.js', import.meta.url), 'utf8');
const worker = (await import(`data:text/javascript;base64,${Buffer.from(source).toString('base64')}`)).default;

test('CSV 节点保留地区代码、延迟和速度，兼容 PowerShell 导出的引号', async () => {
  const originalFetch = globalThis.fetch;
  const rows = [
    ['IP 地址', '已发送', '已接收', '丢包率', '平均延迟', '下载速度(MB/s)', '地区码'],
    ['192.0.2.1', '4', '4', '0.00', '85.00', '12.50', 'NRT'],
    ['192.0.2.2', '4', '4', '0.00', '90.00', '10.00', 'SIN'],
    ['192.0.2.3', '4', '4', '0.00', '95.00', '8.00', '']
  ];
  try {
    for (const quoted of [false, true]) {
      const csv = (quoted ? '\uFEFF' : '') + rows.map(row => row.map(cell => quoted ? `"${cell}"` : cell).join(',')).join('\r\n');
      globalThis.fetch = async input => {
        if (String(input) === 'https://fixture.example/ips.csv') return new Response(csv);
        assert.equal(String(input), 'https://fixture.example/fixed.txt');
        return new Response('');
      };
      const request = new URL('http://localhost:8787/sub');
      request.searchParams.set('node', 'vless://00000000-0000-4000-8000-000000000001@origin.example.com:443?security=tls&type=ws#测试节点');
      request.searchParams.set('minSpeed', '5');
      const response = await worker.fetch(new Request(request), {
        BEST_IP_CSV: 'https://fixture.example/ips.csv',
        FIXED_ADDRESSES_URL: 'https://fixture.example/fixed.txt'
      });
      assert.equal(response.status, 200);
      const nodes = Buffer.from(await response.text(), 'base64').toString('utf8').trim().split('\n').map(line => new URL(line));
      assert.deepEqual(nodes.map(node => node.hostname), ['192.0.2.1', '192.0.2.2', '192.0.2.3']);
      assert.deepEqual(nodes.map(node => decodeURIComponent(node.hash.slice(1))), [
        '测试节点-NRT-85.00ms-12.5MB/s',
        '测试节点-SIN-90.00ms-10MB/s',
        '测试节点-95.00ms-8MB/s'
      ]);
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

test('通用订阅清理 TLS 的 REALITY 参数，同时保留 REALITY 参数及连接配置', async () => {
  const originalFetch = globalThis.fetch;
  globalThis.fetch = async input => {
    const url = String(input);
    if (url === 'https://fixture.example/ips.csv') return new Response('');
    assert.equal(url, 'https://fixture.example/fixed.txt');
    return new Response('192.0.2.1:443#fixture');
  };
  try {
    for (const security of ['tls', 'TLS', 'reality']) {
      for (const format of ['base64', 'v2rayn', 'shadowrocket']) {
        for (const inputMode of ['node', 'node64']) {
          const input = new URL('vless://00000000-0000-4000-8000-000000000001@origin.example.com:443');
          input.search = new URLSearchParams({
            security, type: 'ws', sni: 'tls.example.com', fp: 'chrome',
            pbk: 'fixture-public-key', sid: 'abcdef', path: '/ws?ed=2048',
            encryption: 'none', allowInsecure: '0'
          }).toString();
          // 重复参数也必须全部清除，避免客户端选取不同的值。
          input.searchParams.append('pbk', 'second-fixture-key');
          const request = new URL('http://localhost:8787/sub');
          request.searchParams.set(inputMode, inputMode === 'node64'
            ? Buffer.from(input.href).toString('base64url') : input.href);
          request.searchParams.set('format', format);
          const response = await worker.fetch(new Request(request), {
            BEST_IP_CSV: 'https://fixture.example/ips.csv',
            FIXED_ADDRESSES_URL: 'https://fixture.example/fixed.txt'
          });
          assert.equal(response.status, 200);
          const output = new URL(Buffer.from(await response.text(), 'base64').toString('utf8'));
          assert.equal(output.hostname, '192.0.2.1');
          assert.equal(output.username, input.username);
          for (const key of ['security', 'type', 'sni', 'fp', 'path', 'encryption', 'allowInsecure']) {
            assert.equal(output.searchParams.get(key), input.searchParams.get(key), key);
          }
          assert.equal(output.searchParams.get('host'), 'origin.example.com');
          for (const key of ['pbk', 'sid']) {
            assert.deepEqual(output.searchParams.getAll(key), security === 'reality'
              ? input.searchParams.getAll(key) : [], `${security}/${format}/${inputMode}/${key}`);
          }
          assert.equal(output.searchParams.has('data'), false);
        }
      }
    }
  } finally {
    globalThis.fetch = originalFetch;
  }
});

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
test('订阅 top 默认使用 BEST_IP_MAX，未配置时为 30，并可被 URL 覆盖', async () => {
  const originalFetch = globalThis.fetch;
  const csvRows = Array.from({ length: 40 }, (_, index) => {
    const ip = `104.18.${index}.${index + 1}`;
    return `${ip},4,4,0.00,${70 + index}, ${40 - index},SIN`;
  }).join('\n');
  const csv = `IP 地址,已发送,已接收,丢包率,平均延迟,下载速度(MB/s),地区码\n${csvRows}`;

  const countNodes = async (env, search) => {
    globalThis.fetch = async input => {
      const url = String(input);
      if (url === 'https://fixture.example/ips.csv') return new Response(csv);
      if (url === 'https://fixture.example/fixed.txt') return new Response('');
      throw new Error('unexpected fetch: ' + url);
    };
    const request = new URL('http://localhost:8787/sub');
    request.searchParams.set('node64', Buffer.from('vless://00000000-0000-4000-8000-000000000001@origin.example.com:443?security=tls&type=ws').toString('base64url'));
    if (search) {
      for (const [key, value] of Object.entries(search)) request.searchParams.set(key, value);
    }
    const response = await worker.fetch(new Request(request), {
      BEST_IP_CSV: 'https://fixture.example/ips.csv',
      FIXED_ADDRESSES_URL: 'https://fixture.example/fixed.txt',
      ...env
    });
    assert.equal(response.status, 200);
    return Buffer.from(await response.text(), 'base64').toString('utf8').trim().split('\n').filter(Boolean).length;
  };

  try {
    assert.equal(await countNodes({}, null), 30, '默认 BEST_IP_MAX=30');
    assert.equal(await countNodes({ BEST_IP_MAX: '12' }, null), 12, '读取部署环境变量 BEST_IP_MAX');
    assert.equal(await countNodes({ BEST_IP_MAX: '12' }, { top: '5' }), 5, 'URL top 覆盖默认值');
    assert.equal(await countNodes({ BEST_IP_MAX: '0' }, null), 30, '非法 BEST_IP_MAX 回退 30');
  } finally {
    globalThis.fetch = originalFetch;
  }
});
