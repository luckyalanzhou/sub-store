local root = arg[1] or "."
local snapshot
local busy = true
local state_safe = true
local calls = {}
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
            if command:find("stat -c", 1, true) then return state_safe and 0 or 1 end
            return busy and 0 or 1
        end
    }
end
package.preload["luci.jsonc"] = function()
    return { parse = function() return nil end, stringify = function(value) snapshot = value; return "{}" end }
end
arg = { "details" }
dofile(root .. "/run/payload/root/usr/lib/sub-store/status")
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
dofile(root .. "/run/payload/root/usr/lib/sub-store/status")
assert(snapshot.container == "running")
assert(snapshot.busy == false)
assert(snapshot.storage and snapshot.image and snapshot.container_log)
assert(snapshot.health == "healthy" and snapshot.app_version == "2.42.3")
assert(snapshot.install_log == nil)
assert(snapshot.url and snapshot.api_url)
calls = {}
arg = {}
dofile(root .. "/run/payload/root/usr/lib/sub-store/status")
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
dofile(root .. "/run/payload/root/usr/lib/sub-store/status")
assert(snapshot.container_log == "test" and snapshot.output == "<script>log</script>")
arg = { "runtime-log" }
dofile(root .. "/run/payload/root/usr/lib/sub-store/status")
assert(snapshot.container_log == "test" and snapshot.output == nil)
arg = { "maintenance-log" }
dofile(root .. "/run/payload/root/usr/lib/sub-store/status")
assert(snapshot.output == "<script>log</script>" and snapshot.container_log == nil)
state_safe = false
calls = {}
arg = { "maintenance-log" }
dofile(root .. "/run/payload/root/usr/lib/sub-store/status")
assert(snapshot.output == nil and snapshot.phase == "" and snapshot.action == "" and snapshot.operation == "")
for _, command in ipairs(calls) do
    assert(not command:find("output.log", 1, true))
end
print("LuCI snapshot, maintenance fast path and runtime diagnostics passed.")
