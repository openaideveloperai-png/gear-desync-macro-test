# Gear Desync v4 — SMU Lua macro

Item/gear desync for Roblox, built on **SMU's own shipped implementation** and
extended to desync several hotbar slots at once.

Drop `gear_desync.lua` into your SMU scripts folder, open its settings, tick
**Self-test only**, and fire it once before anything else.

---

## What the shipped macro actually does

SMU has a built-in **Item Desync** macro. Its entire body, from
[`app/macro_runtime.cpp`](https://github.com/Spencer0187/Spencer-Macro-Utilities/blob/main/app/macro_runtime.cpp):

```cpp
const unsigned int slotKey = InventorySlotKey(desync_slot);
HoldKey(slotKey);  ReleaseKey(slotKey);
HoldKey(slotKey);  ReleaseKey(slotKey);
```

…run every runtime tick for as long as the trigger is held. That is the whole
thing. Note what is **not** in it:

- no `freeze()`
- no drop key / Backspace
- no second inventory slot, no item on the ground
- no delay of any kind between the presses

The zero delay is deliberate. The sibling **Item Clip** macro is the same shape
but sleeps `clip_delay/2` between press and release; Item Desync is the flat-out
variant. You equip and unequip faster than the server can replicate the Handle
weld, so the server's copy lags behind the client's.

Freeze is a **separate macro** in SMU with its own hotkey (`vk_mbutton`). People
combine the two by hand. That is where the freeze step in the
[2023 wiki writeup](https://roblox-glitches.fandom.com/wiki/Item_Desync) comes
from — it is not part of item desync itself.

### Correction to v3

v3 of this script was built on that wiki procedure (drop an item, walk to it,
freeze, tap twice, unfreeze, equip+drop) on the assumption that the freeze was
the essential step. The author's own source says otherwise. **The v1 approach —
spam the slot key — was closest to correct all along**; it was just single-slot,
not tight enough, and had no diagnostics. The wiki procedure is kept here as
method 3 because it is a genuinely different *positional* desync, but it is the
least likely of the three to still work.

---

## Methods

| # | Method | Shape | Notes |
| --- | --- | --- | --- |
| 1 | **Loop (shipped)** | Hold-to-run | The shipped implementation, generalised to N slots. **Start here.** |
| 2 | **Freeze burst** | One-shot per press | The same churn, queued into a suspended client so the whole burst flushes in one or two frames. |
| 3 | **Ground item (2023 wiki)** | Setup key + trigger | The old procedure. Needs a droppable item and correct positioning. |

The lag switch can be layered on top of any of them.

## Desyncing multiple items

Put every slot in the **Slots** box: `1,2,3`. Commas, spaces and semicolons all
work; `10` and `0` both mean the 0 key; duplicates are dropped.

| Order | Behaviour | Use when |
| --- | --- | --- |
| **Interleave** (default) | `1 1 2 2 3 3` every pass — all slots churn continuously | The direct generalisation of the shipped macro. Try first. |
| **Burst per slot** | Finishes `burst_len` cycles on one slot before moving on | Slots seem to fight each other and none desyncs properly. |
| **Round robin** | One slot per pass, rotating | Lowest per-slot rate; a middle ground. |

With one slot configured, all three modes are identical to the shipped macro.

---

## Tuning

Defaults match the shipped macro exactly: **2 cycles per pass, 0 ms hold, 0 ms
delay.**

| Setting | Default | Notes |
| --- | --- | --- |
| Cycles per pass | 2 | What the shipped code does per tick. |
| Key hold | 0 ms | `HoldKey` immediately followed by `ReleaseKey`. Raise only if the game drops zero-length presses. |
| Delay between passes | 0 ms | Flat out. The script still calls `checkpoint()` so the watchdog doesn't kill it. |
| Stop after | 30 s | Safety limit on a held trigger. 0 disables. |

The self-test reports your **achievable churn rate** in cycles/sec. The shipped
macro relies on going flat out — if your input backend is slow, the desync may
never build, and that number tells you so.

---

## What the self-test checks

- **Your built-in Item Desync macro's own settings** (`desync_slot`,
  `ItemDesyncSlot`, `vk_f5`) and Item Clip's (`clip_slot`, `clip_delay`,
  `isitemclipswitch`). If the built-in works for you and this script doesn't,
  the difference is visible right here.
- Achievable equip/unequip cycles per second
- Slot parsing — what it understood, what it ignored
- Target process name (`settingsBuffer`) — only matters for methods 2 and 3
- `maxfreezetime` auto-unfreeze cap vs. the planned freeze window
- Whether `freeze(true)` raises, and whether the client kept writing log lines
  while suspended (a live client logs continuously; a suspended one doesn't)
- Lag-switch `available` / `active` / `targetMode` / `unsupportedReason`

---

## Tests

`tests/harness.lua` stubs every documented SMU global on a virtual clock and
asserts on invalid key names, unknown `lagSwitch` option keys, double-holds,
`setDynamicText` on an undeclared id, `freeze(true)` during cleanup, and
out-of-range slider and dropdown defaults.

```
cd tests && lua5.4 test.lua
```

48 assertions across 15 cases. Beyond the obvious ones, these are the checks
that have actually caught bugs:

- **Exact key order per method** — `1 1 2 2 3 3` for interleave, six presses of
  slot 1 before slot 2 for burst, `[F] 1 1 3 3 [U] 1 Backspace 3 Backspace` for
  multi-slot ground item
- **The safety limit doesn't re-arm under a held trigger.** It did: `runLoop`
  stopped at 1 s, returned to the outer loop, saw the trigger still down and
  restarted immediately, giving 1-second bursts until you let go. Now it waits
  for release.
- **Zero UI writes between the first and last keypress.** `ui.setDynamicText` +
  `table.concat` per pass would dominate a zero-delay loop and is the single
  easiest way to silently ruin this macro's timing.
- **No cycles land outside the frozen window** in method 2.

---

## If it still doesn't work

Run the self-test and compare its **built-in macro settings** block against what
you have configured here. Then, in order of likelihood:

1. **The built-in Item Desync macro doesn't work for you either.** Test it
   directly — same slot, same hotkey. If it doesn't, this script won't, and the
   problem is your setup or the game, not the sequence.
2. **The game blocks hotbar slot keys**, or remaps them. Common in games with
   custom inventory UIs.
3. **Churn rate too low** — check the self-test number.
4. **The gear isn't the right kind.** The glitch needs a tool with a `Handle`.
   Handle-less tools have nothing to desync.
5. **Methods 2 and 3 only:** freeze isn't landing — check the target process
   name in SMU's main settings.

---

## Caveats

- **Verified against the documented API, the shipped C++ implementation, and a
  mock host — not against a live Roblox client.** I can't run Roblox here. The
  emitted input sequences and timing are confirmed; whether the glitch
  reproduces in your game is not.
- Roblox patched center-of-mass offsetting on **2025-09-30**, which killed the
  emote-based speed glitch. Per the wiki, item desync survived that patch and is
  now the recommended workaround for it — but engine behaviour moves, and
  anything here can stop working.
- Method 3 additionally needs both items to be **droppable** (`CanBeDropped` is
  false on plenty of game-issued tools) and Backspace to be the game's drop key.
- Automating input and suspending the client are against the Roblox Terms of
  Use; account action is possible.

Sources: [SMU repo](https://github.com/Spencer0187/Spencer-Macro-Utilities) ·
[Lua scripting docs](https://github.com/Spencer0187/Spencer-Macro-Utilities/blob/main/docs/lua_macro_scripting.md) ·
[Item Desync — Roblox Glitches Wiki](https://roblox-glitches.fandom.com/wiki/Item_Desync) ·
[Speed Glitch — Roblox Glitches Wiki](https://roblox-glitches.fandom.com/wiki/Speed_Glitch)
