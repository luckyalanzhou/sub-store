async function readAppVersion({
    frontendPort = process.env.SUB_STORE_FRONTEND_PORT || 3001,
    prefix = (process.env.SUB_STORE_FRONTEND_BACKEND_PATH || '').replace(/\/$/, ''),
    fetchImpl = globalThis.fetch,
} = {}) {
    const response = await fetchImpl(`http://127.0.0.1:${frontendPort}${prefix}/api/utils/env`, {
        signal: AbortSignal.timeout(5000),
    });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const body = await response.json();
    const version = body && body.data && body.data.version;
    if (!/^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/.test(version || ''))
        throw new Error('version is unavailable');
    return version;
}

if (require.main === module || process.argv[1] === '-') {
    readAppVersion().then(version => {
        process.stdout.write(`${version}\n`);
    }).catch(() => {
        process.exitCode = 1;
    });
}

module.exports = { readAppVersion };
