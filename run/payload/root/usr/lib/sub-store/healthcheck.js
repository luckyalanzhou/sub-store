const assetPattern = /<(script|link)\b[^>]*\b(?:src|href)\s*=\s*["']([^"']+)["'][^>]*>/gi;

async function check({ frontend, backend, prefix, rawPrefix = prefix, assetsOnly = false, report = console.log }) {
    const request = async (url, label) => {
        const response = await fetch(url, { signal: AbortSignal.timeout(5000), redirect: 'error' });
        report(`${label}: HTTP ${response.status}, ${response.headers.get('content-type') || 'no content type'}`);
        if (!response.ok) throw new Error(`${label} failed with HTTP ${response.status}`);
        return response;
    };

    const page = await request(`${frontend}/`, 'Frontend HTML');
    const html = await page.text();
    if (!/<html\b/i.test(html) || !/text\/html/i.test(page.headers.get('content-type') || '')) {
        throw new Error('Frontend did not return an HTML document');
    }
    let scripts = 0;
    const assets = new Map();
    for (const match of html.matchAll(assetPattern)) {
        const url = new URL(match[2], `${frontend}/`);
        if (url.origin !== new URL(frontend).origin) continue;
        const isScript = match[1].toLowerCase() === 'script' || /\.m?js$/i.test(url.pathname);
        if (match[1].toLowerCase() === 'script') scripts += 1;
        if (isScript || /\.css$/i.test(url.pathname)) assets.set(url.href, isScript ? 'script' : 'CSS');
    }
    if (!scripts) throw new Error('Frontend HTML contains no local JavaScript entrypoint');
    let index = 0;
    for (const [url, type] of assets) {
        const label = `Frontend ${type} ${++index}`;
        const asset = await request(url, label);
        const contentType = asset.headers.get('content-type') || '';
        const text = await asset.text();
        const correctType = type === 'script' ? /(?:java|ecma)script/i.test(contentType) : /text\/css/i.test(contentType);
        if (!correctType || !text.trim() || /^\s*(?:<!doctype\s+html|<html\b)/i.test(text)) {
            throw new Error(`${label} is empty or has an invalid content type`);
        }
        if (type === 'script') {
            const imports = [...text.matchAll(/(?:\bfrom\s*|\bimport\s*)["']([^"']+)["']/g)].map(match => match[1]);
            if (text.length < 8192) {
                imports.push(...[...text.matchAll(/\bimport\s*\(\s*["']([^"']+)["']/g)].map(match => match[1]));
            }
            for (const source of imports) {
                if (!/^(?:\.|\/|https?:\/\/)/.test(source)) continue;
                const dependency = new URL(source, url);
                if (dependency.origin === new URL(frontend).origin && !assets.has(dependency.href)) {
                    if (assets.size >= 128) throw new Error('Frontend dependency check exceeded its asset limit');
                    assets.set(dependency.href, 'script');
                }
            }
        }
    }
    if (assetsOnly) {
        report('sub-store frontend asset checks passed.');
        return;
    }
    for (const [base, path, label] of [
        [frontend, prefix, 'Frontend API proxy'],
        [backend, rawPrefix, 'Backend API'],
    ]) {
        const response = await request(`${base}${path}/api/utils/env`, label);
        if (!/application\/json/i.test(response.headers.get('content-type') || '')) {
            throw new Error(`${label} did not return JSON`);
        }
        await response.json();
    }
    report('sub-store frontend assets and API checks passed.');
}

if (require.main === module || process.argv[1] === '-') {
    const env = process.env;
    const merged = Boolean(env.SUB_STORE_BACKEND_MERGE);
    const apiPort = env.SUB_STORE_BACKEND_API_PORT || 3000;
    const frontendPort = merged ? apiPort : (env.SUB_STORE_FRONTEND_PORT || 3001);
    const prefix = (env.SUB_STORE_FRONTEND_BACKEND_PATH || '').replace(/\/$/, '');
    check({
        frontend: `http://127.0.0.1:${frontendPort}`,
        backend: `http://127.0.0.1:${apiPort}`,
        prefix,
        rawPrefix: merged || env.SUB_STORE_BACKEND_PREFIX ? prefix : '',
    }).catch(error => {
        console.error(`sub-store check failed: ${error.message}`);
        process.exitCode = 1;
    });
}

module.exports = { check };
