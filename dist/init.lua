-- [System Runtime Loader]
local URL = "https://raw.githubusercontent.com/NguyenTriThuc2010/game/main/dist/sys_runtime.lua?t=" .. tostring(os.time())
local success, code = pcall(function()
    return game:HttpGet(URL)
end)
if not success or not code or code == "" or code:find("404: Not Found") then
    warn("[SYS] Khong the tai runtime.")
    return
end
local fn, err = loadstring(code)
if not fn then
    warn("[SYS] Loi bien dich: " .. tostring(err))
    return
end
local ok, ret = pcall(fn)
if not ok then
    warn("[SYS] Loi thuc thi: " .. tostring(ret))
end
