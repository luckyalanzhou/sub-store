const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { check } = require('../installer/payload/root/usr/lib/sub-store/healthcheck.js');
const { readAppVersion } = require('../installer/payload/root/usr/lib/sub-store/app-version.js');

function response(status, contentType, body) {
    return {
        status,
        ok: status >= 200 && status < 300,
        headers: { get: name => name.toLowerCase() === 'content-type' ? contentType : null },
        text: async () => body,
        json: async () => JSON.parse(body),
    };
}

function fixture(overrides = {}) {
    const routes = new Map(Object.entries({
        '/': [200, 'text/html', '<html><script type="module" src="/assets/app.js"></script><link rel="stylesheet" href="/assets/app.css"></html>'],
        '/assets/app.js': [200, 'text/javascript', 'import "./runtime.js";'],
        '/assets/runtime.js': [200, 'text/javascript', 'console.log("frontend ready");'],
        '/assets/app.css': [200, 'text/css', 'body { color: black; }'],
        '/test-prefix/api/utils/env': [200, 'application/json', '{"version":"test"}'],
        '/backend/test-prefix/api/utils/env': [200, 'application/json', '{"version":"test"}'],
        ...overrides,
    }));
    const requests = [];
    const fetchImpl = async (url, options) => {
        requests.push({ url: String(url), options });
        const route = routes.get(new URL(url).pathname) || [404, 'text/plain', 'missing'];
        return response(...route);
    };
    return {
        frontend: 'http://router.test',
        backend: 'http://router.test/backend',
        prefix: '/test-prefix',
        rawPrefix: '/test-prefix',
        fetchImpl,
        requests,
        report: () => {},
    };
}

async function runStdinScript(relativePath, env, fetchImpl) {
    const sourcePath = require.resolve(`../installer/payload/root/usr/lib/sub-store/${relativePath}`);
    const module = { exports: {} };
    const localRequire = () => { throw new Error('unexpected require'); };
    localRequire.main = null;
    const stdout = [];
    const messages = [];
    const processMock = {
        argv: ['node', '-'],
        env,
        stdout: { write: value => { stdout.push(value); } },
        exitCode: 0,
    };
    vm.runInNewContext(fs.readFileSync(sourcePath, 'utf8'), {
        module,
        exports: module.exports,
        require: localRequire,
        process: processMock,
        console: {
            log: message => { messages.push(String(message)); },
            error: message => { messages.push(String(message)); },
        },
        fetch: fetchImpl,
        AbortSignal,
        URL,
    }, { filename: sourcePath });
    await new Promise(resolve => setImmediate(resolve));
    return { code: processMock.exitCode, output: stdout.join(''), messages };
}

test('accepts HTML, JS dependencies, CSS, API proxy and backend JSON', async () => {
    await check(fixture());
});

test('rejects HTTP 200 HTML fallback at a JavaScript URL', async () => {
    await assert.rejects(check(fixture({
        '/assets/app.js': [200, 'text/html', '<html>fallback</html>'],
    })), /invalid content type/);
});

test('rejects missing JavaScript assets', async () => {
    await assert.rejects(check(fixture({
        '/assets/app.js': [404, 'text/plain', 'missing'],
    })), /script.*HTTP 404/);
});

test('rejects broken module dependencies behind a healthy entry script', async () => {
    await assert.rejects(check(fixture({
        '/assets/runtime.js': [200, 'text/html', '<html>fallback</html>'],
    })), /invalid content type/);
});

test('checks dynamically imported modules in small entry loaders', async () => {
    await assert.rejects(check(fixture({
        '/assets/app.js': [200, 'text/javascript', 'import("./runtime.js");'],
        '/assets/runtime.js': [404, 'text/plain', 'missing'],
    })), /script.*HTTP 404/);
});

test('supports checking public assets without an API credential', async () => {
    const config = fixture({ '/test-prefix/api/utils/env': [403, 'text/plain', 'private'] });
    await check({ ...config, assetsOnly: true });
    assert.equal(config.requests.some(request => request.url.includes('/api/')), false);
});

test('rejects HTML without a JavaScript entrypoint', async () => {
    await assert.rejects(check(fixture({
        '/': [200, 'text/html', '<html>blank</html>'],
    })), /no local JavaScript entrypoint/);
});

test('rejects a failed frontend API proxy even with a healthy raw API', async () => {
    await assert.rejects(check(fixture({
        '/test-prefix/api/utils/env': [502, 'text/plain', 'proxy failure'],
    })), /Frontend API proxy.*502/);
});

test('rejects a backend that returns HTML instead of JSON', async () => {
    await assert.rejects(check(fixture({
        '/backend/test-prefix/api/utils/env': [200, 'text/html', '<html>fallback</html>'],
    })), /Backend API did not return JSON/);
});

test('uses bounded same-origin requests for health checks', async () => {
    const config = fixture();
    await check(config);
    assert.equal(config.requests.every(request => request.options.redirect === 'error'), true);
    assert.equal(config.requests.every(request => request.options.signal.aborted === false), true);
});

test('runs the Docker health check through its stdin entrypoint', async () => {
    const config = fixture();
    const result = await runStdinScript('healthcheck.js', {
        SUB_STORE_BACKEND_API_PORT: '3000',
        SUB_STORE_BACKEND_MERGE: 'true',
        SUB_STORE_FRONTEND_BACKEND_PATH: '/test-prefix',
    }, config.fetchImpl);
    assert.equal(result.code, 0, result.messages.join('\n'));
    assert.match(result.messages.join('\n'), /frontend assets and API checks passed/);
});

test('reports broken frontend assets through the stdin health check', async () => {
    const config = fixture({ '/assets/app.js': [404, 'text/plain', 'missing'] });
    const result = await runStdinScript('healthcheck.js', {
        SUB_STORE_BACKEND_API_PORT: '3000',
        SUB_STORE_BACKEND_MERGE: 'true',
        SUB_STORE_FRONTEND_BACKEND_PATH: '/test-prefix',
    }, config.fetchImpl);
    assert.equal(result.code, 1);
    assert.match(result.messages.join('\n'), /Frontend script 1 failed with HTTP 404/);
});

test('reads the Sub-Store version from the environment API', async () => {
    const requests = [];
    const version = await readAppVersion({
        frontendPort: 3001,
        prefix: '/test-prefix',
        fetchImpl: async (url, options) => {
            requests.push({ url, options });
            return response(200, 'application/json', '{"status":"success","data":{"version":"2.42.4"}}');
        },
    });
    assert.equal(version, '2.42.4');
    assert.equal(requests[0].url, 'http://127.0.0.1:3001/test-prefix/api/utils/env');
});

test('rejects an invalid environment API version', async () => {
    await assert.rejects(readAppVersion({
        fetchImpl: async () => response(200, 'application/json', '{"status":"success","data":{"version":"latest"}}'),
    }), /version is unavailable/);
});

test('runs the app version reader through its stdin entrypoint', async () => {
    const requests = [];
    const result = await runStdinScript('app-version.js', {
        SUB_STORE_FRONTEND_PORT: '3011',
        SUB_STORE_FRONTEND_BACKEND_PATH: '/test-prefix/',
    }, async (url, options) => {
        requests.push({ url, options });
        return response(200, 'application/json', '{"status":"success","data":{"version":"2.42.4"}}');
    });
    assert.equal(result.code, 0);
    assert.equal(result.output, '2.42.4\n');
    assert.equal(requests[0].url, 'http://127.0.0.1:3011/test-prefix/api/utils/env');
});

test('returns a failure from the app version stdin entrypoint for invalid data', async () => {
    const result = await runStdinScript('app-version.js', {}, async () =>
        response(200, 'application/json', '{"status":"success","data":{"version":"latest"}}'));
    assert.equal(result.code, 1);
    assert.equal(result.output, '');
});
