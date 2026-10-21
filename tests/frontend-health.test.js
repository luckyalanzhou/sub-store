const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const fs = require('node:fs');
const { spawn } = require('node:child_process');
const { check } = require('../run/payload/root/usr/lib/sub-store/healthcheck.js');

async function fixture(t, overrides = {}) {
    const routes = {
        '/': [200, 'text/html', '<html><script type="module" src="/assets/app.js"></script><link rel="stylesheet" href="/assets/app.css"></html>'],
        '/assets/app.js': [200, 'text/javascript', 'import "./runtime.js";'],
        '/assets/runtime.js': [200, 'text/javascript', 'console.log("frontend ready");'],
        '/assets/app.css': [200, 'text/css', 'body { color: black; }'],
        '/test-prefix/api/utils/env': [200, 'application/json', '{"version":"test"}'],
        '/backend/test-prefix/api/utils/env': [200, 'application/json', '{"version":"test"}'],
        ...overrides,
    };
    const server = http.createServer((request, response) => {
        const [status, type, body] = routes[request.url] || [404, 'text/plain', 'missing'];
        response.writeHead(status, { 'content-type': type });
        response.end(body);
    });
    await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
    t.after(() => new Promise(resolve => {
        server.closeAllConnections();
        server.close(resolve);
    }));
    const origin = `http://127.0.0.1:${server.address().port}`;
    return { frontend: origin, backend: `${origin}/backend`, prefix: '/test-prefix', report: () => {} };
}

test('accepts HTML, JS dependencies, CSS, API proxy and backend JSON', async t => {
    await check(await fixture(t));
});

test('rejects HTTP 200 HTML fallback at a JavaScript URL', async t => {
    const config = await fixture(t, { '/assets/app.js': [200, 'text/html', '<html>fallback</html>'] });
    await assert.rejects(check(config), /invalid content type/);
});

test('rejects missing JavaScript assets', async t => {
    const config = await fixture(t, { '/assets/app.js': [404, 'text/plain', 'missing'] });
    await assert.rejects(check(config), /script.*HTTP 404/);
});

test('rejects broken module dependencies behind a healthy entry script', async t => {
    const config = await fixture(t, { '/assets/runtime.js': [200, 'text/html', '<html>fallback</html>'] });
    await assert.rejects(check(config), /invalid content type/);
});

test('checks dynamically imported modules in small entry loaders', async t => {
    const config = await fixture(t, {
        '/assets/app.js': [200, 'text/javascript', 'import("./runtime.js");'],
        '/assets/runtime.js': [404, 'text/plain', 'missing'],
    });
    await assert.rejects(check(config), /script.*HTTP 404/);
});

test('supports checking public assets without an API credential', async t => {
    const config = await fixture(t, { '/test-prefix/api/utils/env': [403, 'text/plain', 'private'] });
    await check({ ...config, assetsOnly: true });
});

test('rejects HTML without a JavaScript entrypoint', async t => {
    const config = await fixture(t, { '/': [200, 'text/html', '<html>blank</html>'] });
    await assert.rejects(check(config), /no local JavaScript entrypoint/);
});

test('rejects a failed frontend API proxy even with a healthy raw API', async t => {
    const config = await fixture(t, { '/test-prefix/api/utils/env': [502, 'text/plain', 'proxy failure'] });
    await assert.rejects(check(config), /Frontend API proxy.*502/);
});

test('rejects a backend that returns HTML instead of JSON', async t => {
    const config = await fixture(t, { '/backend/test-prefix/api/utils/env': [200, 'text/html', '<html>fallback</html>'] });
    await assert.rejects(check(config), /Backend API did not return JSON/);
});

async function runStdin(config) {
    const port = new URL(config.frontend).port;
    return new Promise((resolve, reject) => {
        const child = spawn(process.execPath, ['--input-type=commonjs', '-'], {
            env: {
                ...process.env,
                SUB_STORE_BACKEND_API_PORT: port,
                SUB_STORE_BACKEND_MERGE: 'true',
                SUB_STORE_FRONTEND_BACKEND_PATH: config.prefix,
            },
        });
        let output = '';
        child.stdout.on('data', data => { output += data; });
        child.stderr.on('data', data => { output += data; });
        child.on('error', reject);
        child.on('close', code => resolve({ code, output }));
        child.stdin.end(fs.readFileSync(require.resolve('../run/payload/root/usr/lib/sub-store/healthcheck.js')));
    });
}

async function runVersion(config) {
    const port = new URL(config.frontend).port;
    return new Promise((resolve, reject) => {
        const child = spawn(process.execPath, ['--input-type=commonjs', '-'], {
            env: {
                ...process.env,
                SUB_STORE_FRONTEND_PORT: port,
                SUB_STORE_FRONTEND_BACKEND_PATH: config.prefix,
            },
        });
        let output = '';
        child.stdout.on('data', data => { output += data; });
        child.stderr.on('data', data => { output += data; });
        child.on('error', reject);
        child.on('close', code => resolve({ code, output }));
        child.stdin.end(fs.readFileSync(require.resolve('../run/payload/root/usr/lib/sub-store/app-version.js')));
    });
}

test('executes health checks through the stdin invocation used by Docker', async t => {
    const result = await runStdin(await fixture(t));
    assert.equal(result.code, 0, result.output);
    assert.match(result.output, /frontend assets and API checks passed/);
});

test('stdin health checks fail when the frontend entrypoint is broken', async t => {
    const config = await fixture(t, { '/assets/app.js': [404, 'text/plain', 'missing'] });
    const result = await runStdin(config);
    assert.equal(result.code, 1, result.output);
    assert.match(result.output, /script.*HTTP 404/);
});

test('reads the Sub-Store version from the environment API', async t => {
    const config = await fixture(t, {
        '/test-prefix/api/utils/env': [200, 'application/json', '{"status":"success","data":{"version":"2.42.4"}}'],
    });
    const result = await runVersion(config);
    assert.equal(result.code, 0, result.output);
    assert.equal(result.output.trim(), '2.42.4');
});

test('rejects an invalid environment API version', async t => {
    const config = await fixture(t, {
        '/test-prefix/api/utils/env': [200, 'application/json', '{"status":"success","data":{"version":"latest"}}'],
    });
    const result = await runVersion(config);
    assert.equal(result.code, 1, result.output);
    assert.equal(result.output, '');
});
