# Gear Desync v3 — SMU Lua macro

Item/gear desync for Roblox, written for [Spencer Macro Utilities](https://github.com/Spencer0187/Spencer-Macro-Utilities)
(`docs/lua_macro_scripting.md`).

Drop `gear_desync.lua` into your SMU scripts folder, open its settings, tick
**Self-test only**, and fire it once before anything else.

---

## Why v1 and v2 did nothing

**v1** spammed the slot key. That does nothing on its own — correctly identified
in the v2 header.

**v2** added the freeze and assumed that was the missing half. It wasn't. Running
both through a mock of the SMU API, here is what each actually emits on a trigger
press:

```
v2:  1  [FREEZE]  1  1  [UNFREEZE]
v3:     [FREEZE]  1  1  [UNFREEZE]  1  Backspace
```

v2 never presses the drop key, never touches a second inventory slot, and never
does the final equip+drop. The documented glitch desyncs an **equipped handle
against an item lying on the ground** — with nothing on the ground there is
nothing to desync against, so v2 could not work regardless of how well its
freeze landed.

### The procedure it was missing

From the [Roblox Glitches Wiki — Item Desync](https://roblox-glitches.fandom.com/wiki/Item_Desync)
(discovered 2023 by Superglitch11):

1. Put items in the first 10 hotbar slots. Two are used — call them A and B.
2. Press **B**, then **Backspace** → the slot-B item lands on the ground.
3. Press **A** → equip the slot-A item.
4. Walk toward the dropped item; **freeze just before you reach it**.
5. Press **A** twice.
6. Unfreeze, equip slot A, drop it.

Steps 2–3 are the **SETUP** hotkey (default `F6`). Steps 4–6 are the **TRIGGER**
hotkey (default `F5`). The walking in step 4 is yours — the macro can't know when
you're "just before" the item, which is why the freeze fires on a hotkey you press
at that moment instead of on a timer.

### v2's self-test could not fail

```lua
t0 = nowMicros(); freeze(true); sleep(400); freeze(false)
if (nowMicros() - t0) < 350 then  -- "freeze is probably not applying"
```

`sleep()` runs on the macro thread, not on the suspended target, so that elapsed
time is ~400 ms whether or not the freeze did anything at all. It measured its own
`sleep`. The v3 self-test drains the Roblox log, suspends, and re-reads: a live
client writes log lines continuously, a suspended one writes none. That check can
actually fail.

---

## The mechanism

Slot A is already equipped when you trigger. `freeze()` suspends the Roblox
process, so Roblox stops pumping its window message queue while Windows keeps
posting to it — synthetic keypresses stack up unconsumed. Meanwhile the server
keeps simulating your character with no client updates arriving.

On unfreeze the queue drains in one or two frames: the two slot-A taps become
unequip-then-equip **inside a single frame**, so the Handle weld is destroyed and
recreated before any position update replicates. The collider is left at a stale
CFrame while the rendered handle follows you.

---

## Tuning

Run the self-test first. If the freeze isn't landing, **no slider here helps** —
the fix is the Roblox process name in SMU's main settings.

| Setting | Default | Notes |
| --- | --- | --- |
| Drift | 250 ms | The main dial. Start here and walk it up. Too short → no offset builds. Too long → the server rubber-bands you back and eats the desync. |
| Frozen taps | 2 | The method uses 2. Slot A is already equipped, so these are unequip → equip. |
| Tail | 130 ms | Lets the queued input settle before the client resumes. |
| Pre-taps | 0 | Slot A is already equipped after SETUP. Only raise this if you trigger without running SETUP. |
| Sustain | 0 (off) | The v1 behaviour. Can't create a desync, can widen one the freeze already made. |

**Keep the whole frozen window under SMU's `maxfreezetime`.** SMU auto-unfreezes at
that cap; if your window is longer it will unfreeze underneath you mid-sequence and
the run silently does nothing. The self-test prints your planned window next to the
cap and flags the conflict, and `onExecute` warns at arm time. There's also a hard
4000 ms refusal.

---

## What the self-test checks

- Target process name (`settingsBuffer`) — **the most common reason freeze silently does nothing**
- `maxfreezetime` / `maxfreezeoverride` auto-unfreeze cap vs. this config's planned window
- `freezeoutsideroblox`, `takeallprocessids`
- Platform (`freeze` uses stop/continue signals on macOS; the lag-switch backend doesn't exist there)
- Whether `freeze(true)` raises, and how long each call takes
- Whether the client kept writing log lines while suspended
- Lag-switch `available` / `active` / `targetMode` / `unsupportedReason`

---

## API bugs fixed

Verified against `docs/lua_macro_scripting.md`:

- **`onCleanup` was not fault-tolerant.** A raising `releaseKey` would skip the
  unfreeze and leave the client suspended. Each teardown step is now `pcall`'d
  independently. (`freeze(true)` is forbidden in cleanup; `freeze(false)` is allowed —
  v3 only ever calls the latter.)
- **Only one held key was tracked** (`heldKey`), so a mid-sequence abort could leak
  a key. Now a `heldKeys` set, released in full.
- **UI writes inside the frozen window.** `step()` called `ui.setDynamicText` +
  `table.concat` on every line, landing between the queued taps and smearing the
  timing being controlled. v3 buffers during the freeze and flushes after —
  a regression test asserts zero UI writes while suspended.
- **`getSavedValue` unguarded** — it returns `nil` for keys a build doesn't expose
  and can raise on an unknown key. Now wrapped.
- **Lag-switch teardown incomplete** — `clearLagSwitchConfig()` was never called,
  leaving this script's config override owned after exit. Added, plus `autoUnblock`
  and `maxDurationSeconds` so the backend self-releases if cleanup is ever skipped.
- **`getLagSwitchStatus()` fields assumed** — the doc names the fields but doesn't
  pin their types, so access is now defensive against a non-table return.
- **Fragile `and/or` ternaries** for the hard-block flags, replaced with plain
  boolean `and`.
- Settings are coerced with `tonumber` rather than trusted to be numeric.

Signatures confirmed correct in v2 and kept: `ui.sliderInt(id, label, default, min, max, width)`
argument order, `ui.hotkey`/`ui.dynamicTextbox` shapes, `getSavedValue("settingsBuffer")`,
the `lagSwitch` option key names, and `input.setHotkeyMode("loose")`.

---

## Tests

The mock harness stubs every documented SMU global, asserts on invalid key names,
unknown `lagSwitch` option keys, double-holds, `setDynamicText` on an undeclared id,
`freeze(true)` during cleanup, and out-of-range slider defaults. It then drives
`onSettings` → `onExecute` → `onCleanup` on a virtual clock.

24 assertions across 11 cases: both phases emit the exact documented key order, the
two taps land strictly inside the frozen window, the measured window matches
`plannedFreezeMs()`, nothing is left held/frozen/lagging, and the self-test correctly
reports a raising `freeze`, an empty process name, and macOS lag-switch unavailability.

```
lua5.4 test.lua
```

---

## Caveats

- **Verified against the documented API and a mock host, not against a live Roblox
  client.** I can't run Roblox here, so the emitted input sequence and all timing
  are confirmed; whether the glitch reproduces on your build and in your specific
  game is not.
- Both items must be **droppable** — `CanBeDropped` is false on plenty of game-issued
  tools, and the setup phase will silently do nothing if slot B can't be dropped.
- Many games remap or disable Backspace-to-drop, and some disable hotbar slot keys
  entirely. Set the drop key to match the game.
- Roblox patches these. A method from 2023 may not survive the current engine.
- Automating input and suspending the client are against the Roblox Terms of Use;
  account action is possible.
