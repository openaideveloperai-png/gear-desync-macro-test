-- @name: Gear Desync v3 (freeze)
-- @desc: Item/gear desync for Roblox. Implements the real drop-walk-freeze-double-tap procedure, not just slot spam. Two-phase: a setup hotkey drops the slot-B item and equips slot A, then a trigger hotkey freezes the client, queues the unequip/equip pair into the suspended message pump, unfreezes and drops. Includes a self-test that checks the things which actually break it.
-- @author: you
-- @version: 3.0
-- @keybind: F9
-- @memoryLimitMB: 32
--
-- ============================================================================
-- WHAT WAS ACTUALLY WRONG WITH v1 AND v2
--
--   v1 spammed the slot key. That does nothing on its own.
--
--   v2 added the freeze and assumed that was "the missing half". It was not.
--   v2 still never dropped an item, never used a second inventory slot, and
--   never did the final equip+drop. The documented glitch desyncs an equipped
--   handle against an item lying on the ground - with nothing on the ground
--   there is nothing to desync against, so v2 could not work either, no
--   matter how well its freeze landed.
--
--   v2 also had a self-test that could not fail. It did:
--       t0 = now(); freeze(true); sleep(400); freeze(false)
--       if (now() - t0) < 350 then "freeze not applying" end
--   sleep() runs on the macro thread, not the frozen target, so that elapsed
--   time is ~400ms whether or not the freeze did anything at all. It measured
--   its own sleep. See selfTest() below for a check that can actually fail.
--
-- THE PROCEDURE (Roblox Glitches Wiki - "Item Desync", found 2023)
--   1. Items in the first 10 hotbar slots. Two are used: A and B.
--   2. Press B, then the drop key -> the slot-B item lands on the ground.
--   3. Press A -> equip the slot-A item.
--   4. Walk toward the dropped item; freeze just before you reach it.
--   5. Press A twice.
--   6. Unfreeze, equip slot A, drop it.
--
--   Steps 2-3 are the SETUP hotkey. Step 4's freeze through step 6 are the
--   TRIGGER hotkey. Step 4's walking is yours - the macro cannot know when
--   you are "just before" the item, which is why the freeze is on a hotkey
--   you press at that moment rather than on a timer.
--
-- THE MECHANISM
--   Slot A is already equipped when you trigger. freeze() suspends the Roblox
--   process, so Roblox stops pumping its window message queue while Windows
--   keeps posting to it - synthetic keypresses stack up unconsumed. The
--   server meanwhile keeps simulating your character with no client updates.
--   On unfreeze the queue drains in one or two frames: the two slot-A taps
--   become unequip-then-equip inside a single frame, so the Handle weld is
--   destroyed and recreated before any position update replicates. The
--   collider is left at a stale CFrame while the rendered handle follows you.
--
-- FIRST RUN - DO THIS
--   Tick "Self-test only" and fire it once. It reports the target process
--   name, the auto-unfreeze cap, platform support, lag-switch availability,
--   and whether the client actually stopped logging while suspended. If the
--   freeze is not landing, no timing slider below can help you - the fix is
--   the Roblox process name in SMU's main settings.
--
-- THEN TUNE
--   Drift is the main dial. Start 250ms and walk it up. Too short and no
--   offset builds; too long and the server rubber-bands you back, which eats
--   the desync. Keep the whole frozen window under SMU's maxfreezetime or
--   SMU will auto-unfreeze underneath you mid-sequence.
-- ============================================================================

--------------------------------------------------------------------------------
-- state that onCleanup has to be able to reach
--------------------------------------------------------------------------------

local heldKeys = {}
local frozen   = false
local lagging  = false
local laggedCfg = false

--------------------------------------------------------------------------------
-- small helpers
--------------------------------------------------------------------------------

local SLOT_KEYS = { "1", "2", "3", "4", "5", "6", "7", "8", "9", "0" }

local function slotKey(i)
    return SLOT_KEYS[i] or "1"
end

local function num(v, default)
    local n = tonumber(v)
    if n == nil then return default end
    return n
end

-- getSavedValue() returns nil for keys this build does not expose, and can
-- raise on an unknown key. Never let a diagnostic read kill the run.
local function saved(name)
    local ok, v = pcall(getSavedValue, name)
    if ok then return v end
    return nil
end

--------------------------------------------------------------------------------
-- logging
--
-- ui.setDynamicText + table.concat on every line is fine when idle, but it is
-- unbounded work inside the frozen window, where it lands between the queued
-- taps and smears the timing we are trying to control. During the freeze we
-- buffer only and flush once we are back out.
--------------------------------------------------------------------------------

local logLines  = {}
local logT0     = 0
local logDefer  = false

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

local function tapKey(key, holdMs, gapMs)
    holdKey(key)
    heldKeys[key] = true
    if holdMs > 0 then sleep(holdMs) end
    releaseKey(key)
    heldKeys[key] = nil
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

function onSettings()
    ui.text("Item/gear desync. Two hotkeys: SETUP drops the slot-B item and "
        .. "equips slot A, then you walk toward the dropped item and press "
        .. "TRIGGER just before you reach it. Run the self-test first.", 470)
    ui.separator(6)

    ui.checkbox("selftest", "Self-test only (diagnose, do not glitch)", false, 330)
    ui.separator(6)

    ui.text("HOTKEYS", 470)
    ui.hotkey("setup_key", "SETUP  - drop slot B, equip slot A", "F6", 300)
    ui.hotkey("trigger", "TRIGGER - freeze, double-tap, unfreeze, drop", "F5", 300)
    ui.separator(6)

    ui.text("SLOTS - A is the item you desync, B is the one thrown on the "
        .. "ground for A to desync against. Both must be in the first 10 "
        .. "hotbar slots and both must be droppable.", 470)
    ui.sliderInt("slot_a", "Slot A (the desynced item)", 1, 1, 10, 330)
    ui.sliderInt("slot_b", "Slot B (dropped on the ground)", 2, 1, 10, 330)
    ui.keyCombo("drop_key", "Drop key", "Backspace", 300)
    ui.sliderInt("setup_gap_ms", "Gap between setup presses (ms)", 90, 10, 1000, 330)
    ui.separator(6)

    ui.text("METHOD - freeze is the real one. The lag switch is a fallback "
        .. "for setups where freeze is blocked or unreliable.", 470)
    ui.checkbox("use_freeze", "Use process freeze", true, 330)
    ui.checkbox("use_lag", "Use lag switch", false, 330)
    ui.separator(6)

    ui.text("SEQUENCE - slot A is already equipped when you trigger, so the "
        .. "two frozen taps are unequip then equip landing in one frame.", 470)
    ui.sliderInt("pre_taps", "Taps before freezing (0 = already equipped)", 0, 0, 4, 330)
    ui.sliderInt("drift_ms", "Drift: wait after freezing, before taps (ms)", 250, 0, 2000, 330)
    ui.sliderInt("frozen_taps", "Taps while frozen (the method uses 2)", 2, 0, 8, 330)
    ui.sliderInt("tail_ms", "Wait after taps, before unfreezing (ms)", 130, 0, 2000, 330)
    ui.sliderInt("post_delay_ms", "Settle after unfreezing (ms)", 60, 0, 2000, 330)
    ui.checkbox("final_drop", "Finish with equip slot A + drop (step 6)", true, 330)
    ui.sliderInt("final_gap_ms", "Gap between the final equip and drop (ms)", 90, 10, 1000, 330)
    ui.separator(6)

    ui.sliderInt("tap_hold_ms", "Key hold per tap (ms)", 18, 1, 100, 330)
    ui.sliderInt("tap_gap_ms", "Gap between taps (ms)", 18, 0, 200, 330)
    ui.separator(6)

    ui.text("SUSTAIN - the v1 behaviour. Cannot create a desync on its own, "
        .. "but can widen one the freeze has already made.", 470)
    ui.sliderInt("sustain_ms", "Spam slot A after the sequence (ms, 0 = off)", 0, 0, 5000, 330)
    ui.sliderInt("sustain_period_ms", "Sustain half-cycle (ms)", 17, 4, 100, 330)
    ui.separator(6)

    ui.text("LAG SWITCH (only used if ticked above)", 470)
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
    local cfg = {
        keyA        = slotKey(num(settings.slot_a, 1)),
        keyB        = slotKey(num(settings.slot_b, 2)),
        dropKey     = settings.drop_key or "Backspace",
        setupGapMs  = num(settings.setup_gap_ms, 90),

        trigger     = settings.trigger or "F5",
        setupHotkey = settings.setup_key or "F6",

        useFreeze   = settings.use_freeze ~= false,
        useLag      = settings.use_lag == true,

        preTaps     = num(settings.pre_taps, 0),
        driftMs     = num(settings.drift_ms, 250),
        frozenTaps  = num(settings.frozen_taps, 2),
        tailMs      = num(settings.tail_ms, 130),
        postDelayMs = num(settings.post_delay_ms, 60),
        finalDrop   = settings.final_drop ~= false,
        finalGapMs  = num(settings.final_gap_ms, 90),

        tapHold     = num(settings.tap_hold_ms, 18),
        tapGap      = num(settings.tap_gap_ms, 18),

        sustainMs     = num(settings.sustain_ms, 0),
        sustainPeriod = num(settings.sustain_period_ms, 17),

        lagFake      = settings.lag_fake == true,
        lagDelayMs   = num(settings.lag_delay_ms, 150),
        lagOutbound  = settings.lag_outbound ~= false,
        lagInbound   = settings.lag_inbound == true,
        lagPreventDc = settings.lag_prevent_dc ~= false,
    }

    if cfg.dropKey == "" then cfg.dropKey = "Backspace" end
    return cfg
end

-- Everything that happens between freeze(true) and freeze(false).
local function plannedFreezeMs(cfg)
    return cfg.driftMs
        + cfg.tailMs
        + cfg.frozenTaps * (cfg.tapHold + cfg.tapGap)
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
    step("slot A / B    : %s / %s    drop key: %s", cfg.keyA, cfg.keyB, cfg.dropKey)
    if cfg.keyA == cfg.keyB then
        step("  ^ slot A and slot B are the same. They must differ.")
    end

    -- 1. process targeting. This is the single most common reason freeze
    --    silently does nothing.
    local proc = saved("settingsBuffer")
    step("target process: %s", tostring(proc))
    if proc == nil or proc == "" then
        step("  ^ EMPTY. Set the Roblox executable name in SMU's main")
        step("    settings. Freeze cannot target anything until it matches")
        step("    the client you are actually running.")
    end

    local outside = saved("freezeoutsideroblox")
    if outside ~= nil then
        step("freeze outside roblox : %s", tostring(outside))
        if outside == false then
            step("  ^ freeze only applies while Roblox is focused.")
        end
    end
    local takeAll = saved("takeallprocessids")
    if takeAll ~= nil then
        step("all process ids       : %s (multi-instance)", tostring(takeAll))
    end

    -- 2. auto-unfreeze cap vs the window this config actually needs
    local planned = plannedFreezeMs(cfg)
    local cap     = num(saved("maxfreezetime"), nil)
    local override = num(saved("maxfreezeoverride"), nil)
    step("planned freeze: %dms", planned)
    step("maxfreezetime : %s s", tostring(cap))
    if override ~= nil then
        step("refreeze delay: %s ms", tostring(override))
    end
    if cap ~= nil and cap > 0 and planned > cap * 1000 then
        step("  ^ PROBLEM: SMU auto-unfreezes at %.0fms, before this", cap * 1000)
        step("    sequence finishes. It will unfreeze underneath you mid-run.")
        step("    Raise maxfreezetime or lower drift/tail.")
    end

    -- 3. does the freeze land? Roblox writes to its log continuously while
    --    running; a suspended process writes nothing. This can genuinely
    --    fail, unlike v2's version which just measured its own sleep().
    step("freeze test   : suspending %dms...", FREEZE_TEST_MS)

    local baseline = 0
    local okDrain, drained = pcall(readRobloxLog, false)
    if okDrain and type(drained) == "table" then
        if drained.available == false then
            step("  roblox log unavailable (%s) - log check will be", tostring(drained.state))
            step("  inconclusive; watch the screen instead.")
        end
        if type(drained.lines) == "table" then baseline = #drained.lines end
    end
    step("  drained %d pending log line(s)", baseline)

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

    local t1 = nowMicros()
    local okOff, errOff = pcall(freeze, false)
    local offMs = (nowMicros() - t1) / 1000.0
    frozen = false

    if not okOff then
        step("  freeze(false) ERRORED: %s", tostring(errOff))
    else
        step("  freeze(false) returned in %.2fms", offMs)
    end

    step("  log lines written while suspended: %d", during)
    if okOn and during == 0 then
        step("  ^ consistent with a real freeze. An idle client can also")
        step("    log nothing, so confirm Roblox visibly stuttered.")
    elseif during > 0 then
        step("  ^ client kept logging while suspended - the freeze is very")
        step("    likely NOT applying. Check the target process name.")
    end

    -- 4. lag switch
    local okSt, st = pcall(getLagSwitchStatus)
    if not okSt or st == nil then
        step("lagswitch     : no status returned")
    elseif type(st) ~= "table" then
        step("lagswitch     : %s", tostring(st))
    else
        step("lagswitch     : available=%s active=%s mode=%s",
            tostring(st.available),
            tostring(st.active),
            tostring(st.targetMode))
        if st.available ~= true then
            step("  ^ unavailable: %s", tostring(st.unsupportedReason))
            if platform == "macos" then
                step("    (the lag-switch backend does not exist on macOS)")
            end
        end
    end

    step("SELF-TEST DONE")
    step("If Roblox did not visibly freeze, fix that before touching sliders.")
    flushLog()
end

--------------------------------------------------------------------------------
-- phase 1: setup - drop the slot B item, equip slot A  (wiki steps 2-3)
--------------------------------------------------------------------------------

local function runSetup(cfg)
    resetLog()
    step("SETUP  slotB=%s -> %s (drop), then equip slotA=%s",
        cfg.keyB, cfg.dropKey, cfg.keyA)

    tapKey(cfg.keyB, cfg.tapHold, cfg.tapGap)
    step("equipped slot B (%s)", cfg.keyB)
    sleep(cfg.setupGapMs)

    tapKey(cfg.dropKey, cfg.tapHold, cfg.tapGap)
    step("pressed drop (%s)", cfg.dropKey)
    sleep(cfg.setupGapMs)

    tapKey(cfg.keyA, cfg.tapHold, cfg.tapGap)
    step("equipped slot A (%s)", cfg.keyA)

    step("SETUP DONE")
    step("Now walk toward the dropped item and press the TRIGGER hotkey")
    step("just before you reach it.")
    flushLog()
end

--------------------------------------------------------------------------------
-- phase 2: the desync  (wiki steps 4-6)
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
        -- belt and braces: if this script dies in a way that skips cleanup,
        -- the backend still drops the block on its own.
        autoUnblock        = true,
        maxDurationSeconds = 5,
    })
    laggedCfg = true
    lagging   = true
end

local function runDesync(cfg)
    resetLog()
    step("FIRE  slotA=%s freeze=%s lag=%s  (frozen window ~%dms)",
        cfg.keyA, tostring(cfg.useFreeze), tostring(cfg.useLag),
        plannedFreezeMs(cfg))

    -- optional re-equip, unfrozen
    for _ = 1, cfg.preTaps do
        tapKey(cfg.keyA, cfg.tapHold, cfg.tapGap)
    end
    if cfg.preTaps > 0 then step("pre-taps x%d done", cfg.preTaps) end

    -- engage
    if cfg.useLag then
        engageLag(cfg)
        step("lag switch ON")
    end

    if cfg.useFreeze then
        logDefer = true          -- buffer only; no UI work inside the window
        setFrozen(true)
        step("FROZEN")
    end

    -- drift: server keeps simulating, client is stopped
    if cfg.driftMs > 0 then sleep(cfg.driftMs) end

    -- queue unequip/equip into the suspended message pump
    for _ = 1, cfg.frozenTaps do
        tapKey(cfg.keyA, cfg.tapHold, cfg.tapGap)
    end
    step("queued %d tap(s) into the frozen pump", cfg.frozenTaps)

    if cfg.tailMs > 0 then sleep(cfg.tailMs) end

    -- release: the queued input all lands in one or two frames here
    if cfg.useFreeze then
        setFrozen(false)
        step("UNFROZEN - queue flushes now")
        logDefer = false
        flushLog()
    end

    if cfg.useLag then
        lagSwitch(false)
        lagging = false
        step("lag switch OFF")
    end

    -- settle
    if cfg.postDelayMs > 0 then sleep(cfg.postDelayMs) end

    -- step 6: equip slot A and drop it
    if cfg.finalDrop then
        tapKey(cfg.keyA, cfg.tapHold, cfg.tapGap)
        step("re-equipped slot A (%s)", cfg.keyA)
        sleep(cfg.finalGapMs)
        tapKey(cfg.dropKey, cfg.tapHold, cfg.tapGap)
        step("dropped (%s)", cfg.dropKey)
    end

    -- optional sustain
    if cfg.sustainMs > 0 then
        local deadline = nowMicros() + (cfg.sustainMs * 1000)
        local n = 0
        while nowMicros() < deadline and not isCancelled() do
            tapKey(cfg.keyA, cfg.sustainPeriod, cfg.sustainPeriod)
            n = n + 1
        end
        step("sustain: %d taps over %dms", n, cfg.sustainMs)
    end

    step("SEQUENCE COMPLETE")
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

    -- refuse configs that would suspend the client for an unreasonable time
    local planned = plannedFreezeMs(cfg)
    if cfg.useFreeze and planned > FREEZE_HARD_CAP_MS then
        resetLog()
        step("REFUSED: frozen window would be %dms (cap %dms)",
            planned, FREEZE_HARD_CAP_MS)
        step("Lower drift / tail / frozen taps.")
        flushLog()
        return
    end

    if cfg.keyA == cfg.keyB then
        resetLog()
        step("REFUSED: slot A and slot B are both '%s'.", cfg.keyA)
        step("They must be different slots - B is the item thrown on the")
        step("ground for A to desync against.")
        flushLog()
        return
    end

    input.setHotkeyMode("loose")

    resetLog()
    step("Armed.")
    step("  %s = SETUP   (drop slot %s, equip slot %s)",
        cfg.setupHotkey, cfg.keyB, cfg.keyA)
    step("  %s = TRIGGER (freeze %dms, tap x%d, unfreeze%s)",
        cfg.trigger, planned, cfg.frozenTaps,
        cfg.finalDrop and ", drop" or "")

    -- warn rather than refuse: the cap may be unreadable on some builds
    local cap = num(saved("maxfreezetime"), nil)
    if cfg.useFreeze and cap ~= nil and cap > 0 and planned > cap * 1000 then
        step("WARNING: SMU auto-unfreezes at %.0fms but this window is %dms.",
            cap * 1000, planned)
        step("It will unfreeze mid-sequence. Raise maxfreezetime.")
    end
    flushLog()

    local prevFire  = false
    local prevSetup = false

    while not isCancelled() do
        local fire  = input.isPressed(cfg.trigger)
        local setup = input.isPressed(cfg.setupHotkey)

        if fire and not prevFire then
            runDesync(cfg)
            waitRelease(cfg.trigger)
            prevFire, prevSetup = false, false
        elseif setup and not prevSetup then
            runSetup(cfg)
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
--
-- freeze(true) is forbidden in onCleanup; freeze(false) is permitted. Each
-- step is pcall'd so a failure in one cannot stop the unfreeze in the next.
--------------------------------------------------------------------------------

function onCleanup(reason)
    releaseAllKeys()

    if frozen then
        pcall(freeze, false)
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
