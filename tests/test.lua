local SCRIPT = "../gear_desync.lua"
local fails, passes = 0, 0
local function check(cond, msg)
    if cond then passes=passes+1; print("  PASS  "..msg)
    else fails=fails+1; print("  FAIL  "..msg) end
end

local function fresh(cfg)
    onSettings, onExecute, onCleanup, settings = nil,nil,nil,nil
    MOCK_PRESSES  = cfg.presses
    MOCK_SETTINGS = cfg.settings
    MOCK_PLATFORM = cfg.platform
    MOCK_FREEZE_FAILS = cfg.freezeFails
    MOCK_PROC = cfg.proc
    local H = dofile("./harness.lua")
    H.setCancelAfter(cfg.cancelAfter or 3000)
    local ok, err = H.run(SCRIPT)
    return H, ok, err
end

-- compact timeline: key-downs plus freeze/lag markers
local function keyseq(H)
    local s = {}
    for _,e in ipairs(H.events()) do
        if e.kind=="down" then s[#s+1]=e.a
        elseif e.kind=="FREEZE" then s[#s+1]="[F]"
        elseif e.kind=="UNFREEZE" then s[#s+1]="[U]"
        elseif e.kind=="LAG_ON" then s[#s+1]="[L+]"
        elseif e.kind=="LAG_OFF" then s[#s+1]="[L-]" end
    end
    return table.concat(s," ")
end

local function downs(H)
    local s={} for _,e in ipairs(H.events()) do if e.kind=="down" then s[#s+1]=e.a end end
    return s
end

-- assert no UI write lands between the first and last key-down
local function noUiMidChurn(H)
    local first,last
    for i,e in ipairs(H.events()) do
        if e.kind=="down" then if not first then first=i end; last=i end
    end
    if not first then return true end
    for i=first,last do if H.events()[i].kind=="ui" then return false end end
    return true
end

--------------------------------------------------------------------------
print("\n=== TEST 1: Loop method = the shipped body (no freeze, no drop) ===")
local H,ok,err = fresh{
    presses={{atMs=100,key="F5",heldMs=40}},
    settings={method="Loop (shipped)", slots="1"},
    cancelAfter=900,
}
check(ok, "ran clean"..(ok and "" or ": "..tostring(err)))
local d = downs(H)
check(#d>0, "emitted cycles ("..#d..")")
local allOne=true; for _,k in ipairs(d) do if k~="1" then allOne=false end end
check(allOne, "every press is slot 1")
check(keyseq(H):find("%[F%]")==nil, "never calls freeze")
local sawBksp=false; for _,k in ipairs(d) do if k=="Backspace" then sawBksp=true end end
check(not sawBksp, "never presses the drop key")
check(#d % 2 == 0, "cycles come in even multiples of pairs_per_cycle=2")

--------------------------------------------------------------------------
print("\n=== TEST 2: multi-slot INTERLEAVE churns all slots each pass ===")
H,ok,err = fresh{
    presses={{atMs=100,key="F5",heldMs=30}},
    settings={method="Loop (shipped)", slots="1,2,3", order="Interleave"},
    cancelAfter=900,
}
d = downs(H)
check(ok, "ran clean"..(ok and "" or ": "..tostring(err)))
print("  first 12: "..table.concat({table.unpack(d,1,math.min(12,#d))}," "))
check(table.concat({table.unpack(d,1,6)}," ")=="1 1 2 2 3 3",
      "one pass = 1 1 2 2 3 3 (pairs=2 across 3 slots)")
local has1,has2,has3=false,false,false
for _,k in ipairs(d) do if k=="1" then has1=true elseif k=="2" then has2=true elseif k=="3" then has3=true end end
check(has1 and has2 and has3, "all three slots churned")

print("\n=== TEST 3: multi-slot ROUND ROBIN advances one slot per pass ===")
H,ok,err = fresh{
    presses={{atMs=100,key="F5",heldMs=30}},
    settings={method="Loop (shipped)", slots="1,2,3", order="Round robin"},
    cancelAfter=900,
}
d = downs(H)
check(ok, "ran clean"..(ok and "" or ": "..tostring(err)))
print("  first 12: "..table.concat({table.unpack(d,1,math.min(12,#d))}," "))
check(table.concat({table.unpack(d,1,6)}," ")=="1 1 2 2 3 3",
      "passes rotate 1,1 then 2,2 then 3,3")

print("\n=== TEST 4: multi-slot BURST finishes a slot before moving on ===")
H,ok,err = fresh{
    presses={{atMs=100,key="F5",heldMs=30}},
    settings={method="Loop (shipped)", slots="1,2", order="Burst per slot", burst_len=3},
    cancelAfter=900,
}
d = downs(H)
check(ok, "ran clean"..(ok and "" or ": "..tostring(err)))
print("  first 14: "..table.concat({table.unpack(d,1,math.min(14,#d))}," "))
check(table.concat({table.unpack(d,1,6)}," ")=="1 1 1 1 1 1",
      "burst_len=3 x pairs=2 -> six presses of slot 1 first")
check(d[7]=="2", "then switches to slot 2")

--------------------------------------------------------------------------
print("\n=== TEST 5: loop stops when the trigger is released ===")
H,ok,err = fresh{
    presses={{atMs=100,key="F5",heldMs=50}},
    settings={method="Loop (shipped)", slots="1"},
    cancelAfter=2000,
}
local lastDown=0
for _,e in ipairs(H.events()) do if e.kind=="down" then lastDown=e.t end end
print(string.format("  last press at %.0fms, trigger released at 150ms", lastDown))
check(lastDown<=155, "no presses after the trigger is released")

print("\n=== TEST 6: max_run_s safety stops a held trigger ===")
H,ok,err = fresh{
    presses={{atMs=50,key="F5",heldMs=5000}},
    settings={method="Loop (shipped)", slots="1", max_run_s=1},
    cancelAfter=8000,
}
check(ok, "ran clean"..(ok and "" or ": "..tostring(err)))
lastDown=0
for _,e in ipairs(H.events()) do if e.kind=="down" then lastDown=e.t end end
print(string.format("  churn ended at %.0fms", lastDown))
check(lastDown<1200, "stopped at the 1s safety limit, not 5s")
check((H.dynamic()["log"] or ""):find("safety stop")~=nil, "logs the safety stop")

--------------------------------------------------------------------------
print("\n=== TEST 7: Freeze burst queues cycles inside the frozen window ===")
H,ok,err = fresh{
    presses={{atMs=100,key="F5",heldMs=40}},
    settings={method="Freeze burst", slots="1,2", fb_drift_ms=200, fb_burst_ms=100, fb_tail_ms=80},
    cancelAfter=3000,
}
check(ok, "ran clean"..(ok and "" or ": "..tostring(err)))
local inside,outside=0,0
for _,e in ipairs(H.events()) do
    if e.kind=="down" then if e.frozen then inside=inside+1 else outside=outside+1 end end
end
print("  cycles inside freeze: "..inside..", outside: "..outside)
check(inside>0, "cycles land while frozen")
check(outside==0, "no cycles land outside the frozen window")
check(H.frozen()==false, "unfrozen at the end")

local tf,tu
for _,e in ipairs(H.events()) do
    if e.kind=="FREEZE" then tf=e.t elseif e.kind=="UNFREEZE" then tu=e.t end
end
print(string.format("  frozen window: %.0fms (planned 380)", tu-tf))
check(math.abs((tu-tf)-380)<25, "window matches drift+burst+tail")

--------------------------------------------------------------------------
print("\n=== TEST 8: Ground item setup + trigger ===")
H,ok,err = fresh{
    presses={{atMs=100,key="F6",heldMs=40}},
    settings={method="Ground item (2023 wiki)", slots="1", gi_ground_slot=2},
    cancelAfter=1500,
}
check(ok, "setup ran clean"..(ok and "" or ": "..tostring(err)))
check(keyseq(H)=="2 Backspace 1", "setup emits 2 -> Backspace -> 1")

H,ok,err = fresh{
    presses={{atMs=100,key="F5",heldMs=40}},
    settings={method="Ground item (2023 wiki)", slots="1", gi_taps=2},
    cancelAfter=3000,
}
check(ok, "trigger ran clean"..(ok and "" or ": "..tostring(err)))
print("  seq: "..keyseq(H))
check(keyseq(H)=="[F] 1 1 [U] 1 Backspace", "freeze, tap x2, unfreeze, equip, drop")

print("\n=== TEST 9: Ground item with several slots drops each one ===")
H,ok,err = fresh{
    presses={{atMs=100,key="F5",heldMs=40}},
    settings={method="Ground item (2023 wiki)", slots="1,3", gi_taps=2},
    cancelAfter=3000,
}
print("  seq: "..keyseq(H))
check(keyseq(H)=="[F] 1 1 3 3 [U] 1 Backspace 3 Backspace",
      "both slots tapped while frozen, both equipped+dropped after")

--------------------------------------------------------------------------
print("\n=== TEST 10: cleanup leaves nothing held, frozen or lagging ===")
local held=0; for _ in pairs(H.heldKeys()) do held=held+1 end
check(held==0, "no keys held")
check(H.frozen()==false, "not frozen")
check(H.lagging()==false, "not lagging")

print("\n=== TEST 11: lag switch layers onto the loop method ===")
H,ok,err = fresh{
    presses={{atMs=100,key="F5",heldMs=30}},
    settings={method="Loop (shipped)", slots="1", use_lag=true, lag_fake=true},
    cancelAfter=1500,
}
check(ok, "ran clean"..(ok and "" or ": "..tostring(err)))
local s=keyseq(H)
check(s:find("%[L%+%]")~=nil and s:find("%[L%-%]")~=nil, "lag on before churn, off after")
check(H.lagging()==false, "lag released")

--------------------------------------------------------------------------
print("\n=== TEST 12: no UI writes mid-churn (they would dominate the loop) ===")
H,ok,err = fresh{
    presses={{atMs=100,key="F5",heldMs=60}},
    settings={method="Loop (shipped)", slots="1,2"},
    cancelAfter=1500,
}
check(noUiMidChurn(H), "zero ui.setDynamicText calls between first and last press")

H,ok,err = fresh{
    presses={{atMs=100,key="F5",heldMs=40}},
    settings={method="Freeze burst", slots="1"},
    cancelAfter=3000,
}
check(noUiMidChurn(H), "same during the freeze burst")

--------------------------------------------------------------------------
print("\n=== TEST 13: slot parsing ===")
H,ok,err = fresh{ settings={selftest=true, slots="1, 2 ;3"}, cancelAfter=1500 }
local txt=H.dynamic()["log"] or ""
check(txt:find("%[1,2,3%]")~=nil, "accepts commas, spaces and semicolons")

H,ok,err = fresh{ settings={selftest=true, slots="1,10,x,99"}, cancelAfter=1500 }
txt=H.dynamic()["log"] or ""
check(txt:find("%[1,0%]")~=nil, "10 maps to the 0 key")
check(txt:find("ignored unparseable entries")~=nil, "reports junk entries")

H,ok,err = fresh{ settings={slots="abc"}, cancelAfter=300 }
txt=H.dynamic()["log"] or ""
check(txt:find("REFUSED")~=nil, "refuses when no slot parses")

H,ok,err = fresh{ settings={selftest=true, slots="2,2,2"}, cancelAfter=1500 }
txt=H.dynamic()["log"] or ""
check(txt:find("%[2%]")~=nil, "de-duplicates repeated slots")

--------------------------------------------------------------------------
print("\n=== TEST 14: self-test surfaces the built-in macro's settings ===")
H,ok,err = fresh{ settings={selftest=true}, cancelAfter=1500 }
txt=H.dynamic()["log"] or ""
check(ok, "ran"..(ok and "" or ": "..tostring(err)))
check(txt:find("desync_slot")~=nil, "prints built-in desync_slot")
check(txt:find("clip_delay")~=nil, "prints built-in clip_delay")
check(txt:find("churn rate")~=nil, "measures achievable churn rate")

print("\n=== TEST 15: self-test survives freeze() raising ===")
H,ok,err = fresh{ settings={selftest=true}, freezeFails=true, cancelAfter=1500 }
txt=H.dynamic()["log"] or ""
check(ok, "did not crash"..(ok and "" or ": "..tostring(err)))
check(txt:find("ERRORED")~=nil, "reports the failure")
check(H.frozen()==false, "not left frozen")

--------------------------------------------------------------------------
print(string.format("\n==== %d passed, %d failed ====", passes, fails))
os.exit(fails==0 and 0 or 1)
