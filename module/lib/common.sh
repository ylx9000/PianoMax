#!/system/bin/sh
# PianoMax - shared helpers
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.

# Every runtime script sources this so the paths and the log helper exist
# in exactly one place.  MODDIR is derived, never hardcoded: the module can
# be installed under modules_update while an update is pending, and a
# hardcoded /data/adb/modules path would then read and write the wrong tree.

# Find the module root by walking up from the calling script until module.prop
# appears.  Hardcoding /data/adb/modules/pianomax is wrong while an update
# sits in modules_update, and a plain dirname($0) is wrong for the scripts
# that live one level deeper (webroot/control.sh).  A caller that already
# located the module exports PM_DIR and wins -- this matters for tools that
# run from outside the module tree.
if [ -n "${PM_DIR:-}" ] && [ -f "$PM_DIR/module.prop" ]; then :; else
PM_DIR=$(dirname "$0")
i=0
while [ $i -lt 4 ] && [ ! -f "$PM_DIR/module.prop" ]; do
    PM_DIR=$(dirname "$PM_DIR")
    i=$((i + 1))
done
PM_DIR=$(cd "$PM_DIR" 2>/dev/null && pwd) || PM_DIR=$(dirname "$0")
fi
PM_LOG=$PM_DIR/pianomax.log
PM_STATE=$PM_DIR/.state
PM_TARGET=$PM_DIR/.target
PM_STAGE=$PM_DIR/.stage
PM_TRIP=$PM_DIR/.trip
PM_GPU=$PM_DIR/.gpu
PM_BUS=$PM_DIR/.bus
PM_ZONES=$PM_DIR/.zones
PM_PROFILE=$PM_DIR/.profile
PM_OFF=/data/adb/modules/.pianomax_off

CFG=/sys/devices/system/cpu/cpufreq
TM=/sys/devices/virtual/thermal/thermal_message
GPU=/sys/class/kgsl/kgsl-3d0
BUS=/sys/devices/system/cpu/bus_dcvs

pm_log() { echo "[$(date +%m-%d\ %H:%M:%S)] $*" >> "$PM_LOG" 2>/dev/null; }

# The daemon writes a heartbeat every 30 s forever; without a cap the log
# grows without bound.  Checked by size, truncated to the last 400 lines and
# only when past 32 KB, so normal bursts are never cut mid-trace.
pm_log_trim() {
    [ -f "$PM_LOG" ] || return 0
    sz=$(wc -c < "$PM_LOG" 2>/dev/null)
    [ "${sz:-0}" -gt 32768 ] || return 0
    tail -n 400 "$PM_LOG" > "$PM_LOG.tmp" 2>/dev/null && mv "$PM_LOG.tmp" "$PM_LOG"
}

# Read a sysfs node, print an empty string on any failure.
pm_cat() { cat "$1" 2>/dev/null; }

# Write, and report whether the kernel accepted it.  Silence is the default
# failure mode of shell redirection, so every tunable write is counted.
PM_FAILS=0
pm_wr() {
    [ -e "$1" ] || { PM_FAILS=$((PM_FAILS + 1)); pm_log "wr miss $1"; return 1; }
    if echo "$2" > "$1" 2>/dev/null; then return 0; fi
    PM_FAILS=$((PM_FAILS + 1)); pm_log "wr fail $1 (=$2)"; return 1
}

# --- install environment ----------------------------------------------------
# The manager that shipped us decides where updates live and which features
# make sense, and three managers set disjoint marker variables.  Probe the
# strongest evidence first (installer-provided variables), then fall back to
# filesystem traces an already-running manager always leaves behind.  A root
# box with no manager at all is still usable: the verdict then says so and
# the caller decides how far it is willing to go without one.
# Output: one line, "manager|module_root", no spaces.
pm_detect_root() {
    m=unknown
    root=/data/adb/modules
    if [ -n "${KSU:-}" ] || [ -x /data/adb/ksud ]; then
        m=ksu
    elif [ -n "${APATCH:-}" ] || [ -x /data/adb/apd ]; then
        m=apatch
    elif [ -n "${MAGISK_VER_CODE:-}" ]; then
        # Both KernelSU and APatch impersonate this variable with fixed
        # values (25200 / 27000); those cases are caught above, so a value
        # here means the real thing.
        m=magisk
    elif [ -x /data/adb/magisk/busybox ] || command -v magisk >/dev/null 2>&1; then
        # Env-less fallback for a shell that was never spawned by an
        # installer (adb su and friends): go by the daemons on disk.
        m=magisk
    elif [ -d /sbin/.magisk ] || [ -d /debug_ramdisk ]; then
        m=magisk
    elif [ "$(id -u 2>/dev/null)" = "0" ]; then
        m=rootonly
    fi
    # Every current manager keeps modules under /data/adb/modules; the
    # per-manager trees (ksu/, apd state) hold binaries and metadata only.
    # Verify rather than assume: a custom data layout must not silently
    # redirect writes, so the directory has to exist to be reported.
    [ -d "$root" ] || root=unknown
    echo "$m|$root"
}

# Numeric guard: is $1 a plain non-negative integer?
pm_num() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

# Zero-fork helpers for the guard hot loop.  Every $(cat ...) in the main
# while-body costs a fork+exec, and measured on this box the shell forks put
# a tick at ~1.2 s instead of the intended 1 s.  Both helpers are builtins
# only.
#
# pm_get VAR PATH: read one single-line sysfs/procfs value without a
# subshell.  mksh read stops at NUL and newline, which is exactly one sysfs
# integer, so the variable ends up identical to pm_cat output for every
# single-line node this module reads.  Multi-line nodes must not use it.
pm_get() {
    IFS= read -r "$1" < "$2" 2>/dev/null
}

# pm_cmdline_is PID PATTERN: does the process cmdline contain PATTERN?
# Runs one tr and one grep; kept as a helper so callers do not re-derive
# the NUL handling.  Full-tree scans keep their own loops.
# --- zone classification (single source) ------------------------------------
# The skin-zone numbers and the protected type patterns used to be hardcoded
# in four places (apply.sh, status.sh, guard.sh, piano_diag.sh); every drift
# between them was a latent bug.  They live here now.  The type map is
# cached once per boot in .tz_types (zoneN type per line) so callers stop
# paying a fork per zone per pass just to classify.
PM_SKIN_ZONES=" 57 58 59 60 63 64 65 66 67 68 "
# The two clusters the WebUI reports separately ("chip junction" and "GPU").
# Both are subsets of PM_SILICON_ZONES; they exist so the page can print a
# cluster reading rather than the whole-family maximum, which is usually a
# PMIC junction and 30 C hotter than the silicon.
PM_CPU_ZONES=" 1 2 3 4 5 6 7 8 9 10 11 12 13 14 "
PM_GPU_ZONES=" 23 24 25 26 27 28 29 30 "
# The core spoof set behind the "normal" tier: CPU clusters plus GPU only.
# These are the zones that actually heat up under game and benchmark load, and
# the ones a kernel governor reacts to first.  Everything else -- DSP, modem,
# camera, video, DDR, SoC-digital -- is left real on purpose: emulating those
# buys little (they move slowly) and costs the tripwire its last independent
# readings, so leaving them alone is what makes "normal is safer than max" a
# fact rather than a slogan.
PM_SPOOF_CORE_ZONES=" 1 2 3 4 5 6 7 8 9 10 11 12 13 14 \
16 17 18 19 20 21 23 24 25 26 27 28 29 30 "
PM_SPOOFABLE=" "

pm_build_zone_cache() {
    # .tz_types lines: "<zone> <spoofable|-> <type>".  Classifying at build
    # time lets the spoof counters and the freshness sentinels run a single
    # temp-read per zone instead of type+temp forks, and the skin list lives
    # only here and in PM_SKIN_ZONES.
    : > "$PM_DIR/.tz_types"
    # Numeric order, not glob order.  The glob expands as a string sort
    # (0, 1, 10, 11, ..., 2, 20, ...), which put zone 9 last and zone 44 in the
    # middle -- so any "first / middle / last" spot check was really reading
    # three neighbours of the same alphabetical cluster and could not detect a
    # stale tail.  Walking the numbers also makes the file readable by eye.
    _bz_n=0
    while [ "$_bz_n" -le 99 ]; do
        _bz_dir="/sys/class/thermal/thermal_zone$_bz_n"
        if [ -d "$_bz_dir" ]; then
            t=""
            IFS= read -r t < "$_bz_dir/type" 2>/dev/null
            if pm_zone_spoofable "$_bz_n" "$t"; then cls=spoofable; else cls=-; fi
            echo "$_bz_n $cls $t" >> "$PM_DIR/.tz_types"
        fi
        _bz_n=$((_bz_n + 1))
    done
    PM_SPOOFABLE=" "
    PM_SPOOF_CORE=" "
    while IFS= read -r _bz_line; do
        case "$_bz_line" in
            *" spoofable "*)
                _bz_id=${_bz_line%% *}
                PM_SPOOFABLE="$PM_SPOOFABLE$_bz_id "
                # Second list for the normal tier: same classification, cut
                # down to the CPU + GPU clusters.  Derived here rather than in
                # apply.sh so the two lists can never describe different boots.
                case "$PM_SPOOF_CORE_ZONES" in
                    *" $_bz_id "*) PM_SPOOF_CORE="$PM_SPOOF_CORE$_bz_id " ;;
                esac ;;
        esac
    done < "$PM_DIR/.tz_types"
    echo "$PM_SPOOFABLE" > "$PM_DIR/.tz_spoofable"
    echo "$PM_SPOOF_CORE" > "$PM_DIR/.tz_spoofable_core"
}

# Spot-check three spread-out entries rather than the first one.  A ROM that
# renumbers zones does not have to touch zone 0, and a single-line probe made
# the whole cache look valid off one surviving zone.  Variable names are
# _cz_-prefixed: mksh has no function-local scope and the caller's want/zn
# must survive this call.
# Spot-check first / middle / last.  Reading only the first few entries
# validated a single point: on this kernel zones 0, 15 and 22 are the same
# "aoss-N" family, so three consecutive lines could all pass while the rest
# of the file was stale.  Three spread-out samples cost the same and actually
# prove the numbering still holds.
pm_zone_cache_ok() {
    [ -s "$PM_DIR/.tz_types" ] || return 1
    # One pass over the file, keeping the first, the middle and the last entry
    # without sed / cat / pipelines: this runs inside apply_temp_spoof, and on
    # this box every fork is ~6 ms against a 1 s tick.
    # Three probes: first, middle and last.  Reading only the first few lines
    # validated a single point -- on this kernel zones 0, 15 and 22 are all the
    # "aoss-N" family, so three consecutive entries could pass while the rest
    # of the file was stale.
    #
    # Two short passes over a 78-line file: count first, then pick the middle
    # by index.  A one-pass slow cursor was tried and was off by one -- it
    # recorded the current line whenever the counter advanced, not the line at
    # the counter's final value, so a tampered middle entry went unnoticed.
    # Clarity beats a saved pass here; status.sh re-checks it on every emul-mode poll, so the cost is not once-per-boot.
    _cz_n=0
    while IFS= read -r _cz_line; do
        [ -n "$_cz_line" ] && _cz_n=$((_cz_n + 1))
    done < "$PM_DIR/.tz_types"
    [ "$_cz_n" -ge 3 ] || return 1
    _cz_pick=$(( (_cz_n + 1) / 2 ))
    _cz_i=0
    _cz_first=""
    _cz_mid=""
    _cz_last=""
    while IFS= read -r _cz_line; do
        [ -n "$_cz_line" ] || continue
        _cz_i=$((_cz_i + 1))
        [ "$_cz_i" -eq 1 ] && _cz_first="$_cz_line"
        [ "$_cz_i" -eq "$_cz_pick" ] && _cz_mid="$_cz_line"
        _cz_last="$_cz_line"
    done < "$PM_DIR/.tz_types"
    # Verify EVERY entry, not the three probes above.  On 2026-10-23 this box
    # came up with zone 56 = battery and 58 = socd, while the cache from the
    # previous boot had them the other way round.  First/middle/last all
    # matched, the cache was declared valid, and 56 -- now the battery -- ended
    # up in the spoofable set, so the top tier would have pinned the cell's
    # sensor at 25 C and blinded its own over-temperature protection.  A ROM
    # that renumbers zones can move exactly one middle entry.
    # 78 builtin reads are ~15 ms; status.sh runs this on every emul-mode poll, so the check is not free.
    while IFS= read -r _cz_line; do
        [ -n "$_cz_line" ] || continue
        _cz_id=${_cz_line%% *}
        _cz_rest=${_cz_line#* }
        _cz_ty=${_cz_rest#* }
        [ -n "$_cz_id" ] || return 1
        _cz_now=""
        IFS= read -r _cz_now < "/sys/class/thermal/thermal_zone$_cz_id/type" 2>/dev/null || return 1
        [ "$_cz_now" = "$_cz_ty" ] || return 1
    done < "$PM_DIR/.tz_types"
    return 0
}

# Is this zone spoofable?  $1 = zone number, $2 = type.  Two exclusions:
# the skin family by number, and the hardware-protection types by name --
# battery/charger/BCL/PMIC and the synthetic-skin inputs must read true
# temperature no matter what any switch says.
pm_zone_spoofable() {
    case "$PM_SKIN_ZONES" in
        *" $1 "*) return 1 ;;
    esac
    case "$2" in
        *bcl*|*batt*|*battery*|*charger*|*usb*|*ibat*|*vbat*|*wireless*|pm8550*|pmih010x*|quiet_therm|backlight_therm|conn_therm*|flash_therm|wifi_therm|display_therm|ambient*)
            return 1 ;;
    esac
    return 0
}

pm_cmdline_is() {
    tr '\000' ' ' < "/proc/$1/cmdline" 2>/dev/null | grep -q "$2"
}

# Rebuild the working state files from the preset the UI still shows.
#
# restore.sh removes .target as part of its factory cleanup, and both
# pm_base0 and pm_base6 fall back to the extreme preset's values when it is
# gone.  So "restore, then apply" used to come back at 3532800/4320000 no
# matter which preset the label said: turn the module off on 省电, turn it
# back on, and the UI reported 1555200 while the box ran the full ceiling.
# The guard only rebuilt these files on its re-arm path, which needs a trip
# first -- an ordinary off/on cycle never reached it.
#
# One definition, called from tune.sh apply and from the guard's re-arm, so
# the two paths cannot drift.
pm_state_rebuild() {
    [ -f "$PM_TARGET" ] && return 0
    _rb=""
    IFS= read -r _rb < "$PM_PROFILE" 2>/dev/null
    case "$_rb" in
        省电) _rbk=powersave ;;
        均衡) _rbk=balanced ;;
        性能) _rbk=performance ;;
        *)    _rbk=extreme ;;
    esac
    _rbl=""
    [ -s "$PM_DIR/presets.txt" ] &&         _rbl=$(grep "^$_rbk	" "$PM_DIR/presets.txt" 2>/dev/null | head -n 1)
    if [ -z "$_rbl" ]; then
        case "$_rbk" in
            powersave)   _rbl="powersave	省电	1555200	1958400	10	1353000	533000	90000	50000	kernel" ;;
            balanced)    _rbl="balanced	均衡	2400000	2841600	6	3187000	933000	100000	55000	module" ;;
            performance) _rbl="performance	性能	3072000	3513600	4	4224000	1066000	105000	62000	module" ;;
            *)           _rbl="extreme	极限	3532800	4320000	0	4761000	1211000	105000	75000	module" ;;
        esac
    fi
    # Columns after cut -f2-10: name c0 c6 gpu ddr llcc tc ts zones
    set -- $(echo "$_rbl" | cut -f2-10)
    echo "$2 $3" > "$PM_TARGET"
    echo "$7 $8" > "$PM_TRIP"
    echo "$4" > "$PM_GPU"
    echo "$5 $6" > "$PM_BUS"
    echo "$9" > "$PM_ZONES"
    # restore.sh wipes the governor preference with the rest of the state;
    # dropping a stale .gov here keeps a rebuilt state from carrying one.
    rm -f "$PM_DIR/.gov"
    pm_log "state rebuilt from preset $_rbk"
    return 0
}

# Highest temperature among the sensors the module never disables.
# Returns millidegrees.  Falls back to 0 so callers must range-check.
#
# Temperatures come in two families on this platform and they measure very
# different things, so they get separate thresholds and separate loops.  A
# single shared threshold cannot work: the PMIC and skin sensors idle around
# 32-48 C while the CPU junction idles near 85 C under load, so one number
# either never fires (PMIC peaks around 57 C) or fires constantly.

# Silicon: every zone the module turns the governor off for.  These are the
# only sensors that still mean anything once disable_compute_zones has run,
# so the list has to match that function's coverage exactly.
#
# It did not.  The original list held only the CPU clusters, the GPU and the
# PMIC junctions, while disable_compute_zones disables many more.  What fell
# through included ddr, camera-0/1, video, cpu_therm, socd and the DSP zones
# (aoss / mdmss / nsphvx / nsphmx): the kernel governor was silenced on all of
# them and no tripwire ever read them.  A DDR or camera thermal excursion
# could run to the hardware's own critical trip with this module reporting a
# cool chip the whole way.
#
# No counts are written here on purpose.  The gap was 21 when it was found and
# will change with any ROM that adds or removes a sensor; piano_diag.sh
# derives the number at runtime and reports the difference instead.
#
# The group is defined once, here, and disable_compute_zones derives its
# protected set from the same two variables -- a second hardcoded list is
# how the gap appeared in the first place.
PM_SILICON_ZONES=" 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 \
22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 \
56 62 69 70 71 72 73 74 75 76 "
# Sets PM_REAL alongside the maximum: how many of the inputs returned a usable
# reading that is NOT the spoofed 25000.  That is the count of sensors still
# telling the truth, which is what the guard's "all sensors dead" backstop has
# to watch.  A plain non-zero count cannot do it -- with the emul layer on, 49
# of the 57 inputs are pinned at 25000, so a total PMIC outage still yields a
# healthy-looking peak and the backstop would never fire exactly when it is
# needed most.
# The result goes into PM_TMAX, not stdout.  Callers used to write
# TC=$(pm_temp_compute) so the maximum could be captured, but a command
# substitution runs in a subshell: PM_REAL was incremented there and thrown
# away, leaving the guard's dead-sensor backstop reading a permanent zero and
# firing on every tick.  Setting a global and echoing the value as well would
# still lose the count on the $(...) path, so the function only sets globals
# and callers read PM_TMAX.
PM_REAL=0
PM_TMAX=0
pm_temp_compute() {
    PM_TMAX=0
    PM_REAL=0
    for z in $PM_SILICON_ZONES; do
        IFS= read -r v < "/sys/class/thermal/thermal_zone$z/temp" 2>/dev/null || continue
        pm_num "$v" || continue
        case "$v" in
            0|25000) ;;
            *) PM_REAL=$((PM_REAL + 1)) ;;
        esac
        [ "$v" -gt "$PM_TMAX" ] && PM_TMAX=$v
    done
    return 0
}

# Rotating variant: reads one quarter of the silicon family per call, chosen
# by position so each sweep sees a fixed set.  The family is the 57 zones the
# module disables, so a full pass takes four ticks -- 14 or 15 reads each
# instead of 57.  Silicon time constants are far above the four-second sweep,
# so the tripwire loses nothing; the full sweep still runs at every suspected
# trip so the back-off decision sees the true maximum.  Reads go through the
# builtin (measured 0.2 ms against 3.2 ms for a cat fork); at this width the
# difference is what keeps the tick near its nominal one second.
PM_ROT=0
# The rotating sweep cannot produce a trustworthy PM_REAL -- it only sees a
# quarter of the family per call -- so it leaves the last full-sweep value in
# place rather than overwriting it with a number a quarter too small.
# Sets PM_TROT and advances the rotation cursor.  No stdout, same reason as
# pm_temp_compute: PM_ROT has to survive the call, and it cannot do that from
# inside a command substitution.
PM_TROT=0
pm_temp_compute_rot() {
    PM_TROT=0
    i=0
    for z in $PM_SILICON_ZONES; do
        case $((i % 4)) in
            $PM_ROT) ;;
            *) i=$((i + 1)); continue ;;
        esac
        i=$((i + 1))
        v=""
        IFS= read -r v < "/sys/class/thermal/thermal_zone$z/temp" 2>/dev/null || continue
        pm_num "$v" || continue
        [ "$v" -gt "$PM_TROT" ] && PM_TROT=$v
    done
    PM_ROT=$(( (PM_ROT + 1) % 4 ))
    return 0
}

# Skin and battery: the sensors that track what the chassis and the cell are
# actually doing.  quiet_therm is the board's quiet-zone proxy for case
# temperature; the rest are the panel, connectivity and charging paths.
pm_temp_skin() {
    t=0
    for z in $PM_SKIN_ZONES; do
        v=""
        IFS= read -r v < "/sys/class/thermal/thermal_zone$z/temp" 2>/dev/null || continue
        pm_num "$v" || continue
        [ "$v" -gt "$t" ] && t=$v
    done
    echo $t
}

# Thresholds.  Silicon defaults just below thermal shutdown -- the module is
# meant to run hot, so this one is a damage guard, not a comfort guard.  Skin
# defaults where the chassis is genuinely hot rather than merely warm: 60 C is
# uncomfortable to hold and safe for the cell, 52 C tripped on every mouse
# movement.
# Both read the same file: one fork instead of four per tick, since the guard
# asks for both thresholds on every pass and a cut pipeline per field is pure
# waste at 1 Hz forever.
pm_trip_pair() {
    a=105000; b=60000
    v=""
    IFS= read -r v < "$PM_TRIP" 2>/dev/null || v=""
    if [ -n "$v" ]; then
        x=${v%% *}
        y=${v#* }
        pm_num "$x" && a=$x
        [ "$y" != "$v" ] && pm_num "$y" && b=$y
    fi
    echo "$a $b"
}
pm_trip_compute() { set -- $(pm_trip_pair); echo "$1"; }
pm_trip_skin()    { set -- $(pm_trip_pair); echo "$2"; }

# Four presets write these four files; the module reads them here so the
# presets and the individual sliders share one source of truth.  Every default
# below is the extreme value, i.e. "no preset chosen" behaves like the first
# release did.
pm_gpu_level() { v=$(pm_cat "$PM_GPU" | tr -d ' '); pm_num "$v" && echo "$v" || echo 0; }
pm_bus_ddr()   { v=$(pm_cat "$PM_BUS" | cut -d' ' -f1); pm_num "$v" && echo "$v" || echo 4761000; }
pm_bus_llcc()  { v=$(pm_cat "$PM_BUS" | cut -d' ' -f2); pm_num "$v" && echo "$v" || echo 1211000; }

# kernel = leave the stock thermal governor in charge; module = silence the
# compute zones ourselves.  The powersave preset keeps the kernel, because at
# low clocks there is nothing to gain from fighting it.
pm_zones_kernel() {
    v=""
    IFS= read -r v < "$PM_ZONES" 2>/dev/null
    [ "$v" = "kernel" ] && echo yes || echo no
}
pm_profile_name() {
    v=""
    IFS= read -r v < "$PM_PROFILE" 2>/dev/null
    [ -n "$v" ] && echo "$v" || echo 极限
}

# Nearest entry on a cpufreq ladder to `target * pct / 100`.  The guard needs
# this because a stage that is not a real ladder entry gets silently rounded by
# the kernel, and the UI would then show a number the module never asked for.
# The ladder never changes within a boot, and the guard calls this twice per
# tick (pm_hold0/6) plus twice more per back-off.  One cat per policy per boot
# instead of two per second forever.  The cache file is keyed by policy so a
# ROM update that ships new rungs invalidates naturally on reboot.
pm_ladder() {
    _pl_dir=$1
    _pl_key=${_pl_dir##*/}
    _pl_cache="$PM_DIR/.ladder-$_pl_key"
    _pl=""
    if [ -s "$_pl_cache" ]; then
        IFS= read -r _pl < "$_pl_cache" 2>/dev/null
    fi
    if [ -z "$_pl" ]; then
        _pl=$(cat "$_pl_dir/scaling_available_frequencies" 2>/dev/null)
        [ -n "$_pl" ] && echo "$_pl" > "$_pl_cache" 2>/dev/null
    fi
    echo "$_pl"
}

# Same snapping, but the rungs are pulled into a plain shell variable instead
# of through a command substitution.  $(...) forks; the guard calls this twice
# per tick, so the substitution alone was ~26 ms of every tick.
pm_step_down() {
    _sd_dir=$1; _sd_t=$2; _sd_pct=$3
    _sd_want=$((_sd_t * _sd_pct / 100))
    _sd_best=0; _sd_bestd=999999999
    _sd_rungs=$(pm_ladder "$_sd_dir")
    set -- $_sd_rungs
    for _sd_f in "$@"; do
        _sd_d=$((_sd_f > _sd_want ? _sd_f - _sd_want : _sd_want - _sd_f))
        if [ "$_sd_d" -lt "$_sd_bestd" ]; then _sd_bestd=$_sd_d; _sd_best=$_sd_f; fi
    done
    if [ "$_sd_best" -gt 0 ]; then echo "$_sd_best"; else echo "$_sd_t"; fi
}

# CPU ceiling the module should hold, per policy.  Two files, because they mean
# different things and must not overwrite each other:
#   .target  the user's preference, set from the WebUI, survives restarts
#   .stage   the guard's thermal back-off, transient by definition
# A stage written into .target was indistinguishable from a user preference, so
# a thermal event would permanently lower the ceiling the user had asked for.
pm_stage0() { v=$(pm_cat "$PM_STAGE" | cut -d' ' -f1); pm_num "$v" && echo "$v"; }
pm_stage6() { v=$(pm_cat "$PM_STAGE" | cut -d' ' -f2); pm_num "$v" && echo "$v"; }
# The ceiling the user or the preset asked for.  Never affected by a thermal
# back-off, so the guard can always compute a stage from a fixed reference.
pm_base0() { v=$(pm_cat "$PM_TARGET" | cut -d' ' -f1); pm_num "$v" && echo "$v" || echo 3532800; }
pm_base6() { v=$(pm_cat "$PM_TARGET" | cut -d' ' -f2); pm_num "$v" && echo "$v" || echo 4320000; }

# The ceiling currently in force: the back-off stage if one is active.
pm_target0() { v=$(pm_stage0); [ -n "$v" ] && echo "$v" || pm_base0; }
pm_target6() { v=$(pm_stage6); [ -n "$v" ] && echo "$v" || pm_base6; }

# The ceiling the kernel will actually hold.  sysfs accepts any number and
# rounds it to the nearest ladder entry, so comparing a raw request against the
# readback can never converge -- this is what every comparison must use.
pm_hold0() { pm_step_down "$CFG/policy0" "$(pm_target0)" 100; }
pm_hold6() { pm_step_down "$CFG/policy6" "$(pm_target6)" 100; }
# Match the guard by the absolute path it was started with.  A literal
# "pianomax/guard.sh" pattern only works when the module happens to live at
# that exact path, which is false during an update and false in the test copy.
pm_guard_pid() {
    # Fast path: the guard records its pid in the lock dir at startup.  The
    # WebUI snapshot calls this every few seconds and a full /proc scan per
    # call is pure waste when the lock is intact.
    p=$(cat "$PM_DIR/.guard_lock/pid" 2>/dev/null)
    if [ -n "$p" ] && [ -d "/proc/$p" ] && \
       tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q guard.sh; then
        echo "$p"; return 0
    fi
    # Slow path: lock dir gone (SIGKILL, stop, stale) but a guard may still
    # be winding down -- fall back to the scan.
    for p in /proc/[0-9]*; do
        c=$( { tr '\000' ' ' < "$p/cmdline"; } 2>/dev/null ) || continue
        case "$c" in
            *"$PM_DIR/guard.sh"*) echo "${p##*/}"; return 0 ;;
        esac
    done
    return 1
}

pm_guard_up() {
    [ -f "$PM_DIR/disable" ] && return 1
    [ -f "$PM_OFF" ] && return 1
    return 0
}

# Start the daemon detached and verify it actually took.  The check-then-start
# race is closed inside guard.sh itself (mkdir lock): two concurrent starters
# both spawn a candidate, and the loser exits before touching any state.
pm_guard_start() {
    pm_guard_up || return 1
    if pm_guard_pid >/dev/null; then
        # The fast path only reports a guard whose pid the lock records.
        # After a module update the old daemon survives without any lock and
        # the /proc scan still finds it -- trusting that answer here would
        # never start the new code and the takeover sweep would never run.
        # A live guard without a matching lock is a ghost: kill it and start.
        lp=$(cat "$PM_DIR/.guard_lock/pid" 2>/dev/null)
        gp=$(pm_guard_pid)
        if [ -n "$lp" ] && [ "$lp" = "$gp" ] && [ -d "/proc/$lp" ]; then
            return 0
        fi
        [ -n "$gp" ] && [ -d "/proc/$gp" ] && kill -9 "$gp" 2>/dev/null
        rm -rf "$PM_DIR/.guard_lock" 2>/dev/null
        pm_log "guard start: removed lockless instance $gp"
    fi
    setsid sh "$PM_DIR/guard.sh" </dev/null >/dev/null 2>&1 &
    n=0
    while [ $n -lt 10 ]; do
        sleep 0.5 2>/dev/null || sleep 1
        if pm_guard_pid >/dev/null; then pm_log "guard started (pid $(pm_guard_pid))"; return 0; fi
        n=$((n + 1))
    done
    pm_log "guard start failed"
    return 1
}

pm_guard_stop() {
    for p in /proc/[0-9]*; do
        c=$( { tr '\000' ' ' < "$p/cmdline"; } 2>/dev/null ) || continue
        case "$c" in
            *"$PM_DIR/guard.sh"*) kill "${p##*/}" 2>/dev/null ;;
        esac
    done
    sleep 1
    # A clean kill lets the guard's EXIT trap remove the lock, but a SIGKILL
    # or a kill during start does not; make stop always leave a clean slate.
    # Only when the recorded pid is not a live guard anymore: removing the
    # directory while a concurrent start already re-armed it would birth a
    # lockless instance, the exact bug the takeover sweep has to clean up.
    lp=$(cat "$PM_DIR/.guard_lock/pid" 2>/dev/null)
    if [ -n "$lp" ] && [ -d "/proc/$lp" ] && \
       tr '\000' ' ' < "/proc/$lp/cmdline" 2>/dev/null | grep -q guard.sh; then
        :  # a fresh guard owns the lock now; leave it alone
    else
        rm -rf "$PM_DIR/.guard_lock" 2>/dev/null
    fi
}
