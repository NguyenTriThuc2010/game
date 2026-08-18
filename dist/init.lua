-- [System Runtime Loader]
local URL = "https://raw.githubusercontent.com/NguyenTriThuc2010/game/main/dist/sys_runtime.lua?t=" .. tostring(os.time())
local ok, code = pcall(function() return game:HttpGet(URL) end)
if not ok or not code or code == "" or code:sub(1, 3) == "404" then
    warn("[SYS] Khong the tai runtime.")
    return
end
local fn, err = loadstring(code)
if not fn then
    warn("[SYS] Loi bien dich: " .. tostring(err))
    return
end
local ok2, ret = pcall(fn)
if not ok2 then
    warn("[SYS] Loi thuc thi: " .. tostring(ret))
end
