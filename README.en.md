<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/logo-light.png">
  <img src="docs/logo.png" width="128" alt="PianoMax logo">
</picture>

# PianoMax

[简体中文](README.md) · See [CHANGELOG.md](CHANGELOG.md) for release notes

![release](https://img.shields.io/github/v/release/ylx9000/PianoMax?style=flat-square)
![downloads](https://img.shields.io/github/downloads/ylx9000/PianoMax/total?style=flat-square)
![stars](https://img.shields.io/github/stars/ylx9000/PianoMax?style=social)
![platform](https://img.shields.io/badge/platform-Android%2016%20%2F%20HyperOS%203-blue?style=flat-square)
![device](https://img.shields.io/badge/device-piano%20(Xiaomi%20Pad%208%20Pro)-orange?style=flat-square)
![license](https://img.shields.io/badge/license-PolyForm%20Noncommercial%201.0.0-lightgrey?style=flat-square)

</div>

A KernelSU userspace frequency governor module for the Xiaomi Pad 8 Pro (piano / SM8750P).

Four presets — Power save / Balanced / Performance / Extreme. Each preset is a complete set of CPU / GPU / bus ceilings plus two temperature tripwires, applied as a whole. A resident daemon re-asserts the ceiling every second, temperature readings are never faked, and hardware protection zones stay armed.

> [!WARNING]
> Only the Xiaomi Pad 8 Pro (piano / SM8750P) is supported. A device check aborts every script on anything else — nothing is modified.
> When upgrading from v1.0.0-beta, remove the old module in KernelSU Manager first; cross-version in-place updates are untested.

## Download

<div align="center">

[![Download](https://img.shields.io/badge/Download-PianoMax.zip-2ea44f?style=for-the-badge&logo=github)](https://github.com/ylx9000/PianoMax/releases/latest/download/PianoMax.zip)

</div>

The link always points to the latest release. Install: KernelSU Manager → Modules → Install from storage → select the zip (do not extract or rename) → reboot. Older versions are on the [Releases](https://github.com/ylx9000/PianoMax/releases) page.

## The four presets

Switching applies one complete set. Sliders remain available afterwards; a slider value overrides the preset value until a preset is selected again.

| Preset | LITTLE | Prime | GPU cap | DDR | LLCC | Silicon trip | Skin trip | Soft thermal |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 省电 (powersave) | 1555200 | 1958400 | 389 MHz | 1353000 | 533000 | 90 °C | 50 °C | kernel |
| 均衡 (balanced) | 2400000 | 2841600 | 660 MHz | 3187000 | 933000 | 100 °C | 55 °C | module |
| 性能 (performance) | 3072000 | 3513600 | 832 MHz | 4224000 | 1066000 | 105 °C | 62 °C | module |
| 极限 (extreme) | 3532800 | 4320000 | 1100 MHz | 4761000 | 1211000 | 105 °C | 75 °C | module |

- Every value is snapped to a frequency the kernel actually offers before being written. Values off the ladder are silently rounded by the kernel, and the UI then shows something the module never requested.
- **Powersave** returns soft thermal control to the kernel: at those clocks the stock curve never throttles, so silencing it would only remove a layer of protection.
- Presets write the same four state files as the sliders, so a preset and a manual edit never disagree about what is in force.
- After a preset switch the silicon still carries the previous preset's heat and could trip the new, lower tripwire immediately. A 15-second grace period follows each switch: ceilings are still asserted, but back-off is not evaluated until the thermal state has settled.
- The GPU column is a **cap**: the GPU has its own devfreq governor (msm-adreno-tz) and idles at lower levels by design. Whether the cap is in force is shown by max_gpuclk on the WebUI thermal page.

From a shell: `sh /data/adb/modules/pianomax/profile.sh powersave|balanced|performance|extreme`, and `profile.sh list` to list all four.

## Living with other modules (important)

PianoMax writes: `cpu_limits`, `scaling_max_freq`, `scaling_governor`, thermal zone `mode`, GPU pwrlevel and cooling devices, DDR / LLCC `min_freq`, scheduler (sched / walt) parameters, memory parameters (min_free / extfrag / compaction) and I/O tunables. **Any module writing the same nodes conflicts with it**, with these symptoms:

| Conflicting module type | Typical change | Symptom |
| --- | --- | --- |
| Performance-daemon modules ("game booster", "performance mode") | Also write cpu_limits / scaling_max_freq, or ship their own daemon | Two daemons contend for the ceiling; frequencies oscillate and no reading can be trusted |
| Thermal-masking scripts ("unplug thermal") | Disable battery / charger / BCL zones as well | PianoMax deliberately keeps hardware protection zones armed; once the other module disables them, the only remaining line of defence is the kernel critical trip, and a PMIC overtemperature means a black screen |
| mi_thermald killers | Replace mi_thermald with an empty script or kill it | tsens on this SoC is level-triggered: with nobody clearing the interrupt status the CPU services thousands of interrupts per second and the whole system stalls. PianoMax competes with the daemon instead of killing it |
| One-shot GPU clock "lockers" | Write thermal_pwrlevel / max_pwrlevel once at boot | msm-adreno-tz re-latches and the write decays within seconds; concurrent writers make the latch state unpredictable |
| Scheduler-tuning modules (sched / walt / uclamp) | Write the same nodes | Last writer wins; both UIs may show values that are not in force |
| Memory-tuning modules (min_free_kbytes / LRU) | Write the same /proc nodes | Same double-write situation; the winner depends on boot order |

Bottom line: treat PianoMax as the only performance module on the device. Coexistence gains nothing and makes both sides' logs untrustworthy. If coexistence is unavoidable, disable the frequency / thermal part of the other module first.

## Specification

| Unit | Value | Note |
| --- | --- | --- |
| CPU LITTLE | 3532800 kHz | policy0, 6 cores, 16 OPPs |
| CPU prime | 4320000 kHz | policy6, 2 cores, 16 OPPs |
| GPU | 1100 MHz | requires thermal_pwrlevel 0 |
| DDR | 4761000 kHz | memlat and bwmon votes |
| LLCC | 1211000 kHz | memlat and bwmon votes |

## Three channels, not one

The key to how this module works.

**1. cpu_limits is a command channel.** `/sys/devices/virtual/thermal/thermal_message/cpu_limits` always reads back empty, but a write there is the ceiling. Writing `scaling_max_freq` alone is overwritten by `mi_thermald` within two seconds; cpu_limits is not.

**2. Disabling a zone only stops the kernel.** Setting compute zones to `disabled` stops the kernel thermal governor from raising its cooling devices. `mi_thermald` is a userspace daemon writing cpu_limits directly and does not consult zone modes. Disabling zones alone is therefore not enough — the ceiling must be held by a daemon.

**3. The daemon is the third channel.** `guard.sh` reads the real ceiling every second and rewrites cpu_limits whenever it falls below the target. Its role is not acceleration but persistence: without it, the ceiling slides from 3532800 to 1785600 within 20 seconds of disabling zones. Measured on this device.

## Temperature policy

Compute zones (CPU, GPU, board sensors) are switched to `disabled` so the kernel no longer throttles on them. Battery, charger, BCL current limits and PMIC junction sensors are **left untouched**; `mi_thermald` keeps running.

The daemon watches two **independent** families of sensors, because their magnitudes differ so much that a single threshold cannot work:

| Family | Sensors | Tripwire (per preset) | Why |
| --- | --- | --- | --- |
| Silicon | CPU clusters, GPU, PMIC junction | 90 / 100 / 105 °C | full-load steady state is 90-105; shutdown is around 110 |
| Skin | quiet_therm, battery, charger, panel | 50 / 55 / 62 / 75 °C | hand feel and battery longevity |

Crossing a tripwire does **not** restore everything at once; it stages down: first to 88% of the preset base, then to 78% if still hot, and only the third stage hands everything back and pauses assertion. With temperatures settled for two minutes, one stage is given back every two minutes.

"Always maximum frequency" and "never above the tripwire" cannot both hold; one-shot restoration would make the module oscillate every minute.

**Why mi_thermald is never killed**: tsens on this SoC is level-triggered. With the daemon stopped, nobody clears the interrupt status, the CPU services the same interrupt thousands of times per second, and the system stalls. The module only ever starts it.

**Why emul_temp is never written**: faking temperatures defeats the kernel critical trip — the last hardware backstop. On this device that path ends in a PMIC overtemperature shutdown (black screen).

## Install

```
KernelSU → Modules → Install from storage → PianoMax.zip → reboot
```

Requires device code `piano` (Xiaomi Pad 8 Pro / SM8750P), Android 16 / HyperOS 3 and KernelSU. A device check aborts every script on anything else.

## Usage

Use the action button on the module card to switch the module on or off. The WebUI provides fine-grained control.

```sh
su -c "sh /data/adb/modules/pianomax/tune.sh status"
su -c "sh /data/adb/modules/pianomax/tune.sh apply"
su -c "sh /data/adb/modules/pianomax/tune.sh restore"
su -c "sh /data/adb/modules/pianomax/profile.sh list"
```

## WebUI

<p align="center">
<img src="docs/shots/perf-dark.png" width="49%" alt="Performance">
<img src="docs/shots/thermal-dark.png" width="49%" alt="Thermal">
</p>
<p align="center">
<img src="docs/shots/mem-dark.png" width="32%" alt="Memory">
<img src="docs/shots/sched-dark.png" width="32%" alt="Scheduler">
<img src="docs/shots/sys-dark.png" width="32%" alt="System">
</p>

Open from the KernelSU module card. Five tabs: performance, thermal, memory, scheduler, system.

Four deliberate design choices:

**One call returns the whole state.** The page calls `control.sh snapshot` every few seconds; one process returns 40+ values. Widgets never issue their own commands.

**Every write is verified.** Values go through `control.sh set`, which whitelists the node, bounds-checks the value and reads it back. Each edited row shows "applied", "clamped" or "not written" — never an unconditional "done".

**The verdict comes first.** The status line is not decoration: running at ceiling / approaching tripwire / tripped / daemon stopped / ceiling not in force. A stopped daemon means nothing is holding the frequency — that matters more than any number.

**Two tripwires, two steppers.** Silicon and skin are independent curves with separate bounds.

## GPU latch mechanism (measured)

The GPU ceiling is not decided by `max_pwrlevel`; it is latched by a thermal cooling device:

```
/sys/class/thermal/cooling_device37  type=gpu  cur_state=4
  → thermal_pwrlevel=4
  → max_gpuclk=832000000
```

In that state, writing `thermal_pwrlevel`, `max_pwrlevel` or `max_gpuclk` all silently fail (return 0, value unchanged). The only thing that works is writing `cooling_device*/cur_state` (found by `type=gpu`; the index is not stable across kernels) to 0 first, then `devfreq/max_freq`.

Measured: `cur_state 6 → 0` pulls `max_gpuclk` from 660 MHz back to 1100 MHz and `clock_mhz` follows immediately. The daemon re-checks the latch every pass and releases it again whenever msm-adreno-tz re-arms it.

## FAQ

**Battery life?** Extreme idles at roughly 1-2x the stock power draw; powersave and balanced are close to stock. Start on balanced.

**Does this disable thermal protection?** Only the kernel governor on compute zones. Battery, charger, BCL and PMIC zones stay armed, mi_thermald keeps running, and temperatures are never faked.

**Why does the GPU show 389 MHz?** Idle. The GPU has its own governor and only reaches the cap under load. Check max_gpuclk / max_pwrlevel to verify the cap.

**Another performance module is installed — which one takes effect?** Whichever writes last. See the compatibility section above; running both is not supported.

**Preset names changed after updating?** The beta names are now Power save / Balanced / Performance / Extreme. Old state files are recognised automatically; selecting a preset once completes the migration.

## Known limitations

- msm-adreno-tz re-latches the GPU at any time; the daemon re-releases it every second and readings dip briefly right after a re-latch.
- On Extreme, sustained full load reaches the 105 °C silicon tripwire within 4-8 seconds — a physical constraint, not a defect; use Performance for sustained loads.
- Heavy memory stress can still trigger kernel OOM on the 8 GB model. The launcher and SystemUI carry `oom_score_adj` protection and will not be picked, but background processes may be reclaimed.
- Full-speed power draw is significantly higher; use the original charger.

## Development

```sh
bash build.sh    # packages release/PianoMax-<version>.zip (plus stable-named PianoMax.zip)
```

Module layout:

```
module/
  module.prop
  post-fs-data.sh     cold-boot GPU window
  service.sh          one-shot apply after boot
  boot-completed.sh   daemon self-heal
  tune.sh             apply / restore / status entry
  restore.sh          factory restore
  guard.sh            resident daemon
  status.sh           single-shot status collector
  piano_diag.sh       one-shot health check (read-only, six sections)
  action.sh           module card button
  uninstall.sh
  customize.sh
  lib/common.sh       paths, logging, write counters
  lib/apply.sh        every tunable write (shared by tune and guard)
  webroot/
    index.html
    control.sh        the WebUI's only control surface
```

## License

PolyForm Noncommercial License 1.0.0 ([LICENSE](LICENSE)). Free to use, modify and redistribute for personal, non-commercial purposes; any commercial use (paid ROMs, bundled commercial module packs) requires prior written permission. Required Notice: Copyright (c) 2026 ylx9000.

## Disclaimer

Read [DISCLAIMER.md](DISCLAIMER.md) in full before flashing. In short: this runs the device at high temperature and power points; you bear the risk.
