'use strict';
'require view';
'require form';
'require uci';
'require rpc';
'require fs';
'require ui';
'require poll';

const commit = rpc.declare({ object: 'uci', method: 'commit', params: ['config'], expect: { '': 0 } });
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
const operationLabels = {
    start: '启动服务', stop: '停止服务', restart: '重启服务', update: '更新镜像',
    'update-all': '检查并更新', 'rotate-key': '重新生成 API 密钥', check: '检查服务',
    'clear-logs': '清空维护日志'
};

return view.extend({
    validCron: validCron,
    compareVersions: compareVersions,
    formatOperation: function(value) {
        const match = /^(正在执行|操作成功|操作失败)：([^；]+)(.*)$/.exec(value || '');
        if (!match) return value || '尚无维护操作';
        return match[1] + '：' + (operationLabels[match[2]] || match[2]) + match[3];
    },
    formatLocalDate: function(value) {
        const date = new Date(value);
        if (!value || Number.isNaN(date.getTime())) return value || '';
        const pad = number => String(number).padStart(2, '0');
        return date.getFullYear() + '-' + pad(date.getMonth() + 1) + '-' + pad(date.getDate()) + ' ' +
            pad(date.getHours()) + ':' + pad(date.getMinutes()) + ':' + pad(date.getSeconds());
    },
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
        if (this.clearLogsButton) this.clearLogsButton.disabled = disabled || this.activeLog === 'container';
        if (this.map && this.map.root && this.map.root.querySelectorAll)
            this.map.root.querySelectorAll('input,select,textarea').forEach(input => { input.disabled = disabled; });
    },
    clearPendingEnqueue: function(action) {
        if (this.enqueuePendingAction !== action) return false;
        this.enqueuePendingAction = null;
        this.enqueuePreviousOperation = null;
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
            const operationChanged = s.operation && s.operation !== this.enqueuePreviousOperation;
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
            this.status.className = 'alert-message warning';
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
        this.status.className = s.container === 'running' && !unhealthy ? 'sub-store-status is-running' : 'sub-store-status is-warning';
        this.version.textContent = '插件版本：' + (s.version || '未知');
        this.address.value = s.url || '';
        this.open.href = s.url || '#';
        this.open.hidden = !s.url || s.container !== 'running';
        this.operation.textContent = '最近操作：' + this.formatOperation(s.operation);
        this.storage.textContent = s.storage || '实际路径暂不可用';
        this.image.textContent = s.image || '容器镜像未就绪';
        this.appVersion.textContent = s.app_version || '容器日志未提供版本号';
        this.created.textContent = this.formatLocalDate(s.created) || '容器尚未创建';
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
            this.updateStatus.textContent = '插件已更新到 ' + this.pluginReloadVersion + '；' + this.pluginReloadCountdown + ' 秒后刷新页面';
        else if (this.enqueuePendingAction === 'update-all')
            this.updateStatus.textContent = '正在提交检查请求…';
        else if (this.updateAction === 'update-all')
            this.updateStatus.textContent = '正在检查并更新…';
        else if (s.action === 'update-all' && s.phase === 'failed')
            this.updateStatus.textContent = '更新未完全成功，请查看维护日志。';
        else if (s.action === 'update-all' && s.phase === 'success' && latest && comparison === 0)
            this.updateStatus.textContent = '检查完成，插件已是最新版本 ' + latest;
        else if (s.action === 'update-all' && s.phase === 'success')
            this.updateStatus.textContent = '检查更新完成。';
        else if (latest && comparison === 0)
            this.updateStatus.textContent = '插件当前版本：' + latest;
        else if (available && comparison === 1)
            this.updateStatus.textContent = '插件有新版本 ' + latest + '；点击“检查更新”自动安装。';
        else if (latest && comparison === -1)
            this.updateStatus.textContent = '插件当前版本：' + (s.version || '未知');
        else
            this.updateStatus.textContent = '同时检查插件和官方镜像；有更新时自动安装并保留数据。';
    },
    beginUpdateReloadCountdown: function(version) {
        if (this.pluginReloadTimer || typeof window === 'undefined' || !window.setInterval) return;
        this.pluginReloadVersion = version;
        this.pluginReloadCountdown = 5;
        this.updateControls();
        this.pluginReloadTimer = window.setInterval(ui.createHandlerFn(this, function() {
            this.pluginReloadCountdown -= 1;
            this.updateControls();
            if (this.pluginReloadCountdown <= 0) {
                window.clearInterval(this.pluginReloadTimer);
                this.pluginReloadTimer = null;
                window.location.reload();
            }
        }), 1000);
    },
    selectLog: function(name) {
        this.activeLog = name;
        this.followLog = true;
        this.paintLog();
        this.updateLogControls();
    },
    updateLogControls: function() {
        if (!this.clearLogsButton) return;
        this.clearLogsButton.hidden = this.activeLog === 'container';
        this.clearLogsButton.disabled = !!this.localBusy || !!(this.state && this.state.busy);
        this.logHint.textContent = '最多保留 512 KiB，超出部分自动清理。';
    },
    paintLog: function() {
        if (!this.logBox || !this.state) return;
        const logs = {
            operation: this.state.output,
            container: this.state.container_log
        };
        const labels = { operation: '维护日志', container: '运行日志' };
        const text = logs[this.activeLog] || '暂无日志';
        const wasAtBottom = this.logBox.scrollHeight - this.logBox.scrollTop - this.logBox.clientHeight < 24;
        if (this.logBox.textContent !== text) this.logBox.textContent = text;
        if (this.followLog || wasAtBottom) this.logBox.scrollTop = this.logBox.scrollHeight;
        this.followLog = false;
        this.logTitle.textContent = labels[this.activeLog];
        Object.keys(this.logTabs).forEach(name => {
            const active = name === this.activeLog;
            this.logTabs[name].className = 'cbi-button' + (active ? ' cbi-button-action' : '');
            if (this.logTabs[name].setAttribute) this.logTabs[name].setAttribute('aria-pressed', active ? 'true' : 'false');
        });
    },
    refreshLogs: async function() {
        if (!this.logPanel) return;
        if ('offsetParent' in this.logPanel && this.logPanel.offsetParent === null) return;
        try {
            const logs = await this.snapshot('logs');
            this.state = Object.assign(this.state || {}, logs);
            this.paintLog();
        } catch (error) {}
    },
    run: async function(action) {
        if (this.localBusy || (this.state && this.state.busy)) throw new Error('已有操作正在执行，请等待完成。');
        if (action === 'update-all') {
            this.updateAction = action;
            this.updateStartVersion = this.state && this.state.version;
            this.selectLog('operation');
        }
        if (action === 'check') this.selectLog('operation');
        this.enqueuePendingAction = action;
        this.enqueuePreviousOperation = (this.state && this.state.operation) || '';
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
        const button = E('button', { 'class': 'cbi-button cbi-button-' + (style || 'action'),
            click: ui.createHandlerFn(this, function() { return this.run(action); }) }, [label]);
        this.buttons.push(button);
        return button;
    },
    handleSave: async function() {
        if (this.localBusy || this.state.busy) throw new Error('请等待维护操作完成后再保存。');
        this.setBusy(true);
        try {
            await this.map.save(null, true);
            const result = await commit('sub-store');
            if (result && result !== 0) throw new Error('提交设置失败');
            await ui.changes.init();
            ui.addNotification(null, E('p', {}, ['设置已保存；点击保存并应用或重启后生效。']), 'info');
        } finally { this.setBusy(false); }
    },
    handleSaveApply: async function() {
        await this.handleSave();
        this.reloadAfterTask = true;
        this.reloadTaskAccepted = false;
        try { await this.run('restart'); }
        catch (error) { this.reloadAfterTask = false; throw error; }
    },
    handleReset: function() { return this.map.reset(); },
    render: async function(data) {
        this.state = data[1];
        this.buttons = [];
        this.status = E('p');
        this.version = E('p');
        this.operation = E('p', { 'aria-live': 'polite' });
        this.address = E('input', { id: 'sub-store-management-address', 'class': 'cbi-input-text', readonly: true, style: 'width:100%',
            'aria-label': '访问地址' });
        this.open = E('a', { 'class': 'cbi-button cbi-button-positive sub-store-open-button', target: '_blank', rel: 'noopener noreferrer' }, ['点击打开 sub-store']);
        const copy = E('button', { 'class': 'cbi-button', click: ui.createHandlerFn(this, async function() {
            if (navigator.clipboard && window.isSecureContext) await navigator.clipboard.writeText(this.address.value);
            else {
                this.address.focus(); this.address.select();
                if (!document.execCommand('copy')) throw new Error('自动复制不可用，请复制已选中的链接。');
            }
            ui.addNotification(null, E('p', {}, ['管理链接已复制。']), 'info');
        }) }, ['复制访问地址']);
        this.startButton = this.button('启动服务', 'start');
        this.stopButton = this.button('停止服务', 'stop', 'negative');
        this.restartButton = this.button('重启服务', 'restart');
        const statusSection = E('div', { 'class': 'cbi-section sub-store-overview' }, [
            E('h3', {}, ['服务概览']), this.status, this.version,
            E('div', { 'class': 'sub-store-primary-actions' }, [this.open, copy]),
            E('div', { 'class': 'sub-store-service-actions' }, [
                E('span', { 'class': 'sub-store-action-label' }, ['服务控制']),
                this.startButton, this.stopButton, this.restartButton
            ]),
            E('label', { 'class': 'sub-store-address-label', for: 'sub-store-management-address' }, ['访问地址']), this.address,
            E('p', { 'class': 'cbi-value-description' }, ['完整地址含 API 参数，请直接复制使用。']),
            this.operation
        ]);
        const m = this.map = new form.Map('sub-store', null, '管理官方 Sub-Store Docker；订阅与配置请在管理页面操作。');
        const s = m.section(form.NamedSection, 'main', 'settings');
        s.tab('basic', '基本设置');
        s.tab('advanced', '高级设置');
        s.tab('logs', '日志与诊断');
        s.tab('maintenance', '更新维护');
        let o = s.taboption('basic', form.Value, 'frontend_port', '管理页面端口');
        o.datatype = 'port'; o.rmempty = false; o.default = '3001';
        o.description = '默认 3001；保存后更新 Docker 端口映射，外部端口转发需另行调整。';
        const frontend = o;
        o = s.taboption('basic', form.Value, 'access_host', '访问主机名');
        o.description = '留空使用 LAN 地址；也可填写域名或 IP，不含协议和端口。';
        o.validate = function(section, value) {
            return !value || (value.length <= 253 && /^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$/.test(value) &&
                !/\.\.|-\.|\.-/.test(value)) || '请输入域名或 IPv4，不含协议和端口。';
        };
        o = s.taboption('basic', form.Value, 'public_url', '公开访问地址');
        o.placeholder = 'https://sub.example.com';
        o.description = '可选；使用反向代理或外部端口时填写，优先用于生成管理链接。';
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
        o = s.taboption('advanced', form.Value, 'backend_port', '后端 API 端口');
        o.datatype = 'port'; o.rmempty = false; o.default = '3000';
        o.validate = function(section, value) { return +value !== +frontend.formvalue(section) || '前后端端口不能相同。'; };
        o.description = '仅供后端直连，普通用户保持默认。';
        o = s.taboption('advanced', form.Value, 'api_path', 'API 随机路径');
        o.password = true; o.rmempty = false;
        o.description = '后端访问密钥，已包含在管理地址中，请勿公开。';
        o.validate = function(section, value) { return /^[a-fA-F0-9]{48}$/.test(value) || '请输入 48 位十六进制字符。'; };
        o = s.taboption('advanced', form.Value, 'sync_cron', '自动同步计划');
        o.default = '55 23 * * *'; o.rmempty = false;
        o.description = '默认每天北京时间 23:55；不了解 Cron 时保持默认。';
        o.validate = function(section, value) { return validCron(value) || 'Cron 格式或字段范围不正确。'; };
        this.api = E('input', { readonly: true, style: 'width:100%', 'aria-label': '后端直连地址' });
        this.storage = E('pre', { style: 'white-space:pre-wrap;overflow-wrap:anywhere' });
        this.image = E('code');
        this.appVersion = E('span');
        this.created = E('span');
        this.updateStatus = E('span', { 'aria-live': 'polite' }, ['尚未检查更新']);
        this.updateButton = this.button('检查更新', 'update-all', 'positive');
        this.activeLog = 'container';
        this.followLog = true;
        this.logTabs = {};
        this.logTitle = E('span', { 'aria-live': 'polite' }, ['运行日志']);
        this.logHint = E('span');
        this.logBox = E('pre', { 'class': 'sub-store-log-output', role: 'log', 'aria-label': '日志内容' });
        const logTab = (name, label) => {
            const tab = E('button', { 'class': 'cbi-button', 'aria-pressed': 'false',
                click: ui.createHandlerFn(this, function() { this.selectLog(name); }) }, [label]);
            this.logTabs[name] = tab;
            return tab;
        };
        const checkService = this.button('检查服务', 'check', 'action');
        this.clearLogsButton = E('button', { 'class': 'cbi-button cbi-button-negative',
            click: ui.createHandlerFn(this, function() {
                return this.confirm('clear-logs', '清空维护日志',
                    '这会清除启动、重启、更新和检查服务产生的维护记录。Sub-Store 的订阅、配置、数据卷和 Docker 运行日志不会被删除。');
            }) }, ['清空维护日志']);
        this.buttons.push(this.clearLogsButton);
        const logPanel = this.logPanel = E('div', { 'class': 'sub-store-log-panel' }, [
            E('div', { 'class': 'sub-store-log-toolbar' }, [
                E('div', { 'class': 'sub-store-log-tabs', role: 'group', 'aria-label': '日志类型' }, [
                    logTab('container', '运行日志'), logTab('operation', '维护日志')
                ]),
                E('div', { 'class': 'sub-store-log-actions' }, [checkService, this.clearLogsButton])
            ]),
            E('div', { 'class': 'sub-store-log-heading' }, [
                E('strong', {}, [this.logTitle]),
                E('span', { 'class': 'cbi-value-description' }, [this.logHint])
            ]),
            this.logBox
        ]);
        const display = (tab, id, label, node) => {
            const option = s.taboption(tab, form.DummyValue, id, label);
            option.renderWidget = function() { return node; };
        };
        display('advanced', '_api', '后端直连地址', this.api);
        display('advanced', '_storage', '实际数据存储路径', this.storage);
        const rotate = E('button', { 'class': 'cbi-button cbi-button-negative',
            click: ui.createHandlerFn(this, function() {
                return this.confirm('rotate-key', '重新生成 API 访问密钥', '成功后旧管理地址会立即失效。未保存的表单修改将丢弃，请先保存需要保留的设置。');
            }) }, ['重新生成 API 密钥']);
        this.buttons.push(rotate);
        const metric = (label, value) => E('div', { 'class': 'sub-store-maintenance-metric' }, [
            E('span', { 'class': 'sub-store-maintenance-label' }, [label]), value
        ]);
        const updateCard = E('div', { 'class': 'sub-store-maintenance-card' }, [
            E('div', { 'class': 'sub-store-maintenance-copy' }, [
                E('strong', {}, ['更新']),
                E('p', {}, ['检查插件和官方镜像；有更新时自动安装并保留数据。']),
                E('p', { 'class': 'sub-store-maintenance-status' }, [this.updateStatus])
            ]),
            this.updateButton
        ]);
        const keyCard = E('div', { 'class': 'sub-store-maintenance-card' }, [
            E('div', { 'class': 'sub-store-maintenance-copy' }, [
                E('strong', {}, ['API 密钥']),
                E('p', {}, ['管理链接泄露时重新生成；旧链接会失效。'])
            ]),
            rotate
        ]);
        this.maintenancePanel = E('div', { 'class': 'sub-store-maintenance-panel' }, [
            E('div', { 'class': 'sub-store-maintenance-info' }, [
                metric('Docker 镜像', this.image),
                metric('Sub-Store 版本', this.appVersion),
                metric('容器创建时间', this.created)
            ]),
            E('div', { 'class': 'sub-store-maintenance-actions' }, [updateCard, keyCard])
        ]);
        display('maintenance', '_maintenance', '维护操作', this.maintenancePanel);
        display('logs', '_logs', '', logPanel);
        const formNode = await m.render();
        this.paint();
        poll.add(async () => {
            await this.refresh('summary');
            await this.refreshLogs();
        }, 5);
        const pageStyles = [
            '.sub-store-page .sub-store-overview{border-radius:12px;padding:1.25em;margin-bottom:1.2em}',
            '.sub-store-page .cbi-button{margin-bottom:.25em}',
            '.sub-store-page pre{font-size:inherit}',
            '.sub-store-page input[readonly]{box-sizing:border-box}',
            '.sub-store-page .sub-store-status{display:inline-flex;align-items:center;gap:.45em;max-width:100%;box-sizing:border-box;margin:.25em 0 .75em;padding:.38em .7em;border:1px solid;border-radius:4px;font-weight:600;line-height:1.4}',
            '.sub-store-page .sub-store-status.is-running{color:#256b36;background:#eaf5ec;border-color:#bfdfc5}',
            '.sub-store-page .sub-store-status.is-running:before{content:"";width:.5em;height:.5em;flex:none;border-radius:50%;background:#32934b}',
            '.sub-store-page .sub-store-status.is-warning{color:#765411;background:#fff5dc;border-color:#ead38e}',
            '.sub-store-page .sub-store-open-button{text-transform:none}',
            '.sub-store-page .sub-store-primary-actions,.sub-store-page .sub-store-service-actions{display:flex;align-items:center;gap:.5em;flex-wrap:wrap;margin:.75em 0}',
            '.sub-store-page .sub-store-service-actions{padding-top:.7em;border-top:1px solid var(--border-color,#ddd)}',
            '.sub-store-page .sub-store-action-label,.sub-store-page .sub-store-address-label{font-weight:600}',
            '.sub-store-page .sub-store-address-label{display:block;margin:.9em 0 .35em}',
            '.sub-store-page #cbi-sub-store-main-_maintenance,.sub-store-page #cbi-sub-store-main-_logs{display:block!important}',
            '.sub-store-page #cbi-sub-store-main-_maintenance>.cbi-value-title,.sub-store-page #cbi-sub-store-main-_logs>.cbi-value-title{display:none!important}',
            '.sub-store-page #cbi-sub-store-main-_maintenance>.cbi-value-field,.sub-store-page #cbi-sub-store-main-_logs>.cbi-value-field{display:block!important;width:100%!important;max-width:none!important;margin:0!important}',
            '.sub-store-page .sub-store-maintenance-panel{display:grid;gap:1em;width:100%;max-width:1080px;margin:0 auto}',
            '.sub-store-page .sub-store-maintenance-info{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:.75em}',
            '.sub-store-page .sub-store-maintenance-metric{min-width:0;padding:.8em 1em;border:1px solid var(--border-color,#ddd);border-radius:8px;background:var(--background-color-low,#f7f7f7)}',
            '.sub-store-page .sub-store-maintenance-label{display:block;margin-bottom:.35em;color:#7b8190;font-size:.9em}',
            '.sub-store-page .sub-store-maintenance-metric code{display:block;overflow-wrap:anywhere;white-space:normal}',
            '.sub-store-page .sub-store-maintenance-actions{display:grid;grid-template-columns:minmax(0,1.35fr) minmax(0,1fr);gap:.75em}',
            '.sub-store-page .sub-store-maintenance-card{display:flex;min-width:0;align-items:center;justify-content:space-between;gap:1em;padding:1em;border:1px solid var(--border-color,#ddd);border-radius:8px;background:var(--background-color-high,#fff)}',
            '.sub-store-page .sub-store-maintenance-copy{min-width:0}',
            '.sub-store-page .sub-store-maintenance-copy p{margin:.45em 0 0}',
            '.sub-store-page .sub-store-maintenance-status{color:#7b8190}',
            '.sub-store-page .sub-store-maintenance-card .cbi-button{flex:none}',
            '.sub-store-page .sub-store-log-panel{box-sizing:border-box;width:100%;max-width:1280px;margin:0 auto;padding:.85em;border:1px solid var(--border-color,#bbb);border-radius:8px;background:var(--background-color-high,#fff)}',
            '.sub-store-page .sub-store-log-toolbar{display:flex;align-items:center;justify-content:space-between;gap:.75em;flex-wrap:wrap}',
            '.sub-store-page .sub-store-log-tabs,.sub-store-page .sub-store-log-actions{display:flex;gap:.4em;flex-wrap:wrap}',
            '.sub-store-page .sub-store-log-tabs{padding:.25em;border-radius:6px;background:var(--background-color-low,#f5f5f5)}',
            '.sub-store-page .sub-store-log-heading{display:flex;align-items:baseline;gap:.65em;flex-wrap:wrap;margin:.85em 0 .4em}',
            '.sub-store-page .sub-store-log-heading .cbi-value-description{margin:0}',
            '.sub-store-page .sub-store-log-output{box-sizing:border-box;width:100%;height:24em;max-height:55vh;overflow:auto;overscroll-behavior:contain;white-space:pre;padding:.85em;border:1px solid var(--border-color,#bbb);border-radius:6px;background:var(--background-color-low,#f7f7f7);font-family:monospace;font-size:.9em;line-height:1.5}',
            '@media(prefers-color-scheme:dark){.sub-store-page .sub-store-status.is-running{color:#b5dfbd;background:#23422b;border-color:#386b44}.sub-store-page .sub-store-status.is-warning{color:#eed694;background:#463a21;border-color:#76602e}}',
            '@media(max-width:700px){.sub-store-page .sub-store-service-actions{align-items:stretch}.sub-store-page .sub-store-action-label{width:100%}.sub-store-page .sub-store-maintenance-info,.sub-store-page .sub-store-maintenance-actions{grid-template-columns:minmax(0,1fr)}.sub-store-page .sub-store-maintenance-card{align-items:stretch;flex-direction:column}.sub-store-page .sub-store-maintenance-card .cbi-button{align-self:flex-start}.sub-store-page .sub-store-log-toolbar,.sub-store-page .sub-store-log-actions{align-items:stretch}.sub-store-page .sub-store-log-tabs,.sub-store-page .sub-store-log-actions{width:100%}.sub-store-page .sub-store-log-tabs .cbi-button{flex:1}.sub-store-page .sub-store-log-output{height:20em;max-height:50vh}}'
        ].join('');
        return E('div', { 'class': 'sub-store-page' }, [
            E('style', {}, [pageStyles]),
            E('h2', {}, ['sub-store']), statusSection, formNode]);
    }
});
