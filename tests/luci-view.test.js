const fs = require('node:fs');
const test = require('node:test');
const assert = require('node:assert/strict');
const source = fs.readFileSync('run/payload/root/www/luci-static/resources/view/sub-store/manage.js', 'utf8');
function setup() {
    const options = {}, calls = [], polls = [];
    let logTabMenu = null;
    const rootLogTab = { textContent: '日志', clicks: 0, click() { this.clicks += 1; } };
    const state = { container: 'running', health: 'healthy', url: 'http://router.test:3001/?api=x', busy: false, version: 'test',
        app_version: '2.42.3', created: '2026-10-13T00:00:00Z', output: 'maintenance log', container_log: 'runtime log',
        storage: '/mnt/docker/volumes/sub-store-data/_data', plugin_latest_version: '', plugin_update_available: false };
    const E = (tag, attrs = {}, children = []) => ({ tag, ...attrs, children, textContent: '', value: '', focus() {}, select() {},
        setAttribute(name, value) { this[name] = value; } });
    const ui = { createHandlerFn: (ctx, fn) => function(...args) {
        if (global.window && global.window.requireCurrentTarget && !args.some(arg => arg && arg.currentTarget))
            throw new TypeError('event.currentTarget is required');
        return fn.apply(ctx, args);
    }, changes: { init: async () => {}, apply: async () => { calls.push(['apply']); } },
        tabs: { initTabGroup: panes => {
            calls.push(['tabs', panes]);
            const items = panes.map(pane => E('li', {
                'data-tab': pane['data-tab'],
                class: pane['data-tab-active'] === 'true' ? 'cbi-tab' : 'cbi-tab-disabled'
            }, [E('a', { click: () => {
                panes.forEach(candidate => {
                    const active = candidate === pane;
                    candidate.hidden = !active;
                    candidate.setAttribute('data-tab-active', active ? 'true' : 'false');
                });
                items.forEach(item => {
                    item.class = item === items[panes.indexOf(pane)] ? 'cbi-tab' : 'cbi-tab-disabled';
                });
            } }, [pane['data-tab-title']])]));
            logTabMenu = E('ul', { class: 'cbi-tabmenu' }, items);
            logTabMenu.querySelector = selector => {
                const match = selector.match(/\[data-tab="([^"]+)"\]/);
                const item = match && items.find(candidate => candidate['data-tab'] === match[1]);
                return item && item.children[0];
            };
            panes.forEach(pane => { pane.hidden = pane['data-tab-active'] !== 'true'; });
        } },
        addNotification: (...args) => calls.push(['notice', ...args]), showModal: (...args) => calls.push(['modal', ...args]), hideModal() {} };
    const uci = { load: async () => {}, unload() {} };
    const backend = { exec: async (path, args) => {
        calls.push([path, args]);
        if (path.endsWith('status')) return { code: 0, stdout: JSON.stringify(state) };
        if (path.endsWith('job.sh')) {
            Object.assign(state, { busy: true, action: args[1], phase: 'running', container: 'maintenance',
                operation: '正在执行：' + args[1] + '；开始时间：2026-10-14 12:00:00' });
        }
        return { code: 0, stdout: 'accepted' };
    } };
    class Map {
        constructor(...args) { this.args = args; this.sections = []; }
        section(...args) {
            const map = this;
            const section = { args, tabs: [], options: [], tab(name, label) { section.tabs.push({ name, label }); },
                option(type, name, label) { return addOption(undefined, type, name, label); },
                taboption(tab, type, name, label) { return addOption(tab, type, name, label); } };
            const addOption = (tab, type, name, label) => {
                const option = { tab, type, name, label, formvalue: () => option.input,
                    depends(field, value) { option.dependency = { field, value }; } };
                section.options.push(option);
                options[name] = option;
                return option;
            };
            map.sections.push(section);
            return section;
        }
        async render() {
            const form = E('form');
            form.querySelectorAll = () => [rootLogTab];
            form.querySelector = selector => selector === '#cbi-sub-store-main-_logs .cbi-tabmenu' ? logTabMenu : null;
            return form;
        }
        async save() { calls.push(['save']); }
        async load() {}
        async reset() {}
    }
    const view = new Function('view', 'form', 'uci', 'rpc', 'fs', 'ui', 'poll', 'E', source)(
        { extend: value => value }, { Map, NamedSection: 1, Value: 2, DummyValue: 3 }, uci, {}, backend, ui,
        { add: fn => polls.push(fn) }, E);
    return { view, options, calls, state, backend, polls, rootLogTab };
}
test('native page groups settings, masks key and schedules status polling', async () => {
    const t = setup(); const page = await t.view.render(await t.view.load());
    assert.equal(page.tag, 'form');
    assert.deepEqual(t.view.map.args, ['sub-store', 'sub-store']);
    assert.equal(t.view.map.sections.length, 2);
    assert.deepEqual(t.view.map.sections[0].options.map(option => option.name), [
        '_service_status', '_service_control'
    ]);
    assert.equal(t.view.map.sections[0].args[3], '服务概览');
    assert.deepEqual(t.view.map.sections[1].tabs.map(tab => tab.name), ['basic', 'logs', 'maintenance']);
    assert.deepEqual(t.view.map.sections[1].options.filter(option => option.tab === 'basic').map(option => option.name), [
        'frontend_port', 'access_host', 'public_url',
        'backend_port', 'backend_lan_access', '_api',
        'api_path', 'sync_cron'
    ]);
    for (const id of ['_service_status', '_service_control'])
        assert.equal(t.options[id].tab, undefined);
    assert.equal(t.options._management_ui, undefined);
    assert.equal(t.options._created, undefined);
    assert.deepEqual(t.options._api.dependency, { field: 'backend_lan_access', value: '1' });
    assert.equal(t.options.frontend_port.tab, 'basic');
    assert.equal(t.options.public_url.tab, 'basic');
    assert.equal(t.options.backend_port.tab, 'basic');
    assert.equal(t.options.sync_cron.label, 'Cron 表达式');
    assert.equal(t.options.log_max_size_mb, undefined);
    assert.equal(t.options.log_max_files, undefined);
    assert.equal(t.options.api_path.password, true);
    assert.equal(t.options.backend_lan_access.default, '0');
    assert.equal(t.polls.length, 1);
    assert.equal(t.view.open.href, t.state.url);
    assert.equal(t.view.open.textContent, '打开Sub-Store');
    assert.equal(t.view.open['aria-label'], '打开Sub-Store管理界面');
    assert.equal(t.view.open.class, 'btn small cbi-button cbi-button-positive');
    const statusControl = t.options._service_status.renderWidget();
    assert.deepEqual(statusControl.children, [t.view.status, ' ', t.view.open]);
    assert.equal(t.options._management_address, undefined);
    assert.equal(t.view.address, undefined);
    assert.equal(t.view.copyAddressButton, undefined);
    assert.equal(t.view.status.textContent, 'sub-store 服务已启动');
    assert.equal(t.view.version.textContent, 'test');
    assert.equal(t.view.updateStatus.textContent, '');
    assert.equal(t.view.status.className, undefined);
    assert.equal(t.view.startButton.disabled, true);
    assert.equal(t.view.stopButton.disabled, false);
    assert.equal(t.view.restartButton.disabled, false);
    assert.equal(t.view.appVersion.textContent, '2.42.3');
    assert.equal(t.view.image.textContent, '容器镜像未就绪');
    t.view.state.image = 'xream/sub-store:latest / sha256:abcdef0123456789';
    t.view.paint();
    assert.equal(t.view.image.textContent, 'xream/sub-store:latest');
    assert.equal(t.options._storage, undefined);
    assert.equal(t.view.storage, undefined);
    for (const id of ['_plugin_version', '_image', '_app_version', '_updates', '_rotate'])
        assert.equal(t.options[id].tab, 'maintenance');
    assert.equal(t.options._maintenance, undefined);
    assert.equal(t.view.maintenancePanel, undefined);
    assert.doesNotMatch(source, /完整地址含 API 参数/);
    assert.doesNotMatch(source, /sub-store-maintenance-(?:panel|card|row)/);
    assert.doesNotMatch(source, /#cbi-sub-store-main-_maintenance/);
    assert.doesNotMatch(source, /sub-store-page|sub-store-overview|sub-store-status|sub-store-log-panel|pageStyles|E\('style'/);
    assert.match(source, /'class': 'cbi-input-textarea'/);
    assert.equal(t.view.logBoxes.container.value, 'runtime log');
    assert.equal(t.view.logBoxes.operation.value, 'maintenance log');
    assert.equal(t.view.logBoxes.container.cols, 120);
    assert.equal(t.options._logs.tab, 'logs');
    assert.equal(t.options._logs.label, '');
    assert.equal(t.options._logs.description, undefined);
    assert.equal(t.options._rotate.description, undefined);
    assert.ok(Object.values(t.options).every(option => option.description === undefined));
    assert.equal(t.view.clearLogButtons.container.children[0], '清空日志');
    assert.equal(t.view.clearLogButtons.operation.children[0], '清空日志');
    assert.deepEqual(t.view.logTabMenu.children.map(item => item.children[0].children[0]), ['运行日志', '维护日志']);
    assert.equal(t.view.logTabMenu.class, 'cbi-tabmenu');
    assert.ok(t.view.logTabMenu.children.every(item => item.style === undefined && item.children[0].style === undefined));
    assert.equal(t.calls.some(call => call[0] === 'tabs' && call[1] === t.view.logPanes), true);
    assert.equal(t.options._logs.renderWidget().children[0], t.view.logPanes[0]);
    assert.equal(t.view.logPanes[0].children[0], t.view.clearLogButtons.container);
    assert.equal(t.view.logPanes[1].children[0], t.view.clearLogButtons.operation);
    assert.equal(t.view.logPanes[0].hidden, false);
    assert.equal(t.view.logPanes[1].hidden, true);
    t.view.logTabMenu.children[1].children[0].click({ preventDefault() {} });
    assert.equal(t.view.logPanes[0].hidden, true);
    assert.equal(t.view.logPanes[1].hidden, false);
    assert.equal(t.view.logTabMenu.children[1].class, 'cbi-tab');
    assert.equal(t.view.logPanes[1]['data-tab-active'], 'true');
    assert.doesNotMatch(source, /刷新日志/);
    t.state.container_log = 'refreshed runtime log';
    t.state.output = 'refreshed maintenance log';
    await t.polls[0]();
    assert.equal(t.view.logBoxes.container.value, 'refreshed runtime log');
    assert.equal(t.view.logBoxes.operation.value, 'refreshed maintenance log');
    t.options.frontend_port.input = '3001';
    assert.notEqual(t.options.backend_port.validate('main', '3001'), true);
    assert.equal(t.options.backend_port.validate('main', '3000'), true);
    assert.equal(t.options.api_path.validate('main', 'a'.repeat(48)), true);
    assert.notEqual(t.options.api_path.validate('main', 'z'.repeat(48)), true);
    assert.notEqual(t.options.access_host.validate('main', 'http://router:3001'), true);
    assert.equal(t.options.public_url.validate('main', 'https://sub.example.test'), true);
    assert.notEqual(t.options.public_url.validate('main', 'https://bad..example.test'), true);
    assert.match(source, /document\.hidden/);
    assert.match(source, /runtime-log.*maintenance-log/s);
});
test('service actions follow the current container state', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    t.view.state.container = 'exited';
    t.view.paint();
    assert.equal(t.view.startButton.disabled, false);
    assert.equal(t.view.stopButton.disabled, true);
    assert.equal(t.view.restartButton.disabled, true);
    t.view.state.container = 'maintenance';
    t.view.state.busy = true;
    t.view.paint();
    assert.equal(t.view.startButton.disabled, true);
    assert.equal(t.view.stopButton.disabled, true);
    assert.equal(t.view.restartButton.disabled, true);
});
test('unhealthy container is visible and completed work refreshes details', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    t.state.health = 'unhealthy';
    await t.view.refresh('summary');
    assert.equal(t.view.status.textContent, 'sub-store 服务运行异常');
    assert.equal(t.view.status.className, undefined);
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
    const timers = [], calls = [], clearedTimers = [];
    global.window = {
        requireCurrentTarget: true,
        setInterval: fn => { timers.push(fn); return timers.length; },
        clearInterval: id => clearedTimers.push(id),
        location: { reload: () => calls.push('reload') }
    };
    try {
        t.view.updateStartVersion = '0.0.21';
        t.view.updateAction = 'update-all';
        t.view.awaitingTaskDetails = true;
        Object.assign(t.state, { version: '0.0.22', plugin_latest_version: '0.0.22', plugin_update_available: false,
            action: 'update-all', phase: 'failed', busy: false });
        await t.view.refresh('summary');
        assert.equal(t.view.updateStatus.textContent, '插件已更新至 0.0.22 · 5 秒后刷新');
        for (let i = 0; i < 4; i++) {
            timers[0]();
            assert.equal(t.view.updateStatus.textContent, '插件已更新至 0.0.22 · ' + (4 - i) + ' 秒后刷新');
        }
        timers[0]();
        assert.deepEqual(calls, ['reload']);
        assert.deepEqual(clearedTimers, [1]);
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
        assert.equal(t.view.updateStatus.textContent, '检查完成 · 插件 0.0.21');
    } finally {
        if (previousWindow === undefined) delete global.window;
        else global.window = previousWindow;
    }
});
test('save-and-apply applies staged LuCI changes before restarting the service', async () => {
    const t = setup(); await t.view.render(await t.view.load()); t.calls.length = 0;
    await t.view.handleSaveApply();
    const index = name => t.calls.findIndex(call => call[0] === name);
    assert.ok(index('save') < index('apply'));
    assert.ok(index('apply') < index('/usr/lib/sub-store/job.sh'));
    assert.deepEqual(t.calls[index('/usr/lib/sub-store/job.sh')][1], ['--enqueue', 'restart']);
    assert.equal(t.calls.filter(call => call[0] === 'apply').length, 1);
});
test('save stages settings without applying them or restarting the service', async () => {
    const t = setup(); await t.view.render(await t.view.load()); t.calls.length = 0;
    await t.view.handleSave();
    assert.deepEqual(t.calls.map(call => call[0]), ['save', 'notice']);
});
test('invalid settings prevent commit and service restart', async () => {
    const t = setup(); await t.view.render(await t.view.load()); t.calls.length = 0;
    t.view.map.save = async () => { throw new Error('invalid'); };
    await assert.rejects(t.view.handleSaveApply(), /invalid/);
    assert.equal(t.calls.some(call => call[0] === 'apply' || call[0].endsWith('job.sh')), false);
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
    await t.view.run('start');
    await t.view.enqueueTask;
    assert.equal(t.view.localBusy, false);
    assert.equal(t.calls.some(call => call[0] === 'notice'), true);
    await t.view.refresh();
    assert.match(t.view.status.textContent, /状态读取失败/);
});
test('slow enqueue returns immediately and polling confirms the queued task', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    let resolveEnqueue;
    t.backend.exec = (path, args) => {
        t.calls.push([path, args]);
        if (path.endsWith('job.sh')) return new Promise(resolve => { resolveEnqueue = resolve; });
        return { code: 0, stdout: JSON.stringify(t.state) };
    };
    await t.view.run('update-all');
    assert.equal(t.view.localBusy, true);
    assert.equal(t.view.enqueuePendingAction, 'update-all');
    assert.equal(t.view.updateStatus.textContent, '正在提交…');

    Object.assign(t.state, { busy: true, action: 'update-all', phase: 'running', container: 'maintenance',
        operation: '正在执行：update-all；开始时间：2026-10-14 12:00:00' });
    await t.polls[0]();
    assert.equal(t.view.localBusy, false);
    assert.equal(t.view.enqueuePendingAction, null);
    assert.equal(t.view.updateStatus.textContent, '正在检查…');

    resolveEnqueue({ code: 0, stdout: 'accepted' });
    await t.view.enqueueTask;
    assert.equal(t.calls.some(call => call[0] === 'notice'), false);
});
test('checking updates opens the maintenance log tab automatically', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    await t.view.run('update-all');
    assert.equal(t.rootLogTab.clicks, 1);
    assert.equal(t.view.logPanes[0].hidden, true);
    assert.equal(t.view.logPanes[1].hidden, false);
    assert.equal(t.view.logTabMenu.children[1].class, 'cbi-tab');
    assert.equal(t.view.logPanes[1]['data-tab-active'], 'true');
    await t.view.enqueueTask;
});
test('XHR timeout is quiet when polling confirms the queued task', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    t.backend.exec = async (path, args) => {
        t.calls.push([path, args]);
        if (path.endsWith('job.sh')) {
            Object.assign(t.state, { busy: true, container: 'maintenance', action: 'update', phase: 'running',
                operation: '正在执行：update；开始时间：2026-10-14 12:00:00' });
            throw new Error('XHR request timed out');
        }
        return { code: 0, stdout: JSON.stringify(t.state) };
    };
    await t.view.run('update');
    await t.view.enqueueTask;
    assert.equal(t.view.status.textContent, 'sub-store 服务状态：正在维护');
    assert.equal(t.calls.some(call => call[0] === 'notice'), false);
    assert.equal(t.view.localBusy, false);
});
test('XHR timeout keeps controls locked until polling confirms no task started', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    t.backend.exec = async (path, args) => {
        t.calls.push([path, args]);
        if (path.endsWith('job.sh')) throw new Error('XHR request timed out');
        return { code: 0, stdout: JSON.stringify(t.state) };
    };
    await t.view.run('update-all');
    await t.view.enqueueTask;
    assert.equal(t.view.localBusy, true);
    assert.equal(t.view.enqueuePendingAction, 'update-all');
    assert.equal(t.calls.some(call => call[0] === 'notice'), false);
    await t.polls[0]();
    assert.equal(t.view.localBusy, false);
    assert.equal(t.view.enqueuePendingAction, null);
    assert.equal(t.calls.some(call => call[0] === 'notice' && call[3] === 'error'), true);
});
test('logs are displayed as text and stopped container hides open link', async () => {
    const t = setup(); t.state.container_log = '<script>unsafe</script>'; t.state.container = 'exited';
    await t.view.render(await t.view.load());
    assert.equal(t.view.logBoxes.container.value, '<script>unsafe</script>');
    assert.equal(t.view.open.hidden, true);
});
test('service diagnostics stay automatic without a manual log action', async () => {
    const t = setup(); await t.view.render(await t.view.load());
    assert.deepEqual(t.view.logTabMenu.children.map(item => item.children[0].children[0]), ['运行日志', '维护日志']);
    assert.equal(t.options._logs.renderWidget().children[0], t.view.logPanes[0]);
    assert.doesNotMatch(source, /检查服务|action === 'check'/);
    const controller = fs.readFileSync('run/payload/root/usr/bin/sub-storectl', 'utf8');
    assert.doesNotMatch(controller, /^\s*check\)/m);
    assert.match(controller, /docker exec -i sub-store node --input-type=commonjs - < "\$HEALTHCHECK"/);
});
test('each separate log has its own clear action and preserves distinct behavior', async () => {
    for (const [name, expectedAction, expectedMessage, containerStatus] of [
        ['container', 'clear-runtime-logs', '清空运行日志需要短暂重启服务；数据卷保留。'],
        ['operation', 'clear-maintenance-logs', '只清空维护日志，不影响运行日志和数据卷。'],
        ['container', 'clear-runtime-logs', '清空运行日志，不会启动已停止的服务；数据卷保留。', 'exited']
    ]) {
        const t = setup(); await t.view.render(await t.view.load());
        if (containerStatus) t.view.state.container = containerStatus;
        t.view.clearLogButtons[name].click();
        const modal = t.calls.find(call => call[0] === 'modal');
        assert.equal(modal[1], '清空日志');
        assert.equal(modal[2][0].children[0], expectedMessage);
        await modal[2][1].children[2].click();
        await t.view.enqueueTask;
        assert.deepEqual(t.calls.find(call => call[0].endsWith('job.sh'))[1], ['--enqueue', expectedAction]);
    }
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
    assert.equal(t.view.updateStatus.textContent, '');
    t.state.plugin_latest_version = '0.0.22';
    t.state.plugin_update_available = true;
    await t.view.refresh('details');
    assert.equal(t.view.updateStatus.textContent, '发现插件 0.0.22');
    await t.view.updateButton.click();
    const queued = t.calls.filter(call => call[0].endsWith('job.sh')).map(call => call[1][1]);
    assert.deepEqual(queued, ['update-all']);
    assert.doesNotMatch(source, /检查插件更新|下载并安装|更新 Sub-Store 镜像/);
    assert.match(source, /重新生成 API 访问密钥/);
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
