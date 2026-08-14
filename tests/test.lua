package.path = "./?.lua;"..package.path
local SCRIPT = "../gear_desync.lua"

local fails, passes = 0, 0
local function check(cond, msg)
    if cond then passes=passes+1; print("  PASS  "..msg)
    else fails=fails+1; print("  FAIL  "..msg) end
end

local function fresh(cfg)
    for k in pairs(package.loaded) do if k=="harness" then package.loaded[k]=nil end end
    onSettings, onExecute, onCleanup, settings = nil,nil,nil,nil
    MOCK_PRESSES = cfg.presses
    MOCK_SETTINGS = cfg.settings
    MOCK_PLATFORM = cfg.platform
    MOCK_FREEZE_FAILS = cfg.freezeFails
    MOCK_PROC = cfg.proc
    local H = dofile("./harness.lua")
    H.setCancelAfter(cfg.cancelAfter or 3000)
    local ok, err = H.run(SCRIPT)
    return H, ok, err
end

local function keyseq(H)
    local s = {}
    for _,e in ipairs(H.events()) do
        if e.kind=="down" then s[#s+1]=e.a
        elseif e.kind=="FREEZE" then s[#s+1]="[FREEZE]"
        elseif e.kind=="UNFREEZE" then s[#s+1]="[UNFREEZE]"
        elseif e.kind=="LAG_ON" then s[#s+1]="[LAG_ON]"
        elseif e.kind=="LAG_OFF" then s[#s+1]="[LAG_OFF]" end
    end
    return table.concat(s," ")
end

--------------------------------------------------------------------------
print("\n=== TEST 1: SETUP phase emits wiki steps 2-3 (slot B, drop, slot A) ===")
local H,ok,err = fresh{
    presses = { {atMs=100, key="F6", heldMs=50} },
    cancelAfter = 800,
}
check(ok, "onExecute completed without error"..(ok and "" or ": "..tostring(err)))
local seq = keyseq(H)
print("  seq: "..seq)
check(seq=="2 Backspace 1", "emits 2 -> Backspace -> 1 (equip B, drop it, equip A)")

--------------------------------------------------------------------------
print("\n=== TEST 2: TRIGGER phase emits wiki steps 4-6 ===")
H,ok,err = fresh{
    presses = { {atMs=100, key="F5", heldMs=50} },
    cancelAfter = 3000,
}
check(ok, "onExecute completed without error"..(ok and "" or ": "..tostring(err)))
seq = keyseq(H)
print("  seq: "..seq)
check(seq=="[FREEZE] 1 1 [UNFREEZE] 1 Backspace",
      "freeze -> tap A twice -> unfreeze -> equip A -> drop")

-- the two taps must be strictly inside the frozen window
local insideFrozen, outsideAfter = 0, 0
local seenUnfreeze = false
for _,e in ipairs(H.events()) do
    if e.kind=="UNFREEZE" then seenUnfreeze=true end
    if e.kind=="down" and e.a=="1" then
        if e.frozen then insideFrozen=insideFrozen+1
        elseif seenUnfreeze then outsideAfter=outsideAfter+1 end
    end
end
check(insideFrozen==2, "exactly 2 slot-A taps land while frozen (got "..insideFrozen..")")
check(outsideAfter==1, "exactly 1 slot-A tap after unfreeze (got "..outsideAfter..")")

-- measure the real frozen window
local tf, tu
for _,e in ipairs(H.events()) do
    if e.kind=="FREEZE" then tf=e.t end
    if e.kind=="UNFREEZE" then tu=e.t end
end
local window = tu-tf
print(string.format("  frozen window: %.0fms", window))
check(math.abs(window-(250+130+2*(18+18)))<1,
      "frozen window matches plannedFreezeMs() = 452ms (got "..string.format("%.0f",window)..")")

--------------------------------------------------------------------------
print("\n=== TEST 3: no key left held, not frozen, not lagging after cleanup ===")
local held=0; for _ in pairs(H.heldKeys()) do held=held+1 end
check(held==0, "no keys still held")
check(H.frozen()==false, "process not left frozen")
check(H.lagging()==false, "lag switch not left on")

--------------------------------------------------------------------------
print("\n=== TEST 4: lag switch path uses only documented option keys ===")
H,ok,err = fresh{
    presses = { {atMs=100, key="F5", heldMs=50} },
    settings = { use_lag=true, use_freeze=false, lag_fake=true },
    cancelAfter = 3000,
}
check(ok, "lag path ran without error"..(ok and "" or ": "..tostring(err)))
seq = keyseq(H)
print("  seq: "..seq)
check(seq:find("%[LAG_ON%]")~=nil and seq:find("%[LAG_OFF%]")~=nil, "lag toggled on and off")
local sawClear=false
for _,e in ipairs(H.events()) do if e.kind=="LAG_CFG_CLEAR" then sawClear=true end end
check(sawClear, "clearLagSwitchConfig() called in cleanup")

--------------------------------------------------------------------------
print("\n=== TEST 5: self-test detects a freeze that is not landing ===")
H,ok,err = fresh{
    settings = { selftest=true },
    freezeFails = true,
    cancelAfter = 100,
}
check(ok, "self-test survives freeze() raising"..(ok and "" or ": "..tostring(err)))
local txt = H.dynamic()["log"] or ""
check(txt:find("ERRORED")~=nil, "reports freeze(true) ERRORED")
check(H.frozen()==false, "does not leave the process frozen after a failed freeze")

print("\n=== TEST 6: self-test flags an empty target process name ===")
H,ok,err = fresh{ settings={selftest=true}, proc="", cancelAfter=100 }
txt = H.dynamic()["log"] or ""
check(ok, "ran"..(ok and "" or ": "..tostring(err)))
check(txt:find("EMPTY")~=nil, "flags empty process name")

print("\n=== TEST 7: self-test detects a client still logging while 'frozen' ===")
-- freeze() succeeds but the mock keeps emitting log lines only when unfrozen,
-- so a working freeze => 0 lines. Verify the healthy path reports that.
H,ok,err = fresh{ settings={selftest=true}, cancelAfter=100 }
txt = H.dynamic()["log"] or ""
check(txt:find("log lines written while suspended: 0")~=nil,
      "healthy freeze reports 0 log lines during suspension")
check(txt:find("consistent with a real freeze")~=nil, "reports freeze looks real")

print("\n=== TEST 8: macOS reports lag switch unavailable ===")
H,ok,err = fresh{ settings={selftest=true}, platform="macos", cancelAfter=100 }
txt = H.dynamic()["log"] or ""
check(txt:find("unavailable")~=nil, "surfaces unsupportedReason on macOS")

--------------------------------------------------------------------------
print("\n=== TEST 9: refuses slot A == slot B ===")
H,ok,err = fresh{ settings={slot_a=1, slot_b=1}, cancelAfter=100 }
txt = H.dynamic()["log"] or ""
check(txt:find("REFUSED")~=nil, "refuses identical slots")

print("\n=== TEST 10: refuses an over-cap freeze window ===")
H,ok,err = fresh{ settings={drift_ms=2000, tail_ms=2000, frozen_taps=8}, cancelAfter=100 }
txt = H.dynamic()["log"] or ""
check(txt:find("REFUSED")~=nil, "refuses >4000ms frozen window")

print("\n=== TEST 11: no UI writes inside the frozen window ===")
-- instrument: count setDynamicText calls between FREEZE and UNFREEZE
local uiWrites = 0
local realRun = true
do
    onSettings, onExecute, onCleanup, settings = nil,nil,nil,nil
    MOCK_PRESSES = { {atMs=100, key="F5", heldMs=50} }
    MOCK_SETTINGS, MOCK_PLATFORM, MOCK_FREEZE_FAILS, MOCK_PROC = nil,nil,nil,nil
    local Hh = dofile("./harness.lua")
    Hh.setCancelAfter(3000)
    local origSet = ui.setDynamicText
    local isFrozen = false
    local origFreeze = freeze
    freeze = function(en) isFrozen = en; return origFreeze(en) end
    robloxFreeze, roblox_freeze = freeze, freeze
    ui.setDynamicText = function(id,t) if isFrozen then uiWrites = uiWrites + 1 end return origSet(id,t) end
    Hh.run(SCRIPT)
end
print("  UI writes during freeze: "..uiWrites)
check(uiWrites==0, "zero ui.setDynamicText calls while the client is suspended")

--------------------------------------------------------------------------
print(string.format("\n==== %d passed, %d failed ====", passes, fails))
os.exit(fails==0 and 0 or 1)
