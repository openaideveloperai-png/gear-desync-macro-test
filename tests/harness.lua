-- Mock SMU host: stubs every documented API, records the emitted timeline,
-- and drives onSettings/onExecute/onCleanup.

local T = 0            -- virtual clock, micros
local events = {}
local uiDefs = {}
local dynamic = {}
local frozenNow = false
local lagNow = false

settings = {}

local function rec(kind, a, b)
    events[#events+1] = { t = T/1000, kind = kind, a = a, b = b, frozen = frozenNow }
end

-- ---- utility ----
function log(m) rec("log", tostring(m)) end
function sleep(ms) assert(type(ms)=="number", "sleep got "..type(ms)); T = T + ms*1000 end
function sleepMicros(us) T = T + us end
function nowMicros() return T end
function getUnixTimestamp() return 1700000000 end
function getSMUVersion() return "3.1.4-mock" end
function getPlatform() return MOCK_PLATFORM or "windows" end
function getScriptHotkey() return "F9" end

local SAVED = {
    settingsBuffer      = MOCK_PROC ~= nil and MOCK_PROC or "RobloxPlayerBeta.exe",
    maxfreezetime       = 5,
    maxfreezeoverride   = 250,
    freezeoutsideroblox = false,
    isfreezeswitch      = true,
    takeallprocessids   = false,
}
function getSavedValue(n)
    if SAVED[n] == nil then return nil end
    return SAVED[n]
end

local logAvailable = true
function readRobloxLog(includeExisting)
    -- a live client emits lines; a frozen one does not
    local lines = {}
    if not frozenNow and logAvailable then
        lines = { "[FLog::Output] tick", "[FLog::Network] heartbeat" }
    end
    return { available = logAvailable, startedNewLog = false, path = "/mock/log.txt",
             lines = lines, state = "attached", placeId = 1, userId = 2,
             universeId = 3, jobId = "j", clientChannel = "live",
             resolution = "ok", server = "1.2.3.4" }
end
robloxLog = { read = readRobloxLog }

-- ---- execution control ----
local cancelAfter = math.huge
function isCancelled() return T/1000 > cancelAfter end
function sleepUntilCancelled(ms) sleep(ms) return isCancelled() end
function throwIfCancelled() if isCancelled() then error("cancelled") end end
function checkpoint() T = T + 10 end   -- loop overhead
function shouldYield() return false end

-- ---- ui ----
ui = {}
function ui.text(t,w) uiDefs[#uiDefs+1]={k="text"} end
function ui.separator(s) end
function ui.checkbox(id,l,d,w) uiDefs[#uiDefs+1]={k="checkbox",id=id,d=d}; if settings[id]==nil then settings[id]=d end end
function ui.sliderInt(id,l,d,mn,mx,w)
    assert(type(d)=="number" and type(mn)=="number" and type(mx)=="number",
        "sliderInt "..id.." bad numeric args")
    assert(d>=mn and d<=mx, "sliderInt "..id.." default "..tostring(d).." outside ["..mn..","..mx.."]")
    uiDefs[#uiDefs+1]={k="sliderInt",id=id,d=d,mn=mn,mx=mx}
    if settings[id]==nil then settings[id]=d end
end
function ui.sliderFloat(id,l,d,mn,mx,w) ui.sliderInt(id,l,d,mn,mx,w) end
function ui.dropdown(id,l,o,d,w)
    assert(type(o)=="table" and #o>0, "dropdown "..id.." needs an options array")
    local hit=false
    for _,v in ipairs(o) do if v==d then hit=true end end
    assert(hit or type(d)=="number", "dropdown "..id.." default '"..tostring(d).."' not in options")
    uiDefs[#uiDefs+1]={k="dropdown",id=id,d=d,opts=o}
    if settings[id]==nil then settings[id]=d end
end
function ui.textbox(id,l,d,w,h) if settings[id]==nil then settings[id]=d end end
function ui.dynamicTextbox(id,l,d,w,h) dynamic[id]=d; uiDefs[#uiDefs+1]={k="dyn",id=id} end
function ui.setDynamicText(id,t)
    assert(dynamic[id]~=nil, "setDynamicText on undeclared id '"..tostring(id).."'")
    rec("ui"); dynamic[id]=t
end
function ui.keybind(id,l,d,w) if settings[id]==nil then settings[id]=d end end
function ui.hotkey(id,l,d,w) uiDefs[#uiDefs+1]={k="hotkey",id=id,d=d}; if settings[id]==nil then settings[id]=d end end
function ui.keyCombo(id,l,d,w) uiDefs[#uiDefs+1]={k="combo",id=id,d=d}; if settings[id]==nil then settings[id]=d end end
function ui.button(id,l,a,b,c) end

-- ---- input ----
local VALID_KEYS = {}
for _,k in ipairs({"0","1","2","3","4","5","6","7","8","9","Backspace","Space",
    "Enter","Delete","Tab","Escape","LMB","RMB","MMB","F1","F2","F3","F4","F5",
    "F6","F7","F8","F9"}) do VALID_KEYS[k]=true end
for c=string.byte("A"),string.byte("Z") do VALID_KEYS[string.char(c)]=true end

local down = {}
function holdKey(k)
    assert(VALID_KEYS[k], "holdKey: invalid key name '"..tostring(k).."'")
    assert(not down[k], "holdKey: '"..k.."' already held (double-hold leak)")
    down[k]=true; rec("down",k); T = T + 20   -- SendInput cost
end
function releaseKey(k)
    assert(VALID_KEYS[k], "releaseKey: invalid key name '"..tostring(k).."'")
    down[k]=nil; rec("up",k); T = T + 20
end
function pressKey(k,d) holdKey(k); sleep(d or 10); releaseKey(k) end
function isKeyPressed(k) return down[k]==true end
function clickMouse(k,d) rec("click",k) end
function typeText(t,d) end
function mouseWheel(d) end

-- scripted hotkey timeline: {atMs=..., key=..., heldMs=...}
local PRESSES = MOCK_PRESSES or {}
local function hotkeyDown(hk)
    local ms = T/1000
    for _,p in ipairs(PRESSES) do
        if p.key==hk and ms>=p.atMs and ms < p.atMs+(p.heldMs or 60) then return true end
    end
    return false
end
function isHotkeyPressed(hk,o) return hotkeyDown(hk) end

input = {}
local hotkeyMode = "loose"
function input.isPressed(hk,o)
    assert(type(hk)=="string" and hk~="", "input.isPressed got bad hotkey: "..tostring(hk))
    return hotkeyDown(hk)
end
function input.setHotkeyMode(m)
    assert(m=="loose" or m=="strict", "bad hotkey mode "..tostring(m)); hotkeyMode=m
end
function input.getHotkeyMode() return hotkeyMode end
function input.hold(h) end
function input.release(h) end
function input.setHeld(h,d) end
function input.toggleHeld(h) end
function input.releaseAllManaged() end

-- ---- mouse/pixel ----
function moveMouse() end
function moveMouseAbs() end
function getPixelColor() return 0 end

-- ---- freeze / lag ----
local inCleanup = false
function freeze(en)
    assert(type(en)=="boolean", "freeze() needs a boolean, got "..type(en))
    if en and inCleanup then error("freeze(true) is not allowed during onCleanup") end
    if MOCK_FREEZE_FAILS then error("no target process matched") end
    frozenNow = en; rec(en and "FREEZE" or "UNFREEZE")
end
robloxFreeze = freeze
roblox_freeze = freeze

local VALID_LAG_KEYS = {
    hardBlockInbound=1, hardBlockOutbound=1, fakeLag=1, fakeLagInbound=1,
    fakeLagOutbound=1, fakeLagDelayMs=1, targetMode=1, useUdp=1, useTcp=1,
    preventDisconnect=1, autoUnblock=1, maxDurationSeconds=1,
    unblockDurationMs=1, remoteIps=1, remotePorts=1, includeRobloxDynamicIps=1,
}
function lagSwitch(en, opts)
    assert(type(en)=="boolean", "lagSwitch() needs a boolean")
    if opts ~= nil then
        assert(type(opts)=="table","lagSwitch opts must be a table")
        for k,v in pairs(opts) do
            assert(VALID_LAG_KEYS[k], "lagSwitch: UNKNOWN option key '"..k.."'")
            if k=="targetMode" then
                assert(v=="roblox" or v=="all" or v=="custom", "bad targetMode "..tostring(v))
            end
        end
    end
    lagNow = en; rec(en and "LAG_ON" or "LAG_OFF")
end
lagswitch = lagSwitch
function getLagSwitchConfig() return {} end
function setLagSwitchConfig(o) end
function clearLagSwitchConfig() rec("LAG_CFG_CLEAR") end
function getLagSwitchStatus()
    if MOCK_PLATFORM=="macos" then
        return { available=false, active=false, targetMode="roblox",
                 unsupportedReason="native backend unavailable on macOS" }
    end
    return { available=true, active=lagNow, targetMode="roblox", unsupportedReason="" }
end

-- ---- driver ----
local function run(scriptPath)
    local chunk = assert(loadfile(scriptPath))
    chunk()
    if onSettings then
        local t0=T
        onSettings()
        assert((T-t0)/1e6 < 5, "onSettings exceeded its 5s budget")
    end
    for k,v in pairs(MOCK_SETTINGS or {}) do settings[k]=v end
    local ok, err = pcall(onExecute)
    inCleanup = true
    if onCleanup then onCleanup(ok and "completed" or "error") end
    return ok, err
end

return {
    run = run, events = function() return events end,
    dynamic = function() return dynamic end,
    setCancelAfter = function(ms) cancelAfter = ms end,
    frozen = function() return frozenNow end,
    lagging = function() return lagNow end,
    heldKeys = function() return down end,
    uiDefs = function() return uiDefs end,
}
