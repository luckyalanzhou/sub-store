'use strict';
'require view';
'require form';
'require uci';
'require fs';
'require ui';
'require poll';

const names = { running: '运行中', exited: '已停止', stopped: '已停止', restarting: '正在重启',
    maintenance: '正在维护', 'docker-unavailable': 'Docker 不可用', 'not-created': '容器尚未创建' };
function validCron(value) {
    const fields = value.trim().split(/\s+/);
    const limits = [[0, 59], [0, 23], [1, 31], [1, 12], [0, 7]];
    return fields.length === 5 && fields.every((field, i) => field.split(',').every(item => {
        const parts = item.split('/');
        if (parts.length > 2 || (parts.length === 2 && (!/^\d+$/.test(parts[1]) || +parts[1] < 1))) return false;
        if (parts[0] === '*') return true;
        const range = parts[0].split('-');
        return range.length <= 2 && range.every(n => /^\d+$/.test(n) && +n >= limits[i][0] && +n <= limits[i][1]) &&
            (range.length === 1 || +range[0] <= +range[1]);
    }));
}
function compareVersions(left, right) {
    const parse = value => {
        const match = /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/.exec(value || '');
        return match && match.slice(1);
    };
    const a = parse(left), b = parse(right);
    if (!a || !b) return null;
    for (let i = 0; i < 3; i++) {
        if (a[i].length !== b[i].length) return a[i].length > b[i].length ? 1 : -1;
        if (a[i] !== b[i]) return a[i] > b[i] ? 1 : -1;
    }
    return 0;
}
return view.extend({
    validCron: validCron,
    compareVersions: compareVersions,
    snapshot: async function(mode) {
        const r = await fs.exec('/usr/lib/sub-store/status', mode && mode !== 'summary' ? [mode] : []);
        if (r.code !== 0) throw new Error(r.stderr || '读取服务状态失败');
        return JSON.parse(r.stdout);
    },
    load: function() {
        return Promise.all([uci.load('sub-store'), this.snapshot('details')]);
    },
    setBusy: function(busy) {
        this.localBusy = busy;
        const disabled = busy || !!(this.state && this.state.busy);
        this.buttons.forEach(button => { button.disabled = disabled; });
        const status = this.state && this.state.container;
        if (this.startButton)
            this.startButton.disabled = disabled || !['exited', 'stopped', 'not-created'].includes(status);
        if (this.stopButton)
            this.stopButton.disabled = disabled || status !== 'running';
        if (this.restartButton)
            this.restartButton.disabled = disabled || status !== 'running';
        if (this.map && this.map.root && this.map.root.querySelectorAll)
            this.map.root.querySelectorAll('input,select,textarea').forEach(input => { input.disabled = disabled; });
    },
    clearPendingEnqueue: function(action) {
        if (this.enqueuePendingAction !== action) return false;
        this.enqueuePendingAction = null;
        this.enqueuePreviousOperation = null;
        this.enqueuePreviousOperationId = null;
        this.enqueueRequestError = null;
        this.enqueueRequestTimedOut = false;
        this.enqueueStatusMisses = 0;
        this.localBusy = false;
        return true;
    },
    failPendingEnqueue: function(action, error) {
        if (!this.clearPendingEnqueue(action)) return;
        this.awaitingTaskDetails = false;
        if (this.updateAction === action) {
            this.updateAction = null;
            this.updateControls();
        }
        if (this.reloadAfterTask) {
            this.reloadAfterTask = false;
            this.reloadTaskAccepted = false;
        }
        ui.addNotification(null, E('p', {}, ['设备未确认此操作：' + error.message + '。请查看维护日志后再重试。']), 'error');
    },
    refresh: async function(mode) {
        try {
            const wasBusy = !!(this.state && this.state.busy);
            let s = await this.snapshot(mode || 'summary');
            if ((mode || 'summary') === 'summary' && (wasBusy || (this.awaitingTaskDetails && !this.enqueuePendingAction)) && !s.busy && s.phase !== 'running') {
                s = Object.assign(s, await this.snapshot('details'));
                this.awaitingTaskDetails = false;
            }
            const pendingAction = this.enqueuePendingAction;
            const operationChanged = s.operation_id
                ? s.operation_id !== this.enqueuePreviousOperationId
                : s.operation && s.operation !== this.enqueuePreviousOperation;
            const taskStarted = pendingAction && s.action === pendingAction && (s.busy || operationChanged);
            const pluginUpdateInstalled = this.updateAction === 'update-all' &&
                s.action === 'update-all' && !s.busy && s.phase !== 'running' &&
                this.updateStartVersion && s.version && s.version !== this.updateStartVersion &&
                s.plugin_latest_version === s.version &&
                (s.plugin_update_available === false || s.plugin_update_available === '0');
            this.state = Object.assign(this.state || {}, s);
            if (taskStarted) {
                this.clearPendingEnqueue(pendingAction);
                if (this.reloadAfterTask) this.reloadTaskAccepted = true;
            } else if (pendingAction && this.enqueueRequestError) {
                if (this.enqueueRequestTimedOut) {
                    this.enqueueStatusMisses = (this.enqueueStatusMisses || 0) + 1;
                    if (this.enqueueStatusMisses < 2) {
                        if (pendingAction === 'update-all' && this.updateStatus)
                            this.updateStatus.textContent = '正在确认设备状态；状态和日志会自动更新，请勿重复点击。';
                    } else {
                        this.failPendingEnqueue(pendingAction, this.enqueueRequestError);
                    }
                } else {
                    this.failPendingEnqueue(pendingAction, this.enqueueRequestError);
                }
            }
            if (this.updateAction && !s.busy && s.phase !== 'running' && s.action === this.updateAction)
                this.updateAction = null;
            this.paint();
            if (pluginUpdateInstalled) this.beginUpdateReloadCountdown(s.version);
            if (this.reloadAfterTask && this.reloadTaskAccepted && !s.busy && s.phase !== 'running') {
                this.reloadAfterTask = false;
                this.reloadTaskAccepted = false;
                uci.unload('sub-store');
                await uci.load('sub-store');
                await this.map.load();
                await this.map.reset();
            }
            return true;
        } catch (error) {
            this.status.textContent = '状态读取失败：' + error.message;
            return false;
        }
    },
    paint: function() {
        const s = this.state;
        const unhealthy = s.container === 'running' && s.health === 'unhealthy';
        const starting = s.container === 'running' && s.health === 'starting';
        this.status.textContent = unhealthy ? 'sub-store 服务运行异常' : starting ? 'sub-store 服务正在启动检查' :
            s.container === 'running' ? 'sub-store 服务已启动' :
                'sub-store 服务状态：' + (names[s.container] || s.container || '状态未知');
        this.version.textContent = s.version || '未知';
        this.open.href = s.url || '#';
        this.open.hidden = !s.url || s.container !== 'running';
        const image = String(s.image || '').split(/\s+\/\s+/, 1);
        this.image.textContent = image[0] || '容器镜像未就绪';
        this.appVersion.textContent = s.app_version || '容器日志未提供版本号';
        this.api.value = s.api_url || '';
        this.updateControls();
        this.paintLog();
        this.updateLogControls();
        this.setBusy(!!this.localBusy);
    },
    updateControls: function() {
        if (!this.updateStatus) return;
        const s = this.state || {};
        const latest = s.plugin_latest_version || '';
        const comparison = compareVersions(latest, s.version || '');
        const available = s.plugin_update_available === true || s.plugin_update_available === '1';
        if (this.pluginReloadCountdown !== undefined)
            this.updateStatus.textContent = '插件已更新至 ' + this.pluginReloadVersion + ' · ' + this.pluginReloadCountdown + ' 秒后刷新';
        else if (this.enqueuePendingAction === 'update-all')
            this.updateStatus.textContent = '正在提交…';
        else if (this.updateAction === 'update-all')
            this.updateStatus.textContent = '正在检查…';
        else if (s.action === 'update-all' && s.phase === 'failed')
            this.updateStatus.textContent = '更新失败 · 查看维护日志';
        else if (s.action === 'update-all' && s.phase === 'success' && latest && comparison === 0)
            this.updateStatus.textContent = '检查完成 · 插件 ' + latest;
        else if (s.action === 'update-all' && s.phase === 'success')
            this.updateStatus.textContent = '检查完成';
        else if (latest && comparison === 0)
            this.updateStatus.textContent = '插件 ' + latest;
        else if (available && comparison === 1)
            this.updateStatus.textContent = '发现插件 ' + latest;
        else if (latest && comparison === -1)
            this.updateStatus.textContent = '插件 ' + (s.version || '未知');
        else
            this.updateStatus.textContent = '';
    },
    beginUpdateReloadCountdown: function(version) {
        if (this.pluginReloadTimer != null || this.pluginReloadCountdown !== undefined ||
            typeof window === 'undefined' || !window.setInterval) return;
        this.pluginReloadVersion = version;
        this.pluginReloadCountdown = 5;
        this.updateControls();
        this.pluginReloadTimer = window.setInterval(() => {
            this.pluginReloadCountdown -= 1;
            this.updateControls();
            if (this.pluginReloadCountdown <= 0) {
                window.clearInterval(this.pluginReloadTimer);
                this.pluginReloadTimer = null;
                window.location.reload();
            }
        }, 1000);
    },
    updateLogControls: function() {
        if (!this.clearLogButtons) return;
        const disabled = !!this.localBusy || !!(this.state && this.state.busy);
        Object.values(this.clearLogButtons).forEach(button => { button.disabled = disabled; });
    },
    paintLog: function() {
        if (!this.logBoxes || !this.state) return;
        const logs = {
            operation: this.state.output,
            container: this.state.container_log
        };
        Object.keys(logs).forEach(name => {
            const box = this.logBoxes[name];
            if (!box) return;
            const text = logs[name] || '暂无日志';
            const wasAtBottom = box.scrollHeight - box.scrollTop - box.clientHeight < 24;
            if (box.value !== text) box.value = text;
            if (this.followLogs[name] || wasAtBottom) box.scrollTop = box.scrollHeight;
            this.followLogs[name] = false;
        });
    },
    refreshLogs: async function() {
        if (!this.logBoxes) return;
        const visible = Object.entries(this.logBoxes).find(entry =>
            !('offsetParent' in entry[1]) || entry[1].offsetParent !== null);
        if (!visible) return;
        try {
            const logs = await this.snapshot(visible[0] === 'container' ? 'runtime-log' : 'maintenance-log');
            this.state = Object.assign(this.state || {}, logs);
            this.paintLog();
        } catch (error) {}
    },
    showMaintenanceLogs: function() {
        if (this.logsPageTab) this.logsPageTab.click();
        const maintenanceTab = this.logTabMenu && this.logTabMenu.querySelector('[data-tab="operation"] a');
        if (maintenanceTab) maintenanceTab.click();
    },
    run: async function(action) {
        if (this.localBusy || (this.state && this.state.busy)) throw new Error('已有操作正在执行，请等待完成。');
        if (action === 'update-all') {
            this.updateAction = action;
            this.updateStartVersion = this.state && this.state.version;
            this.showMaintenanceLogs();
        }
        this.enqueuePendingAction = action;
        this.enqueuePreviousOperation = (this.state && this.state.operation) || '';
        this.enqueuePreviousOperationId = (this.state && this.state.operation_id) || '';
        this.enqueueRequestError = null;
        this.setBusy(true);
        this.awaitingTaskDetails = true;
        this.updateControls();
        this.enqueueTask = Promise.resolve().then(() => fs.exec('/usr/lib/sub-store/job.sh', ['--enqueue', action])).then(r => {
            if (r.code !== 0) return { error: new Error(r.stderr || r.stdout || '操作提交失败') };
            return { accepted: true };
        }, error => ({ error })).then(async result => {
            if (this.enqueuePendingAction !== action) return;
            if (result.error) {
                this.enqueueRequestError = result.error;
                this.enqueueRequestTimedOut = /timed out|timeout/i.test(result.error.message || '');
                this.enqueueStatusMisses = 0;
                const refreshed = await this.refresh('summary');
                if (this.enqueuePendingAction === action && !refreshed) {
                    if (this.enqueueRequestTimedOut) {
                        if (action === 'update-all' && this.updateStatus)
                            this.updateStatus.textContent = '正在确认设备状态；状态和日志会自动更新，请勿重复点击。';
                    } else {
                        this.failPendingEnqueue(action, result.error);
                    }
                }
                return;
            }
            await this.refresh('summary');
        }).catch(error => {
            if (this.enqueuePendingAction === action) {
                this.enqueueRequestError = error;
                this.enqueueRequestTimedOut = /timed out|timeout/i.test(error.message || '');
                this.enqueueStatusMisses = 0;
                return this.refresh('summary').then(refreshed => {
                    if (this.enqueuePendingAction === action && !refreshed && !this.enqueueRequestTimedOut)
                        this.failPendingEnqueue(action, error);
                    if (this.enqueuePendingAction === action && !refreshed && this.enqueueRequestTimedOut &&
                        action === 'update-all' && this.updateStatus)
                        this.updateStatus.textContent = '正在确认设备状态；状态和日志会自动更新，请勿重复点击。';
                });
            }
        });
    },
    confirm: function(action, title, message) {
        ui.showModal(title, [E('p', {}, [message]), E('div', { 'class': 'right' }, [
            E('button', { 'class': 'cbi-button', click: ui.hideModal }, ['取消']), ' ',
            E('button', { 'class': 'cbi-button cbi-button-negative', click: ui.createHandlerFn(this, async function() {
                ui.hideModal();
                if (action === 'rotate-key') {
                    this.reloadAfterTask = true;
                    this.reloadTaskAccepted = false;
                }
                try { await this.run(action); }
                catch (error) {
                    this.reloadAfterTask = false;
                    this.reloadTaskAccepted = false;
                    throw error;
                }
            }) }, ['确认执行'])
        ])]);
    },
    button: function(label, action, style) {
        const button = E('button', { type: 'button', 'class': 'cbi-button cbi-button-' + (style || 'action'),
            click: ui.createHandlerFn(this, function() { return this.run(action); }) }, [label]);
        this.buttons.push(button);
        return button;
    },
    handleSave: async function() {
        if (this.localBusy || this.state.busy) throw new Error('请等待维护操作完成后再保存。');
        this.setBusy(true);
        try {
            await this.map.save(null, true);
            ui.addNotification(null, E('p', {}, ['设置已保存；尚未应用。']), 'info');
        } finally { this.setBusy(false); }
    },
    handleSaveApply: async function() {
        if (this.localBusy || this.state.busy) throw new Error('请等待维护操作完成后再保存。');
        this.setBusy(true);
        try {
            await this.map.save(null, true);
            await ui.changes.apply();
        } finally { this.setBusy(false); }
        this.reloadAfterTask = true;
        this.reloadTaskAccepted = false;
        try {
            await this.run('restart');
            await this.enqueueTask;
        }
        catch (error) { this.reloadAfterTask = false; throw error; }
    },
    handleReset: function() { return this.map.reset(); },
    render: async function(data) {
        this.state = data[1];
        this.buttons = [];
        this.status = E('span');
        this.version = E('span');
        this.open = E('a', { 'class': 'btn small cbi-button cbi-button-positive', target: '_blank', rel: 'noopener noreferrer' }, ['打开']);
        this.open.textContent = '打开Sub-Store';
        this.open.setAttribute('aria-label', '打开Sub-Store管理界面');
        this.startButton = this.button('启动', 'start');
        this.stopButton = this.button('停止', 'stop', 'negative');
        this.restartButton = this.button('重启', 'restart');
        const m = this.map = new form.Map('sub-store', 'sub-store');
        const overview = m.section(form.NamedSection, 'main', 'settings', '服务概览');
        const s = m.section(form.NamedSection, 'main', 'settings');
        s.tab('basic', '基本设置');
        s.tab('logs', '日志');
        s.tab('maintenance', '更新维护');
        const displayOverview = (id, label, node) => {
            const option = overview.option(form.DummyValue, id, label);
            option.renderWidget = function() { return node; };
            return option;
        };
        const display = (tab, id, label, node) => {
            const option = s.taboption(tab, form.DummyValue, id, label);
            option.renderWidget = function() { return node; };
            return option;
        };
        displayOverview('_service_status', '服务状态', E('div', {}, [this.status, ' ', this.open]));
        displayOverview('_service_control', '服务控制', E('div', {}, [
            this.startButton, ' ', this.stopButton, ' ', this.restartButton
        ]));
        let o = s.taboption('basic', form.Value, 'frontend_port', '管理页面端口');
        o.datatype = 'port'; o.rmempty = false; o.default = '3001';
        const frontend = o;
        o = s.taboption('basic', form.Value, 'access_host', '访问主机名');
        o.validate = function(section, value) {
            return !value || (value.length <= 253 && /^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(value) &&
                !/\.\.|-\.|\.-/.test(value)) || '请输入域名或 IPv4，不含协议和端口。';
        };
        o = s.taboption('basic', form.Value, 'public_url', '公开访问地址');
        o.validate = function(section, value) {
            if (!value) return true;
            if (!/^https?:\/\/[A-Za-z0-9.-]+(?::\d{1,5})?(?:\/[^?#\s]*)?$/.test(value))
                return '请输入不含查询参数的 HTTP 或 HTTPS 地址。';
            const authority = value.replace(/^https?:\/\//, '').split('/')[0];
            const host = authority.split(':')[0];
            if (!host || host.length > 253 || !/^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(host) || /\.\.|-\.|\.-/.test(host))
                return '公开访问地址中的主机名无效。';
            const port = authority.includes(':') ? +authority.split(':').pop() : 0;
            return !port || (port >= 1 && port <= 65535) || '端口必须在 1 到 65535 之间。';
        };
        o = s.taboption('basic', form.Value, 'backend_port', '后端 API 端口');
        o.datatype = 'port'; o.rmempty = false; o.default = '3000';
        o.validate = function(section, value) { return +value !== +frontend.formvalue(section) || '前后端端口不能相同。'; };
        o = s.taboption('basic', form.Flag, 'backend_lan_access', '允许局域网直连后端');
        o.default = '0'; o.rmempty = false;
        this.api = E('input', { 'class': 'cbi-input-text', readonly: true, 'aria-label': '后端直连地址' });
        display('basic', '_api', '后端直连地址', this.api).depends('backend_lan_access', '1');
        o = s.taboption('basic', form.Value, 'api_path', 'API 密钥');
        o.password = true; o.rmempty = false;
        o.validate = function(section, value) { return /^[a-fA-F0-9]{48}$/.test(value) || '请输入 48 位十六进制字符。'; };
        o = s.taboption('basic', form.Value, 'sync_cron', 'Cron 表达式');
        o.default = '55 23 * * *'; o.rmempty = false;
        o.validate = function(section, value) { return validCron(value) || 'Cron 格式或字段范围不正确。'; };
        this.image = E('span');
        this.appVersion = E('span');
        this.updateStatus = E('span', { 'aria-live': 'polite' });
        this.updateButton = this.button('检查更新', 'update-all', 'positive');
        this.followLogs = { container: true, operation: true };
        this.logBoxes = {};
        this.clearLogButtons = {};
        const logSection = (name, title, action) => {
            const runtime = name === 'container';
            const box = E('textarea', { 'class': 'cbi-input-textarea', readonly: true, rows: 20, cols: 120, wrap: 'off',
                role: 'log', 'aria-label': title });
            const clearButton = E('button', { type: 'button', 'class': 'cbi-button cbi-button-negative',
                click: ui.createHandlerFn(this, function() {
                    const running = this.state && this.state.container === 'running';
                    const message = runtime ?
                        (running ? '清空运行日志需要短暂重启服务；数据卷保留。' : '清空运行日志，不会启动已停止的服务；数据卷保留。') :
                        '只清空维护日志，不影响运行日志和数据卷。';
                    return this.confirm(action, '清空日志', message);
                }) }, ['清空日志']);
            this.logBoxes[name] = box;
            this.clearLogButtons[name] = clearButton;
            this.buttons.push(clearButton);
            return E('div', {}, [clearButton, box]);
        };
        const runtimeLogs = logSection('container', '运行日志', 'clear-runtime-logs');
        const maintenanceLogs = logSection('operation', '维护日志', 'clear-maintenance-logs');
        runtimeLogs.setAttribute('data-tab', 'container');
        runtimeLogs.setAttribute('data-tab-title', '运行日志');
        runtimeLogs.setAttribute('data-tab-active', 'true');
        maintenanceLogs.setAttribute('data-tab', 'operation');
        maintenanceLogs.setAttribute('data-tab-title', '维护日志');
        maintenanceLogs.setAttribute('data-tab-active', 'false');
        this.logPanes = [runtimeLogs, maintenanceLogs];
        const logsPanel = E('div', {}, this.logPanes);
        display('logs', '_logs', '', logsPanel);
        const rotate = E('button', { type: 'button', 'class': 'cbi-button cbi-button-negative',
            click: ui.createHandlerFn(this, function() {
                return this.confirm('rotate-key', '重新生成 API 访问密钥', '成功后旧管理地址会立即失效。未保存的表单修改将丢弃，请先保存需要保留的设置。');
            }) }, ['重新生成']);
        this.buttons.push(rotate);
        display('maintenance', '_plugin_version', '插件版本', this.version);
        display('maintenance', '_app_version', 'Sub-Store 版本', this.appVersion);
        display('maintenance', '_image', 'Docker 镜像', this.image);
        display('maintenance', '_updates', '更新', E('div', {}, [
            this.updateButton, ' ', E('span', { 'aria-live': 'polite' }, [this.updateStatus])
        ]));
        display('maintenance', '_rotate', 'API 密钥', rotate);
        const formNode = await m.render();
        ui.tabs.initTabGroup(this.logPanes);
        this.logTabMenu = formNode.querySelector && formNode.querySelector('#cbi-sub-store-main-_logs .cbi-tabmenu');
        const pageTabs = formNode.querySelectorAll && formNode.querySelectorAll('.cbi-tabmenu a');
        this.logsPageTab = pageTabs && Array.from(pageTabs).find(tab => tab.textContent.trim() === '日志');
        this.paint();
        this.pollCycle = 0;
        poll.add(async () => {
            if (typeof document !== 'undefined' && document.hidden) return;
            this.pollCycle += 1;
            const logVisible = this.logBoxes && Object.values(this.logBoxes).some(box =>
                !('offsetParent' in box) || box.offsetParent !== null);
            const fast = this.localBusy || (this.state && this.state.busy) || this.enqueuePendingAction || logVisible;
            if (fast || this.pollCycle % 3 === 0) await this.refresh('summary');
            if (logVisible) await this.refreshLogs();
        }, 5);
        return formNode;
    }
});
