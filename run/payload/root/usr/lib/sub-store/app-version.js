const env = process.env;
const prefix = (env.SUB_STORE_FRONTEND_BACKEND_PATH || '').replace(/\/$/, '');
const frontendPort = env.SUB_STORE_FRONTEND_PORT || 3001;

fetch(`http://127.0.0.1:${frontendPort}${prefix}/api/utils/env`, {
    signal: AbortSignal.timeout(5000),
}).then(async response => {
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const body = await response.json();
    const version = body && body.data && body.data.version;
    if (!/^(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)$/.test(version || ''))
        throw new Error('version is unavailable');
    process.stdout.write(`${version}\n`);
}).catch(() => {
    process.exitCode = 1;
});
