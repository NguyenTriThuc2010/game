-- [System Runtime Loader]
local BASE_URL = "https://raw.githubusercontent.com/NguyenTriThuc2010/game/main/"

local function loadModule(name)
    local url = BASE_URL .. name .. ".lua?t=" .. tostring(os.time())
    local success, code = pcall(function()
        return game:HttpGet(url)
    end)
    if not success or not code or code == "" then
        warn("[SYS] Failed to fetch: " .. name)
        return false
    end
    local fn, err = loadstring(code)
    if not fn then
        warn("[SYS] Syntax error in " .. name .. ": " .. tostring(err))
        return false
    end
    local ok, ret = pcall(fn)
    if not ok then
        warn("[SYS] Runtime error in " .. name .. ": " .. tostring(ret))
        return false
    end
    return true
end

-- Shared Environment
_G.__SYS = _G.__SYS or {}

local modules = {
    "lib_env",
    "lib_dat",
    "lib_nav",
    "lib_act",
    "lib_sub",
    "lib_gui"
}

print("[SYS] Initializing core modules...")
for _, mod in ipairs(modules) do
    local ok = loadModule(mod)
    if not ok then
        warn("[SYS] Critical load failure on: " .. mod)
    end
end
print("[SYS] All modules active.")
