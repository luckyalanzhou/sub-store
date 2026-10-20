local root = arg[1] or "."
local snapshot
local busy = true
local calls = {}
local plugin_state_trusted = false
local operation_state_dir_trusted = true
local operation_snapshot_fixture = os.getenv("SUB_STORE_TEST_OPERATION_SNAPSHOT")
local status_fixture_dir = os.getenv("SUB_STORE_TEST_STATUS_FIXTURE_DIR")
local original_open = io.open
io.open = function(path, mode)
    local plugin_state_file = path:match("^/tmp/sub%-store%-plugin%-update/(.+)$")
    if plugin_state_file == "latest-version" then
        return { read = function() return "0.0.24\n" end, close = function() end }
    elseif plugin_state_file == "update-available" then
        return { read = function() return "1\n" end, close = function() end }
    end
    if path == "/tmp/sub-store-operation/snapshot" then
        if operation_snapshot_fixture then return original_open(operation_snapshot_fixture, mode) end
        return nil
    end
    local state_file = status_fixture_dir and path:match("^/tmp/sub%-store%-operation/(.+)$")
    if path:match("^/tmp/sub%-store%-operation/") then
        if state_file then return original_open(status_fixture_dir .. "/" .. state_file, mode) end
        return nil
    end
    return original_open(path, mode)
end
package.preload["luci.sys"] = function()
    return {
        exec = function(command)
            calls[#calls + 1] = command
            if command:find(" status ", 1, true) then return "running\n" end
            if command:find(" health", 1, true) then return "healthy\n" end
            if command:find("app%-version") then return "2.42.3\n" end
            if command:find("output.log", 1, true) then return "<script>log</script>\n" end
            return "test\n"
        end,
        call = function(command)
            calls[#calls + 1] = command
            if command:find("/tmp/sub-store-plugin-update", 1, true) then
                return plugin_state_trusted and 0 or 1
            end
            if command:find("/tmp/sub-store-operation", 1, true) then
                if command:find("lock/pid", 1, true) then
                    return busy and operation_state_dir_trusted and 0 or 1
                end
                return operation_state_dir_trusted and 0 or 1
            end
            return busy and 0 or 1
        end
    }
end
package.preload["luci.jsonc"] = function()
    return { parse = function() return nil end, stringify = function(value) snapshot = value; return "{}" end }
end
arg = { "details" }
dofile(root .. "/installer/payload/root/usr/lib/sub-store/status")
assert(snapshot.container == "maintenance")
assert(snapshot.busy == true)
assert(snapshot.output == "<script>log</script>")
assert(snapshot.url == nil and snapshot.api_url == nil)
for _, command in ipairs(calls) do
    assert(not command:find("docker", 1, true) and not command:find("sub-storectl", 1, true))
end
busy = false
calls = {}
arg = { "details" }
dofile(root .. "/installer/payload/root/usr/lib/sub-store/status")
assert(snapshot.container == "running")
assert(snapshot.busy == false)
assert(snapshot.storage and snapshot.image and snapshot.container_log)
assert(snapshot.health == "healthy" and snapshot.app_version == "2.42.3")
assert(snapshot.install_log == nil)
assert(snapshot.url and snapshot.api_url)
calls = {}
arg = {}
dofile(root .. "/installer/payload/root/usr/lib/sub-store/status")
assert(snapshot.container == "running")
assert(snapshot.container_log == nil and snapshot.output == nil)
assert(snapshot.storage == nil and snapshot.image == nil)
local read_runtime_log = false
for _, command in ipairs(calls) do
    if command:find("docker logs --tail 100 sub-store", 1, true) then read_runtime_log = true end
end
assert(not read_runtime_log)
calls = {}
arg = { "logs" }
dofile(root .. "/installer/payload/root/usr/lib/sub-store/status")
assert(snapshot.container_log == "test" and snapshot.output == "<script>log</script>")
arg = { "runtime-log" }
dofile(root .. "/installer/payload/root/usr/lib/sub-store/status")
assert(snapshot.container_log == "test" and snapshot.output == nil)
arg = { "maintenance-log" }
dofile(root .. "/installer/payload/root/usr/lib/sub-store/status")
assert(snapshot.output == "<script>log</script>" and snapshot.container_log == nil)
if operation_snapshot_fixture then
    calls = {}
    arg = { "summary" }
    dofile(root .. "/installer/payload/root/usr/lib/sub-store/status")
    assert(snapshot.operation_id:match("^%d+%-%d+$"))
    assert(snapshot.action == "stop")
    assert(snapshot.phase == "success")
    assert(snapshot.operation:match("操作成功：stop；完成时间："))
end
if status_fixture_dir then
    calls = {}
    arg = { "summary" }
    dofile(root .. "/installer/payload/root/usr/lib/sub-store/status")
    assert(snapshot.operation_id == "")
    assert(snapshot.action == "stop")
    assert(snapshot.phase == "success")
    assert(snapshot.operation == "legacy operation status")
end
busy = false
plugin_state_trusted = true
calls = {}
arg = { "details" }
dofile(root .. "/installer/payload/root/usr/lib/sub-store/status")
assert(snapshot.plugin_latest_version == "0.0.24")
assert(snapshot.plugin_update_available == true)
local plugin_state_guarded = false
for _, command in ipairs(calls) do
    if command:find("/tmp/sub-store-plugin-update", 1, true) then
        assert(command:find("! -L", 1, true))
        assert(command:find("0:700", 1, true))
        assert(command:find("0:600:1", 1, true))
        plugin_state_guarded = true
    end
end
assert(plugin_state_guarded)
plugin_state_trusted = false
calls = {}
dofile(root .. "/installer/payload/root/usr/lib/sub-store/status")
assert(snapshot.plugin_latest_version == "")
assert(snapshot.plugin_update_available == false)
operation_state_dir_trusted = false
calls = {}
dofile(root .. "/installer/payload/root/usr/lib/sub-store/status")
assert(snapshot.operation_id == "")
assert(snapshot.phase == "" and snapshot.action == "" and snapshot.operation == "")
assert(snapshot.output == nil)
for _, command in ipairs(calls) do
    assert(not command:find("tail -n 100 /tmp/sub-store-operation/output.log", 1, true))
end
print("LuCI snapshot, maintenance fast path and runtime diagnostics passed.")
