# Disclaimer

**Read this in full before flashing PianoMax. Installing it means you understand and accept everything below.**

## What it does

PianoMax is a frequency scaling module for KernelSU on the Xiaomi Pad 8 Pro (codename piano, model 25091RP04C, SoC SM8750P).

It raises the CPU, GPU, DDR and LLCC ceilings to the top bins published in the SoC specification, writes them through the `thermal_message/cpu_limits` command channel, and holds them with a daemon that loops every second. It also switches the compute thermal zones to `disabled` so the kernel stops throttling on those readings.

It does **not** stop `mi_thermald` and does **not** touch the battery, charger, BCL current limit or PMIC junction protection paths.

Temperature spoofing is a **separate switch that ships off**, with four tiers (off / lock only / normal 28 zones / max 48 zones). The higher the tier, the more sensors stop reporting the truth: at Max the module's own chip tripwire is left with only the eight PMIC junctions plus the battery and has effectively lost its input, while Normal keeps 29 real readings and stays armed. Battery, charger, BCL, PMIC and chassis zones remain real on every tier, and hardware over-temperature protection stays armed. The full boundary, tier by tier, is in the README's "Temperature spoof" section — please read it before switching anything on.

## What that means

By default the system throttles as temperature rises, keeping junction temperatures inside a safe band. With this module installed that throttling path is disabled for the compute zones, so the chip runs near its top bins for extended periods.

Three direct consequences:

1. **Surface temperatures will be noticeably higher.** Under sustained load the frame and back can become uncomfortable to hold. That is the design goal, not a fault.
2. **Power draw rises significantly.** Battery life shrinks, and a non-stock charger may not keep up, which shows up as repeated charge interruptions or stutter.
3. **There is a hardware risk in extreme cases.** Long-term operation at high temperature and power accelerates battery ageing and can, in principle, permanently damage the SoC or its power delivery.

The module ships with temperature tripwires (90-105 °C depending on the preset): when the hottest sensor crosses one, the daemon stages down and eventually restores every parameter and pauses. That is a **software** protection. It assumes the system is still healthy enough to run. If the system hangs, the kernel panics, or the daemon is killed, that protection does not apply.

## What is explicitly not promised

- **Stability.** This is a beta, verified on one device and one system build (HyperOS 3 / OS3.0.309.0.WPYCNXM).
- **Data safety.** The module changes system-level scheduler and memory parameters. A crash in extreme cases can lose unsaved data.
- **Reversibility.** A full factory restore is provided, but restoring parameters does not repair hardware that has already been damaged by heat.

## Situations this is not recommended for

- Sustained full load while charging (heat and current at the same time)
- Environments with poor cooling (bedding, a car, direct sun, sealed cases)
- Critical workloads on a device you cannot afford to lose
- Use on a device whose fastboot / recovery procedure you do not know

## Recovery

1. **Boot loop:** create an empty file named `disable` inside `/data/adb/modules/pianomax/` from recovery or `adb shell`. KernelSU skips the module on the next boot.
2. **KernelSU module page reachable:** disable it there.
3. **No system access at all:** flash the stock `init_boot` image in fastboot to remove KernelSU and all modules.
4. **Recovery available:** delete `/data/adb/modules/pianomax`.

The module itself restores parameters before exiting when it sees the `disable` file, so it will not leave the device pinned.

## Liability

This software is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose and noninfringement.

**In no event shall the authors or copyright holders be liable for any claim, damages or other liability**, whether in an action of contract, tort or otherwise, arising from, out of or in connection with the software or the use or other dealings in the software.

In short: this software was installed by choice on a personally owned device. Overheating, stuttering, battery drain, reboots or permanent damage after installation are the user's responsibility. The author accepts no liability.

## License

[PolyForm Noncommercial License 1.0.0](LICENSE).
