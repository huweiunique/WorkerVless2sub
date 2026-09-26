import http from 'node:http';
import worker from './worker.mjs';

const port = Number(process.env.PORT || 8787);

function buildEnv() {
  return process.env;
}

const server = http.createServer(async (req, res) => {
  try {
    const proto = req.headers['x-forwarded-proto'] || 'http';
    const host = req.headers.host || `127.0.0.1:${port}`;
    const url = `${proto}://${host}${req.url || '/'}`;

    const chunks = [];
    for await (const chunk of req) chunks.push(chunk);
    const body = chunks.length ? Buffer.concat(chunks) : undefined;

    const headers = new Headers();
    for (const [key, value] of Object.entries(req.headers)) {
      if (Array.isArray(value)) {
        for (const item of value) headers.append(key, item);
      } else if (value !== undefined) {
        headers.set(key, value);
      }
    }

    const request = new Request(url, {
      method: req.method,
      headers,
      body: ['GET', 'HEAD'].includes(req.method || 'GET') ? undefined : body,
      duplex: 'half'
    });

    const response = await worker.fetch(request, buildEnv());

    res.statusCode = response.status;
    for (const [key, value] of response.headers.entries()) {
      res.setHeader(key, value);
    }

    const data = Buffer.from(await response.arrayBuffer());
    res.end(data);
  } catch (error) {
    console.error(error);
    res.statusCode = 500;
    res.setHeader('content-type', 'text/plain; charset=utf-8');
    res.end('Internal Server Error');
  }
});

server.listen(port, '0.0.0.0', () => {
  console.log(`WorkerVless2sub listening on 0.0.0.0:${port}`);
});
