const fs = require('node:fs');
const test = require('node:test');
const assert = require('node:assert/strict');
const source = fs.readFileSync('run/payload/root/www/luci-static/resources/view/sub-store/manage.js', 'utf8');
function setup() {
    const options = {}, calls = [], polls = [];
    const state = { container: 'running', health: 'healthy', url: 'http://router.test:3001/?api=x', busy: false, version: 'test',
        app_version: '2.42.3', created: '2026-10-13T00:00:00Z', output: 'maintenance log', container_log: 'runtime log',
        storage: '/mnt/docker/volumes/sub-store-data/_data', plugin_latest_version: '', plugin_update_available: false };
    const E = (tag, attrs = {}, children = []) => ({ tag, ...attrs, children, textContent: '', value: '', focus() {}, select() {} });
    const ui = { createHandlerFn: (ctx, fn) => fn.bind(ctx), changes: { init: async () => {} },
        addNotification: (...args) => calls.push(['notice', ...args]), showModal: (...args) => calls.push(['modal', ...args]), hideModal() {} };
    const uci = { load: async () => {}, unload() {} };
    const backend = { exec: async (path, args) => {
        calls.push([path, args]);
        return path.endsWith('status') ? { code: 0, stdout: JSON.stringify(state) } : { code: 0, stdout: 'accepted' };
    } };
    class Map {
        section() { return { tab() {}, taboption(tab, type, name) {
            const option = { tab, formvalue: () => option.input };
            options[name] = option; return option;
        } }; }
        async render() { return E('form'); }
        async save() { calls.push(['save']); }
        async load() {}
        async reset() {}
    }
    const rpc = { declare: () => async config => { calls.push(['commit', config]); return 0; } };
    const view = new Function('view', 'form', 'uci', 'rpc', 'fs', 'ui', 'poll', 'E', source)(
        { extend: value => value }, { Map, NamedSection: 1, Value: 2, DummyValue: 3 }, uci, rpc, backend, ui,
        { add: fn => polls.push(fn) }, E);
    return { view, options, calls, state, backend, polls };
}
test('native page groups settings, masks key and schedules status polling', async () => {
    const t = setup(); const page = await t.view.render(await t.view.load());
    assert.equal(t.options.frontend_port.tab, 'basic');
    assert.equal(t.options.public_url.tab, 'basic');
    assert.equal(t.options.backend_port.tab, 'advanced');
    assert.equal(t.options.log_max_size_mb, undefined);
    assert.equal(t.options.log_max_files, undefined);
    assert.equal(t.options.api_path.password, true);
    assert.equal(t.polls.length, 1);
    assert.equal(t.view.open.href, t.state.url);
    assert.equal(t.view.open.children[0], '点击打开 sub-store');
    assert.match(t.view.open.class, /sub-store-open-button/);
    assert.equal(t.view.address['aria-label'], '访问地址');
    assert.equal(t.view.status.textContent, 'sub-store 服务已启动');
    assert.equal(t.view.status.className, 'sub-store-status is-running');
    assert.equal(t.view.appVersion.textContent, '2.42.3');
    assert.equal(page.children[2].children[0].children[0], '服务概览');
    assert.match(source, /sub-store-status\{display:inline-flex/);
    assert.match(source, /sub-store-status\{[^}]*border-radius:4px/);
    assert.match(source, /sub-store-open-button\{text-transform:none\}/);
    assert.equal(t.view.storage.textContent, t.state.storage);
    assert.equal(t.view.logBox.textContent, 'runtime log');
    assert.equal(t.view.clearLogsButton.hidden, true);
    t.view.logTabs.operation.click();
    assert.equal(t.view.logBox.textContent, 'maintenance log');
    assert.equal(t.view.clearLogsButton.hidden, false);
    t.view.clearLogsButton.click();
    assert.equal(t.calls.find(call => call[0] === 'modal')[1], '清空维护日志');
    t.view.logTabs.container.click();
    assert.equal(t.view.logBox.textContent, 'runtime log');
    assert.equal(t.view.clearLogsButton.hidden, true);
    assert.deepEqual(Object.keys(t.view.logTabs).sort(), ['container', 'operation']);
    assert.doesNotMatch(source, /刷新日志/);
    t.state.container_log = 'refreshed runtime log';
    await t.polls[0]();
    assert.equal(t.view.logBox.textContent, 'refreshed runtime log');
    t.options.frontend_port.input = '3001';
    assert.notEqual(t.options.backend_port.validate('main', '3001'), true);
    assert.equal(t.options.backend_port.validate('main', '3000'), true);
    assert.equal(t.options.api_path.validate('main', 'a'.repeat(48)), true);
    assert.notEqual(t.options.api_path.validate('main', 'z'.repeat(48)), true);
    assert.notEqual(t.options.access_host.validate('main', 'http://router:3001'), true);
    assert.equal(t.options.public_url.validate('main', 'https://sub.example.test'), true);
    assert.notEqual(t.options.public_url.validate('main', 'https://bad..example.test'), true);
    assert.match(source, /同时检查插件和官方镜像；有更新时自动安装并保留数据/);
});
test('unhealthy container is visible and completed work refreshes details', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    t.state.health = 'unhealthy';
    await t.view.refresh('summary');
    assert.equal(t.view.status.textContent, 'sub-store 服务运行异常');
    assert.match(t.view.status.className, /is-warning/);
    t.state.busy = true;
    await t.view.refresh('summary');
    t.calls.length = 0;
    t.state.busy = false;
    t.state.phase = 'success';
    await t.view.refresh('summary');
    assert.equal(t.calls.some(call => call[0].endsWith('status') && call[1][0] === 'details'), true);
});
test('Cron rejects malformed, out-of-range and reversed ranges', () => {
    const { view } = setup();
    for (const cron of ['55 23 * * *', '0 */6 * * *', '0 0 1-15 * 1,5']) assert.equal(view.validCron(cron), true);
    for (const cron of ['60 23 * * *', '* * * *', '* * * * * *', '*/0 * * * *', '0 0 15-1 * *', '0 0 * * 8', '0,,1 * * * *']) assert.equal(view.validCron(cron), false);
});
test('plugin version comparison handles unbounded numeric components', () => {
    const { view } = setup();
    assert.equal(view.compareVersions('1.10.0', '1.9.99'), 1);
    assert.equal(view.compareVersions('1.2.10000000000000000001', '1.2.9999999999999999999'), 1);
    assert.equal(view.compareVersions('0.0.21', '0.0.21'), 0);
    assert.equal(view.compareVersions('dev', '0.0.21'), null);
});
test('combined update verifies a newly installed plugin and shows a refresh countdown', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    const previousWindow = global.window;
    const timers = [], calls = [];
    global.window = {
        setInterval: fn => { timers.push(fn); return timers.length; },
        clearInterval() {},
        location: { reload: () => calls.push('reload') }
    };
    try {
        t.view.updateStartVersion = '0.0.21';
        t.view.updateAction = 'update-all';
        t.view.awaitingTaskDetails = true;
        Object.assign(t.state, { version: '0.0.22', plugin_latest_version: '0.0.22', plugin_update_available: false,
            action: 'update-all', phase: 'failed', busy: false });
        await t.view.refresh('summary');
        assert.equal(t.view.updateStatus.textContent, '插件已更新到 0.0.22；5 秒后刷新页面');
        for (let i = 0; i < 5; i++) timers[0]();
        assert.deepEqual(calls, ['reload']);
    } finally {
        if (previousWindow === undefined) delete global.window;
        else global.window = previousWindow;
    }
});
test('image-only update does not reload the LuCI page', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    const previousWindow = global.window;
    const timers = [];
    global.window = { setInterval: fn => { timers.push(fn); return timers.length; }, clearInterval() {},
        location: { reload() { throw new Error('unexpected reload'); } } };
    try {
        t.view.updateStartVersion = '0.0.21';
        t.view.updateAction = 'update-all';
        t.view.awaitingTaskDetails = true;
        Object.assign(t.state, { version: '0.0.21', plugin_latest_version: '0.0.21', plugin_update_available: false,
            action: 'update-all', phase: 'success', busy: false });
        await t.view.refresh('summary');
        assert.equal(timers.length, 0);
        assert.equal(t.view.updateStatus.textContent, '检查完成，插件已是最新版本 0.0.21');
    } finally {
        if (previousWindow === undefined) delete global.window;
        else global.window = previousWindow;
    }
});
test('save-and-apply validates and commits before enqueueing restart', async () => {
    const t = setup(); await t.view.render(await t.view.load()); t.calls.length = 0;
    await t.view.handleSaveApply();
    const index = name => t.calls.findIndex(call => call[0] === name);
    assert.ok(index('save') < index('commit'));
    assert.ok(index('commit') < index('/usr/lib/sub-store/job.sh'));
    assert.deepEqual(t.calls[index('/usr/lib/sub-store/job.sh')][1], ['--enqueue', 'restart']);
});
test('invalid settings prevent commit and service restart', async () => {
    const t = setup(); await t.view.render(await t.view.load()); t.calls.length = 0;
    t.view.map.save = async () => { throw new Error('invalid'); };
    await assert.rejects(t.view.handleSaveApply(), /invalid/);
    assert.equal(t.calls.some(call => call[0] === 'commit' || call[0].endsWith('job.sh')), false);
    assert.equal(t.view.localBusy, false);
});
test('running task prevents save and competing operation', async () => {
    const t = setup(); await t.view.render(await t.view.load()); t.state.busy = true; await t.view.refresh();
    await assert.rejects(t.view.handleSave(), /等待/);
    await assert.rejects(t.view.run('update'), /已有/);
    assert.equal(t.view.buttons.every(button => button.disabled), true);
});
test('failed RPC is surfaced and controls are released', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    t.backend.exec = async () => ({ code: 1, stderr: 'Docker unavailable' });
    await assert.rejects(t.view.run('start'), /Docker unavailable/);
    assert.equal(t.view.localBusy, false);
    assert.equal(t.calls.some(call => call[0] === 'notice'), true);
    await t.view.refresh();
    assert.match(t.view.status.textContent, /状态读取失败/);
});
test('XHR timeout reports that the queued task may still be running', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    t.backend.exec = async (path, args) => {
        t.calls.push([path, args]);
        if (path.endsWith('job.sh')) {
            t.state.busy = true;
            t.state.container = 'maintenance';
            throw new Error('XHR request timed out');
        }
        return { code: 0, stdout: JSON.stringify(t.state) };
    };
    await t.view.run('update');
    assert.equal(t.view.status.textContent, 'sub-store 服务状态：正在维护');
    assert.equal(t.calls.some(call => call[0] === 'notice' && call[3] === 'warning'), true);
    assert.equal(t.view.localBusy, false);
});
test('logs are displayed as text and stopped container hides open link', async () => {
    const t = setup(); t.state.container_log = '<script>unsafe</script>'; t.state.container = 'exited';
    await t.view.render(await t.view.load());
    assert.equal(t.view.logBox.textContent, '<script>unsafe</script>');
    assert.equal(t.view.open.hidden, true);
});
test('service check switches to maintenance output', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    await t.view.run('check');
    assert.equal(t.view.activeLog, 'operation');
    assert.deepEqual(t.calls.find(call => call[0].endsWith('job.sh'))[1], ['--enqueue', 'check']);
});
test('menu and ACL expose only this configuration and fixed helper paths', () => {
    const root = 'run/payload/root/usr/share/';
    const menu = JSON.parse(fs.readFileSync(root + 'luci/menu.d/luci-app-sub-store.json'));
    assert.equal(menu['admin/services/sub-store'].action.path, 'sub-store/manage');
    const acl = JSON.parse(fs.readFileSync(root + 'rpcd/acl.d/luci-app-sub-store.json'))['luci-app-sub-store'];
    assert.deepEqual(acl.write.uci, ['sub-store']);
    assert.deepEqual(Object.keys(acl.write.file), ['/usr/lib/sub-store/job.sh']);
});
test('one update button checks the plugin and Docker image, then updates newer versions', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    t.state.version = '0.0.21';
    assert.equal(t.view.updateButton.children[0], '检查更新');
    assert.equal(t.view.updateStatus.textContent, '同时检查插件和官方镜像；有更新时自动安装并保留数据。');
    t.state.plugin_latest_version = '0.0.22';
    t.state.plugin_update_available = true;
    await t.view.refresh('details');
    assert.equal(t.view.updateStatus.textContent, '插件有新版本 0.0.22；点击“检查更新”自动安装。');
    await t.view.updateButton.click();
    const queued = t.calls.filter(call => call[0].endsWith('job.sh')).map(call => call[1][1]);
    assert.deepEqual(queued, ['update-all']);
    assert.match(source, /同时检查插件和官方镜像；有更新时自动安装并保留数据/);
    assert.doesNotMatch(source, /检查插件更新|下载并安装|更新 Sub-Store 镜像/);
    assert.match(source, /重新生成 API 密钥/);
    const controller = fs.readFileSync('run/payload/root/usr/bin/sub-storectl', 'utf8');
    const combinedAction = controller.slice(controller.indexOf('    update-all)'), controller.indexOf('    check-plugin-update)'));
    assert.match(combinedAction, /\$0" update/);
    assert.match(combinedAction, /plugin-update install-if-newer/);
    assert.match(combinedAction, /image_result.*plugin_result/s);
    assert.match(combinedAction, /plugin_result.*fail/s);
    const installer = fs.readFileSync('run/payload/install.sh', 'utf8');
    assert.match(installer, /PLUGIN_ONLY="\$\{SUB_STORE_PLUGIN_ONLY:-0\}"/);
    assert.match(installer, /The Docker image, container, and data were not changed/);
    assert.match(installer, /SUB_STORE_PLUGIN_ONLY/);
});
test('installer clears LuCI caches when replacing the page', () => {
    const installer = fs.readFileSync('run/payload/install.sh', 'utf8');
    assert.match(installer, /rm -f \/tmp\/luci-indexcache\*/);
    assert.match(installer, /rm -rf \/tmp\/luci-modulecache/);
});
