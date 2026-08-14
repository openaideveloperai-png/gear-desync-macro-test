-- @name: Gear Desync v4 (multi-slot)
-- @desc: Item/gear desync built on SMU's own shipped implementation - a tight zero-delay equip/unequip loop - extended to churn several hotbar slots at once so you can desync multiple items. Freeze and ground-item variants included as fallbacks, plus a self-test that reads your built-in macro's settings.
-- @author: you
-- @version: 4.0
-- @keybind: F9
-- @memoryLimitMB: 32
--
-- ============================================================================
-- WHAT THE SHIPPED MACRO ACTUALLY DOES
--
--   SMU has a built-in "Item Desync" macro. Its entire body, from
--   app/macro_runtime.cpp, is:
--
--       const unsigned int slotKey = InventorySlotKey(desync_slot);
--       HoldKey(slotKey);  ReleaseKey(slotKey);
--       HoldKey(slotKey);  ReleaseKey(slotKey);
--
--   run every runtime tick for as long as the trigger is held. That is the
--   whole thing. Note what is NOT there:
--     - no freeze()
--     - no drop key / Backspace
--     - no second inventory slot, no item on the ground
--     - no delay at all between the presses
--
--   The zero delay is deliberate. The sibling Item Clip macro is the same
--   shape but sleeps clip_delay/2 between press and release; Item Desync is
--   the flat-out variant. You are equipping and unequipping faster than the
--   server can replicate the Handle weld, so the server's copy of the handle
--   lags behind the client's.
--
--   Freeze is a SEPARATE macro in SMU (its own hotkey, vk_mbutton). People
--   combine the two by hand. That is where the "freeze" step in the 2023
--   wiki writeup comes from - it is not part of item desync itself.
--
-- METHODS HERE
--   1. LOOP        - the shipped implementation, generalised to N slots.
--                    Hold the trigger, it churns. Start here.
--   2. FREEZE BURST- the same churn, but queued into a suspended client so
--                    the whole burst flushes in one or two frames.
--   3. GROUND ITEM - the 2023 wiki procedure (drop an item, walk to it,
--                    freeze, tap twice, unfreeze, equip+drop). Kept because
--                    it is a genuinely different positional desync, but it
--                    is the least likely of the three to still work.
--
-- MULTIPLE ITEMS
--   Put every slot you want desynced in the Slots box: "1,2,3". Interleave
--   mode churns all of them each cycle, which is the direct generalisation
--   of the shipped macro. If they fight each other, try Burst mode, which
--   finishes one slot before starting the next.
--
-- FIRST RUN
--   Tick "Self-test only". It prints your built-in Item Desync macro's own
--   saved settings (slot, hotkey) so you can compare them against what this
--   script is doing, and checks freeze/lag availability.
-- ============================================================================

--------------------------------------------------------------------------------
-- state that onCleanup has to be able to reach
--------------------------------------------------------------------------------

local heldKeys  = {}
local frozen    = false
local lagging   = false
local laggedCfg = false

--------------------------------------------------------------------------------
-- helpers
--------------------------------------------------------------------------------

local function num(v, default)
    local n = tonumber(v)
    if n == nil then return default end
    return n
end

local function saved(name)
    local ok, v = pcall(getSavedValue, name)
    if ok then return v end
    return nil
end

-- Hotbar slot -> key name. SMU's InventorySlotKey clamps 0..9 and adds VK_0,
-- so a slot is just its literal digit. We additionally accept 10 as a
-- friendlier spelling of the 0 key.
local function slotToKey(n)
    n = math.floor(num(n, -1))
    if n == 10 then return "0" end
    if n >= 0 and n <= 9 then return tostring(n) end
    return nil
end

-- "1,2,3" / "1 2 3" / "1;2" -> { "1", "2", "3" }
local function parseSlots(str)
    local keys, seen, bad = {}, {}, {}
    for tok in tostring(str or ""):gmatch("[^,%s;]+") do
        local k = slotToKey(tok)
        if k == nil then
            bad[#bad + 1] = tok
        elseif not seen[k] then
            seen[k] = true
            keys[#keys + 1] = k
        end
    end
    return keys, bad
end

--------------------------------------------------------------------------------
-- logging
--
-- ui.setDynamicText + table.concat is unbounded work; inside a freeze window or
-- a zero-delay churn loop it is the dominant cost and wrecks the timing we are
-- trying to control. Buffer while it matters, flush after.
--------------------------------------------------------------------------------

local logLines = {}
local logT0    = 0
local logDefer = false

local function flushLog()
    ui.setDynamicText("log", table.concat(logLines, "\n"))
end

local function resetLog()
    logLines = {}
    logDefer = false
    logT0    = nowMicros()
end

local function step(fmt, ...)
    local ms  = (nowMicros() - logT0) / 1000.0
    local msg = fmt
    if select("#", ...) > 0 then
        local ok, formatted = pcall(string.format, fmt, ...)
        msg = ok and formatted or fmt
    end
    logLines[#logLines + 1] = string.format("%8.1fms  %s", ms, msg)
    while #logLines > 60 do
        table.remove(logLines, 1)
    end
    if not logDefer then flushLog() end
end

--------------------------------------------------------------------------------
-- input
--------------------------------------------------------------------------------

-- The shipped macro's unit of work: one down/up with no sleep in between.
local function cycleKey(key, holdMs)
    holdKey(key)
    heldKeys[key] = true
    if holdMs and holdMs > 0 then sleep(holdMs) end
    releaseKey(key)
    heldKeys[key] = nil
end

local function tapKey(key, holdMs, gapMs)
    cycleKey(key, holdMs)
    if gapMs and gapMs > 0 then sleep(gapMs) end
end

local function releaseAllKeys()
    for k in pairs(heldKeys) do
        pcall(releaseKey, k)
    end
    heldKeys = {}
end

local function waitRelease(hotkey)
    while input.isPressed(hotkey) and not isCancelled() do
        if sleepUntilCancelled(5) then return end
    end
end

local function setFrozen(on)
    freeze(on)
    frozen = on
end

--------------------------------------------------------------------------------
-- settings
--------------------------------------------------------------------------------

local METHODS = { "Loop (shipped)", "Freeze burst", "Ground item (2023 wiki)" }
local ORDERS  = { "Interleave", "Burst per slot", "Round robin" }

function onSettings()
    ui.text("Gear desync. The default method is SMU's own shipped Item Desync "
        .. "implementation - a zero-delay equip/unequip loop - extended to "
        .. "several slots at once. Run the self-test first.", 470)
    ui.separator(6)

    ui.checkbox("selftest", "Self-test only (diagnose, do not glitch)", false, 330)
    ui.separator(6)

    ui.text("METHOD", 470)
    ui.dropdown("method", "Method", METHODS, METHODS[1], 330)
    ui.hotkey("trigger", "Trigger (method 1 is hold-to-run)", "F5", 300)
    ui.separator(6)

    ui.text("SLOTS - the items to desync. Comma separated, e.g. \"1,2,3\". "
        .. "Use 10 or 0 for the 0 key. One slot behaves exactly like the "
        .. "shipped macro.", 470)
    ui.textbox("slots", "Slots", "1", 300, 0)
    ui.dropdown("order", "Multi-slot order", ORDERS, ORDERS[1], 330)
    ui.sliderInt("burst_len", "Cycles per slot in Burst mode", 6, 1, 60, 330)
    ui.separator(6)

    ui.text("CHURN - the shipped macro uses 2 cycles per tick, 0ms hold, 0ms "
        .. "delay. Raise the delay only if zero is too fast for the game.", 470)
    ui.sliderInt("pairs_per_cycle", "Equip/unequip cycles per pass", 2, 1, 16, 330)
    ui.sliderInt("tap_hold_ms", "Key hold (ms, 0 = shipped behaviour)", 0, 0, 60, 330)
    ui.sliderInt("cycle_delay_ms", "Delay between passes (ms, 0 = flat out)", 0, 0, 200, 330)
    ui.sliderInt("max_run_s", "Safety: stop holding after (s, 0 = no limit)", 30, 0, 300, 330)
    ui.separator(6)

    ui.text("FREEZE BURST (method 2)", 470)
    ui.sliderInt("fb_drift_ms", "Drift before the burst (ms)", 250, 0, 2000, 330)
    ui.sliderInt("fb_burst_ms", "Burst length while frozen (ms)", 120, 10, 2000, 330)
    ui.sliderInt("fb_tail_ms", "Settle before unfreezing (ms)", 100, 0, 2000, 330)
    ui.separator(6)

    ui.text("GROUND ITEM (method 3) - press the setup key, walk toward the "
        .. "dropped item, then press the trigger just before you reach it.", 470)
    ui.hotkey("setup_key", "Setup: drop the ground item, equip first slot", "F6", 300)
    ui.sliderInt("gi_ground_slot", "Slot thrown on the ground", 2, 0, 10, 330)
    ui.keyCombo("drop_key", "Drop key", "Backspace", 300)
    ui.sliderInt("gi_gap_ms", "Gap between setup presses (ms)", 90, 10, 1000, 330)
    ui.sliderInt("gi_drift_ms", "Drift after freezing (ms)", 250, 0, 2000, 330)
    ui.sliderInt("gi_taps", "Taps while frozen", 2, 0, 8, 330)
    ui.sliderInt("gi_tail_ms", "Settle before unfreezing (ms)", 130, 0, 2000, 330)
    ui.checkbox("gi_final_drop", "Finish with equip + drop", true, 330)
    ui.separator(6)

    ui.text("LAG SWITCH - optional, layered on top of any method.", 470)
    ui.checkbox("use_lag", "Use lag switch", false, 330)
    ui.checkbox("lag_fake", "Fake lag (delay) instead of hard block", false, 330)
    ui.sliderInt("lag_delay_ms", "Fake-lag delay (ms)", 150, 10, 1000, 330)
    ui.checkbox("lag_outbound", "Affect outbound", true, 330)
    ui.checkbox("lag_inbound", "Affect inbound", false, 330)
    ui.checkbox("lag_prevent_dc", "Disconnect prevention", true, 330)
    ui.separator(6)

    ui.dynamicTextbox("log", "Run log", "Not run yet", 470, 260)
end

--------------------------------------------------------------------------------
-- config
--------------------------------------------------------------------------------

local FREEZE_HARD_CAP_MS = 4000

local function buildConfig()
    local slots, bad = parseSlots(settings.slots or "1")

    return {
        method   = settings.method or METHODS[1],
        order    = settings.order or ORDERS[1],
        slots    = slots,
        badSlots = bad,

        trigger     = settings.trigger or "F5",
        setupHotkey = settings.setup_key or "F6",

        pairs      = math.max(1, math.floor(num(settings.pairs_per_cycle, 2))),
        tapHold    = num(settings.tap_hold_ms, 0),
        cycleDelay = num(settings.cycle_delay_ms, 0),
        burstLen   = math.max(1, math.floor(num(settings.burst_len, 6))),
        maxRunS    = num(settings.max_run_s, 30),

        fbDrift = num(settings.fb_drift_ms, 250),
        fbBurst = num(settings.fb_burst_ms, 120),
        fbTail  = num(settings.fb_tail_ms, 100),

        giGroundKey = slotToKey(num(settings.gi_ground_slot, 2)) or "2",
        dropKey     = (settings.drop_key ~= nil and settings.drop_key ~= "")
                      and settings.drop_key or "Backspace",
        giGap       = num(settings.gi_gap_ms, 90),
        giDrift     = num(settings.gi_drift_ms, 250),
        giTaps      = math.floor(num(settings.gi_taps, 2)),
        giTail      = num(settings.gi_tail_ms, 130),
        giFinalDrop = settings.gi_final_drop ~= false,

        useLag       = settings.use_lag == true,
        lagFake      = settings.lag_fake == true,
        lagDelayMs   = num(settings.lag_delay_ms, 150),
        lagOutbound  = settings.lag_outbound ~= false,
        lagInbound   = settings.lag_inbound == true,
        lagPreventDc = settings.lag_prevent_dc ~= false,
    }
end

local function slotsLabel(cfg)
    return table.concat(cfg.slots, ",")
end

--------------------------------------------------------------------------------
-- lag switch
--------------------------------------------------------------------------------

local function engageLag(cfg)
    lagSwitch(true, {
        fakeLag            = cfg.lagFake,
        fakeLagDelayMs     = cfg.lagDelayMs,
        fakeLagInbound     = cfg.lagFake and cfg.lagInbound,
        fakeLagOutbound    = cfg.lagFake and cfg.lagOutbound,
        hardBlockInbound   = (not cfg.lagFake) and cfg.lagInbound,
        hardBlockOutbound  = (not cfg.lagFake) and cfg.lagOutbound,
        preventDisconnect  = cfg.lagPreventDc,
        targetMode         = "roblox",
        useUdp             = true,
        useTcp             = false,
        autoUnblock        = true,
        maxDurationSeconds = 10,
    })
    laggedCfg = true
    lagging   = true
end

local function releaseLag()
    if lagging then
        lagSwitch(false)
        lagging = false
    end
end

--------------------------------------------------------------------------------
-- the churn
--
-- One pass = cfg.pairs equip/unequip cycles on one slot, matching the shipped
-- macro's two-cycles-per-tick. Returns the number of cycles emitted.
--------------------------------------------------------------------------------

local function churnSlot(cfg, key)
    for _ = 1, cfg.pairs do
        cycleKey(key, cfg.tapHold)
    end
    return cfg.pairs
end

-- Advances one "pass" over the configured slots according to order mode.
-- rr is the round-robin cursor, carried by the caller.
local function churnPass(cfg, rr)
    local n = 0
    if #cfg.slots == 1 then
        n = churnSlot(cfg, cfg.slots[1])
    elseif cfg.order == "Round robin" then
        n = churnSlot(cfg, cfg.slots[rr])
        rr = rr % #cfg.slots + 1
    elseif cfg.order == "Burst per slot" then
        for _, key in ipairs(cfg.slots) do
            for _ = 1, cfg.burstLen do
                n = n + churnSlot(cfg, key)
            end
            checkpoint()
            if isCancelled() then break end
        end
    else -- Interleave
        for _, key in ipairs(cfg.slots) do
            n = n + churnSlot(cfg, key)
        end
    end
    return n, rr
end

--------------------------------------------------------------------------------
-- method 1: the shipped loop, hold-to-run
--------------------------------------------------------------------------------

local function runLoop(cfg)
    resetLog()
    step("LOOP  slots=%s  order=%s  pairs=%d  hold=%dms  delay=%dms",
        slotsLabel(cfg), cfg.order, cfg.pairs, cfg.tapHold, cfg.cycleDelay)
    step("Hold the trigger. Release to stop.")

    if cfg.useLag then
        engageLag(cfg)
        step("lag switch ON")
    end

    -- Zero-delay churn is the point of this method, so the log must not run
    -- inside it - a setDynamicText per pass would dominate the loop.
    logDefer = true

    local cycles, passes = 0, 0
    local rr = 1
    local t0 = nowMicros()
    local limitUs = (cfg.maxRunS > 0) and (cfg.maxRunS * 1000000) or nil

    while input.isPressed(cfg.trigger) and not isCancelled() do
        local n
        n, rr = churnPass(cfg, rr)
        cycles  = cycles + n
        passes  = passes + 1

        if cfg.cycleDelay > 0 then
            sleep(cfg.cycleDelay)
        else
            -- A script that never yields is killed by the watchdog.
            -- checkpoint() satisfies it without adding a delay.
            checkpoint()
        end

        if limitUs and (nowMicros() - t0) > limitUs then
            logDefer = false
            step("safety stop: held longer than %ds", cfg.maxRunS)
            logDefer = true
            break
        end
    end

    logDefer = false
    local elapsed = (nowMicros() - t0) / 1000.0
    releaseLag()
    if cfg.useLag then step("lag switch OFF") end

    step("released after %.0fms - %d passes, %d equip/unequip cycles",
        elapsed, passes, cycles)
    if elapsed > 0 then
        step("rate: %.0f cycles/sec", cycles / (elapsed / 1000.0))
    end
    flushLog()
end

--------------------------------------------------------------------------------
-- method 2: churn queued into a suspended client
--------------------------------------------------------------------------------

local function runFreezeBurst(cfg)
    resetLog()
    local planned = cfg.fbDrift + cfg.fbBurst + cfg.fbTail
    step("FREEZE BURST  slots=%s  window=%dms", slotsLabel(cfg), planned)

    if cfg.useLag then
        engageLag(cfg)
        step("lag switch ON")
    end

    logDefer = true
    setFrozen(true)
    step("FROZEN")

    if cfg.fbDrift > 0 then sleep(cfg.fbDrift) end

    local cycles, rr = 0, 1
    local deadline = nowMicros() + cfg.fbBurst * 1000
    while nowMicros() < deadline and not isCancelled() do
        local n
        n, rr = churnPass(cfg, rr)
        cycles = cycles + n
        if cfg.cycleDelay > 0 then sleep(cfg.cycleDelay) else checkpoint() end
    end
    step("queued %d cycles into the frozen pump", cycles)

    if cfg.fbTail > 0 then sleep(cfg.fbTail) end

    setFrozen(false)
    step("UNFROZEN - queue flushes now")
    logDefer = false
    flushLog()

    releaseLag()
    if cfg.useLag then step("lag switch OFF") end
    step("BURST COMPLETE - %d cycles", cycles)
    flushLog()
end

--------------------------------------------------------------------------------
-- method 3: the 2023 ground-item procedure
--------------------------------------------------------------------------------

local function runGroundSetup(cfg)
    resetLog()
    local first = cfg.slots[1]
    step("SETUP  equip %s -> %s (drop) -> equip %s",
        cfg.giGroundKey, cfg.dropKey, first)

    tapKey(cfg.giGroundKey, 18, cfg.giGap)
    step("equipped ground slot (%s)", cfg.giGroundKey)

    tapKey(cfg.dropKey, 18, cfg.giGap)
    step("pressed drop (%s)", cfg.dropKey)

    tapKey(first, 18, cfg.giGap)
    step("equipped slot %s", first)

    step("SETUP DONE - walk toward the dropped item, then press the trigger")
    step("just before you reach it.")
    flushLog()
end

local function runGroundItem(cfg)
    resetLog()
    local planned = cfg.giDrift + cfg.giTail + cfg.giTaps * 36
    step("GROUND ITEM  slots=%s  window=~%dms", slotsLabel(cfg), planned)

    if cfg.useLag then
        engageLag(cfg)
        step("lag switch ON")
    end

    logDefer = true
    setFrozen(true)
    step("FROZEN")

    if cfg.giDrift > 0 then sleep(cfg.giDrift) end

    -- Each configured slot gets its taps queued in the same frozen window, so
    -- they all flush together.
    for _, key in ipairs(cfg.slots) do
        for _ = 1, cfg.giTaps do
            tapKey(key, 18, 18)
        end
        step("queued %d tap(s) for slot %s", cfg.giTaps, key)
    end

    if cfg.giTail > 0 then sleep(cfg.giTail) end

    setFrozen(false)
    step("UNFROZEN - queue flushes now")
    logDefer = false
    flushLog()

    releaseLag()
    if cfg.useLag then step("lag switch OFF") end

    if cfg.giFinalDrop then
        sleep(60)
        for _, key in ipairs(cfg.slots) do
            tapKey(key, 18, cfg.giGap)
            tapKey(cfg.dropKey, 18, cfg.giGap)
            step("equipped %s and dropped", key)
        end
    end

    step("SEQUENCE COMPLETE")
    flushLog()
end

--------------------------------------------------------------------------------
-- diagnostics
--------------------------------------------------------------------------------

local FREEZE_TEST_MS = 700

local function selfTest(cfg)
    resetLog()
    step("SELF-TEST")

    local platform = tostring(getPlatform())
    step("platform      : %s", platform)
    step("SMU version   : %s", tostring(getSMUVersion()))
    step("script hotkey : %s", tostring(getScriptHotkey()))
    step("method        : %s", cfg.method)
    step("slots parsed  : [%s]  (%d)", slotsLabel(cfg), #cfg.slots)
    if #cfg.badSlots > 0 then
        step("  ^ ignored unparseable entries: %s", table.concat(cfg.badSlots, " "))
    end
    if #cfg.slots == 0 then
        step("  ^ NO VALID SLOTS. Put digits in the Slots box, e.g. 1,2,3")
    end

    -- What is the built-in Item Desync macro set to? If that one works for
    -- you and this script does not, the difference is in here.
    step("--- built-in Item Desync macro ---")
    step("desync_slot     : %s", tostring(saved("desync_slot")))
    step("ItemDesyncSlot  : %s", tostring(saved("ItemDesyncSlot")))
    step("vk_f5 (trigger) : %s", tostring(saved("vk_f5")))
    step("--- built-in Item Clip macro ---")
    step("clip_slot       : %s", tostring(saved("clip_slot")))
    step("clip_delay      : %s ms", tostring(saved("clip_delay")))
    step("isitemclipswitch: %s", tostring(saved("isitemclipswitch")))

    -- process targeting: only matters for the freeze-based methods
    local proc = saved("settingsBuffer")
    step("target process: %s", tostring(proc))
    if proc == nil or proc == "" then
        step("  ^ EMPTY. Freeze cannot target anything. Harmless for the")
        step("    Loop method, fatal for Freeze burst and Ground item.")
    end

    local outside = saved("freezeoutsideroblox")
    if outside ~= nil then
        step("freeze outside roblox : %s", tostring(outside))
    end

    local cap = num(saved("maxfreezetime"), nil)
    step("maxfreezetime : %s s", tostring(cap))
    local planned = cfg.fbDrift + cfg.fbBurst + cfg.fbTail
    step("freeze-burst window: %dms", planned)
    if cap ~= nil and cap > 0 and planned > cap * 1000 then
        step("  ^ PROBLEM: auto-unfreeze at %.0fms cuts this short.", cap * 1000)
    end

    -- does the freeze land? A live client writes log lines continuously; a
    -- suspended one writes none.
    step("freeze test   : suspending %dms...", FREEZE_TEST_MS)
    local okDrain, drained = pcall(readRobloxLog, false)
    if okDrain and type(drained) == "table" and drained.available == false then
        step("  roblox log unavailable (%s) - check is inconclusive",
            tostring(drained.state))
    end

    local t0 = nowMicros()
    local okOn, errOn = pcall(freeze, true)
    local onMs = (nowMicros() - t0) / 1000.0
    frozen = okOn and true or false
    if not okOn then
        step("  freeze(true) ERRORED: %s", tostring(errOn))
    else
        step("  freeze(true) returned in %.2fms", onMs)
    end

    sleep(FREEZE_TEST_MS)

    local during = 0
    local okMid, mid = pcall(readRobloxLog, false)
    if okMid and type(mid) == "table" and type(mid.lines) == "table" then
        during = #mid.lines
    end

    local okOff, errOff = pcall(freeze, false)
    frozen = false
    if not okOff then step("  freeze(false) ERRORED: %s", tostring(errOff)) end

    step("  log lines while suspended: %d", during)
    if okOn and during == 0 then
        step("  ^ consistent with a real freeze (an idle client also logs 0)")
    elseif during > 0 then
        step("  ^ client kept logging - freeze is likely NOT applying")
    end

    -- churn rate: how fast can we actually emit cycles?
    local key = cfg.slots[1] or "1"
    local n, tc0 = 0, nowMicros()
    while (nowMicros() - tc0) < 200000 and not isCancelled() do
        cycleKey(key, cfg.tapHold)
        n = n + 1
        checkpoint()
    end
    local rate = n / ((nowMicros() - tc0) / 1000000.0)
    step("churn rate    : %.0f equip/unequip cycles/sec on slot %s", rate, key)
    if rate < 100 then
        step("  ^ low. The shipped macro relies on going flat out; if your")
        step("    input backend is this slow the desync may never build.")
    end

    local okSt, st = pcall(getLagSwitchStatus)
    if okSt and type(st) == "table" then
        step("lagswitch     : available=%s active=%s mode=%s",
            tostring(st.available), tostring(st.active), tostring(st.targetMode))
        if st.available ~= true then
            step("  ^ unavailable: %s", tostring(st.unsupportedReason))
        end
    else
        step("lagswitch     : no status returned")
    end

    step("SELF-TEST DONE")
    flushLog()
end

--------------------------------------------------------------------------------
-- main
--------------------------------------------------------------------------------

function onExecute()
    local cfg = buildConfig()

    if settings.selftest == true then
        selfTest(cfg)
        return
    end

    if #cfg.slots == 0 then
        resetLog()
        step("REFUSED: no valid slots parsed from \"%s\".",
            tostring(settings.slots))
        step("Put hotbar digits in the Slots box, e.g. 1,2,3")
        flushLog()
        return
    end

    local usesFreeze = (cfg.method ~= METHODS[1])
    local planned = (cfg.method == METHODS[2])
        and (cfg.fbDrift + cfg.fbBurst + cfg.fbTail)
        or  (cfg.giDrift + cfg.giTail + cfg.giTaps * 36)

    if usesFreeze and planned > FREEZE_HARD_CAP_MS then
        resetLog()
        step("REFUSED: frozen window would be %dms (cap %dms).",
            planned, FREEZE_HARD_CAP_MS)
        flushLog()
        return
    end

    input.setHotkeyMode("loose")

    resetLog()
    step("Armed - %s", cfg.method)
    step("  slots  : %s   (%s)", slotsLabel(cfg), cfg.order)
    if cfg.method == METHODS[1] then
        step("  %s : hold to churn, release to stop", cfg.trigger)
    elseif cfg.method == METHODS[2] then
        step("  %s : one burst per press (~%dms frozen)", cfg.trigger, planned)
    else
        step("  %s : setup (drop + equip)", cfg.setupHotkey)
        step("  %s : freeze, tap, unfreeze, drop", cfg.trigger)
    end
    if #cfg.badSlots > 0 then
        step("  ignored: %s", table.concat(cfg.badSlots, " "))
    end

    local cap = num(saved("maxfreezetime"), nil)
    if usesFreeze and cap ~= nil and cap > 0 and planned > cap * 1000 then
        step("WARNING: auto-unfreeze at %.0fms will cut this short.", cap * 1000)
    end
    flushLog()

    local prevFire, prevSetup = false, false

    while not isCancelled() do
        local fire  = input.isPressed(cfg.trigger)
        local setup = input.isPressed(cfg.setupHotkey)

        if fire and not prevFire then
            if cfg.method == METHODS[1] then
                runLoop(cfg)
                -- runLoop exits either because the trigger was released (this
                -- is then a no-op) or because the safety limit tripped while
                -- it is still held - in which case we must not re-arm until
                -- it is let go, or it just restarts immediately.
                waitRelease(cfg.trigger)
            elseif cfg.method == METHODS[2] then
                runFreezeBurst(cfg)
                waitRelease(cfg.trigger)
            else
                runGroundItem(cfg)
                waitRelease(cfg.trigger)
            end
            prevFire, prevSetup = false, false
        elseif setup and not prevSetup and cfg.method == METHODS[3] then
            runGroundSetup(cfg)
            waitRelease(cfg.setupHotkey)
            prevFire, prevSetup = false, false
        else
            prevFire, prevSetup = fire, setup
            if sleepUntilCancelled(4) then break end
        end
    end
end

--------------------------------------------------------------------------------
-- cleanup - releases only, no new actions
--------------------------------------------------------------------------------

function onCleanup(reason)
    releaseAllKeys()

    if frozen then
        pcall(freeze, false)   -- freeze(true) is forbidden here; false is fine
        frozen = false
    end
    if lagging then
        pcall(lagSwitch, false)
        lagging = false
    end
    if laggedCfg then
        pcall(clearLagSwitchConfig)
        laggedCfg = false
    end

    logLines[#logLines + 1] = "-- stopped (" .. tostring(reason) .. ")"
    pcall(flushLog)
end
