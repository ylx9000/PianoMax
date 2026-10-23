#!/system/bin/sh
# PianoMax - single-shot status collector
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# One exec() per widget would mean 22 value reads plus six status reads every
# three seconds, each one a fresh root shell, and ksu.exec serialises them on a
# single thread.  This collects the whole picture once and prints it as
# key=value lines, so a refresh costs exactly one call.

# Sourced from control.sh's cmd_snapshot: PM_DIR is already set there, so the
# common.sh pass is skipped (85 ms of parsing per poll). The dirname fallback
# covers the direct runs (tune.sh status).  Note $0 is the CALLER's path under
# source, so this fallback must not be trusted to locate the module when
# PM_DIR exists -- hence the guard, not a blind re-source.
[ -n "${PM_DIR:-}" ] || PM_DIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
[ -f "$PM_DIR/lib/common.sh" ] || PM_DIR=$(dirname "$0")
[ -n "${PM_DIR:-}" ] && [ -f "$PM_DIR/lib/common.sh" ] && . "$PM_DIR/lib/common.sh"

MODE=${1:-full}
case "$MODE" in --snapshot|snapshot|light) MODE=snapshot ;; esac

kv() { echo "$1=$2"; }

# ---- module ---------------------------------------------------------
# module.prop: two lines read through the builtin.  The old grep|cut pair per
# key was four forks (~130 ms at this box's ~33 ms per exec) to answer a
# question the first line of the file already holds.  All values keep the
# trailing content after the first '=' exactly as cut -d= -f2 did.
_ver=""; _id=""
while IFS= read -r _v; do
    case "$_v" in
        version=*) _ver=${_v#*=} ;;
        id=*)      _id=${_v#*=} ;;
    esac
done < "$PM_DIR/module.prop" 2>/dev/null
kv version "$_ver"
kv id "$_id"
if [ -f "$PM_DIR/disable" ]; then kv state disabled
elif [ -f "$PM_OFF" ]; then kv state off
else kv state on; fi
S=""
IFS= read -r S 2>/dev/null < "$PM_STATE"
# Before the guard's first tick .state does not exist yet; printing an empty
# value made the WebUI's hold field blank, which reads as "broken" rather
# than "starting".  "starting" is the honest answer for that window.
case "$S" in
    "") kv hold "starting" ;;
    *)  # Parameter expansion instead of echo|cut: one saved fork per poll.
        kv hold "${S%%'|'*}" ;;
esac
# guard fast path inlined: read the lock pid through the builtin, verify the
# cmdline with one grep -a (grep tolerates the NUL separators that make mksh
# read useless here -- it would stop at the first NUL and only see "sh").
# The old $(pm_guard_pid) paid cat+tr+grep (3 forks) for the same answer.
_g=""
_gpid=""
IFS= read -r _gpid 2>/dev/null < "$PM_DIR/.guard_lock/pid"
if [ -n "$_gpid" ] && grep -aq guard.sh "/proc/$_gpid/cmdline" 2>/dev/null; then
    _g=$_gpid
else
    # Lock missing or stale: fall back to the full /proc scan, which only
    # runs in the rare broken state, not on every poll.
    _g=$(pm_guard_pid 2>/dev/null)
    case $_g in "") _g=down ;; esac
fi
kv guard "$_g"
# Same answer as pm_profile_name without the $( ) subshell.
_pn=""; IFS= read -r _pn 2>/dev/null < "$PM_PROFILE"
case $_pn in "") _pn=极限 ;; esac
kv profile "$_pn"
# Whether the preset keeps the kernel governor or hands it back.  The WebUI
# needs it to know that the emul tiers are unavailable on the kernel-governed
# preset (apply_temp_spoof degrades them to lock), and offering a control that
# cannot work is worse than greying it out.
_z=""; IFS= read -r _z 2>/dev/null < "$PM_ZONES"
kv zones "$_z"
kv thermald "$(getprop init.svc.mi_thermald)"

# ---- live clocks ----------------------------------------------------
# All fifteen single-line sysfs nodes through the builtin (IFS= read -r),
# same form the tunables block below already used and the guard's hot loop
# uses: each replaced $(pm_cat ...) was a fork (~33 ms here), fifteen of
# them ~0.5 s of every poll.  Every node in this block is a single-line
# integer or word, which is exactly the mksh read sweet spot documented in
# common.sh.
IFS= read -r _v 2>/dev/null < "$CFG/policy0/scaling_cur_freq";  kv cur0 "$_v"
IFS= read -r _v 2>/dev/null < "$CFG/policy6/scaling_cur_freq";  kv cur6 "$_v"
IFS= read -r _v 2>/dev/null < "$CFG/policy0/scaling_max_freq";  kv max0 "$_v"
IFS= read -r _v 2>/dev/null < "$CFG/policy6/scaling_max_freq";  kv max6 "$_v"
IFS= read -r _v 2>/dev/null < "$CFG/policy0/scaling_min_freq";  kv min0 "$_v"
IFS= read -r _v 2>/dev/null < "$CFG/policy6/scaling_min_freq";  kv min6 "$_v"
IFS= read -r _v 2>/dev/null < "$CFG/policy0/scaling_governor";  kv gov  "$_v"
IFS= read -r _v 2>/dev/null < "$CFG/policy0/cpuinfo_max_freq";  kv hw0  "$_v"
IFS= read -r _v 2>/dev/null < "$CFG/policy6/cpuinfo_max_freq";  kv hw6  "$_v"
IFS= read -r _v 2>/dev/null < "$GPU/clock_mhz";                 kv gpu  "$_v"
IFS= read -r _v 2>/dev/null < "$GPU/thermal_pwrlevel";          kv tp   "$_v"
IFS= read -r _v 2>/dev/null < "$GPU/max_pwrlevel";              kv gpu_lvl "$_v"
IFS= read -r _v 2>/dev/null < "$GPU/max_gpuclk";                kv gpu_hw "$_v"
# The ceiling the current pwrlevel maps to.  max_pwrlevel is an ordinal, so
# neither the live clock (idle-locked) nor max_gpuclk (hardware max, constant)
# shows what a preset switch actually did to the GPU -- resolve the ordinal
# against the ladder and report the MHz a preset is capped at.
IFS= read -r _v 2>/dev/null < "$GPU/max_pwrlevel"; _gl=$_v
if [ -n "$_gl" ]; then
    IFS= read -r _v 2>/dev/null <<EOF
$(awk -v n=$((_gl + 1)) '{ print $n }' "$GPU/gpu_available_frequencies" 2>/dev/null)
EOF
    [ -n "$_v" ] || _v=0
    kv gpu_cap "$_v"
fi
IFS= read -r _v 2>/dev/null < "$BUS/DDR/cur_freq";              kv ddr  "$_v"
IFS= read -r _v 2>/dev/null < "$BUS/LLCC/cur_freq";             kv llcc "$_v"

# ---- temperature, always real ---------------------------------------
# trip_c/trip_s stay in the snapshot block (not full-only): the WebUI's
# verdict chip derives "approaching trip" from them, and snapshot mode
# without them made the chip assume the 105/60 defaults even when the
# preset or the user had moved the tripwires.
# One `cat` over every zone file beats one fork per zone (~0.13 s each
# pass was forks alone).  mode is read once per zone in the same pass, so
# the zone-count block further down disappears into this single walk.
PM_SPOOF_STATE=$PM_DIR/.spoof
# The state file carries a tier name now, not a boolean.  Normalise it here so
# every consumer downstream (the zone walk, the UI, the diagnostic) sees one of
# off / lock / normal / max no matter what an older build wrote; "on" is the
# pre-tier spelling of max.
SPOOF_RAW=""
IFS= read -r SPOOF_RAW 2>/dev/null < "$PM_SPOOF_STATE"
case "$SPOOF_RAW" in
    on|max) SPOOF_TIER=max ;;
    normal) SPOOF_TIER=normal ;;
    lock)   SPOOF_TIER=lock ;;
    *)      SPOOF_TIER=off ;;
esac
# Mirror apply_temp_spoof's kernel-preset degrade: on the powersave preset
# every emul tier actually runs as framework-lock-only (zones25 stays 0,
# measured 2026-10-23), so the badge/counts must report lock -- otherwise
# the UI advertises normal/max while the engine behaves as lock and the
# user reads the mismatch as "the spoof is broken".  .spoof keeps the raw
# user intent for the engine; this display tier reports live behaviour.
if [ "$SPOOF_TIER" = "normal" ] || [ "$SPOOF_TIER" = "max" ]; then
    [ "$(pm_zones_kernel)" = "yes" ] && SPOOF_TIER=lock
fi
# The tier's zone list has to be known before the walk so the count rides along
# with the reads the walk already performs.  It used to be a second full pass
# over the same zones (~0.3 s per call) that could only ever agree with the
# first one.  lock has no list at all -- it touches no sensor.
SPOOFABLE=" "
if [ "$SPOOF_TIER" = "max" ] || [ "$SPOOF_TIER" = "normal" ]; then
    pm_zone_cache_ok || pm_build_zone_cache
    # Builtin read: the list files are one line of space-separated ids.
    SPOOFABLE=""
    if [ "$SPOOF_TIER" = "normal" ]; then
        IFS= read -r SPOOFABLE 2>/dev/null < "$PM_DIR/.tz_spoofable_core"
    else
        IFS= read -r SPOOFABLE 2>/dev/null < "$PM_DIR/.tz_spoofable"
    fi
    [ -n "$SPOOFABLE" ] || SPOOFABLE=" "
fi
# Cap = the size of the tier's list, read from the cache rather than hardcoded:
# a ROM that adds or removes a sensor changes it, and a stale number in the UI
# would be indistinguishable from a broken spoof.
# Word count inline -- wc -w was a fork for a number the walk below re-derives
# anyway.  read populates the positional parameters, so $# is the word count.
SPOOF_CAP=0
case "$SPOOF_TIER" in
    max)    IFS= read -r _cap < "$PM_DIR/.tz_spoofable" ;;
    normal) IFS= read -r _cap < "$PM_DIR/.tz_spoofable_core" ;;
esac
if [ -n "$_cap" ]; then set -- $_cap; SPOOF_CAP=$#; fi
case "$SPOOF_CAP" in ''|*[!0-9]*) SPOOF_CAP=0 ;; esac
T_SKIN_MAX=0; T_HOT_MAX=0
ZTOT=0; ZD=0; SPOOF_N=0
V_CPU=0; V_GPU=0
# One walk over every zone yields five answers at once: total count, the
# chassis maximum, the hottest non-emulated reading, how many zones the
# module switched off, and how many are currently emulated.  Each of those
# used to be its own loop of forks.  Reads go through the builtin -- this
# script runs every three seconds behind an open WebUI, so its cost is
# literally the UI's frame budget.
for z in /sys/class/thermal/thermal_zone*; do
    ZTOT=$((ZTOT + 1))
    v=""
    IFS= read -r v 2>/dev/null < "$z/temp" || v=""
    case "$v" in ''|*[!0-9]*) v=0 ;; esac
    zn=${z##*/}; zn=${zn#thermal_zone}
    case "$PM_SKIN_ZONES" in
        *" $zn "*) [ "$v" -gt "$T_SKIN_MAX" ] && T_SKIN_MAX=$v ;;
    esac
    case "$v" in
        25000)
            # Exactly the spoof signature; excluded from t_hot so the page
            # keeps showing the real hottest sensor while the spoof is on
            # (zone 71 pmih010x_lite normally wins).
            case "$SPOOFABLE" in *" $zn "*) SPOOF_N=$((SPOOF_N + 1)) ;; esac ;;
        *) [ "$v" -gt "$T_HOT_MAX" ] && T_HOT_MAX=$v ;;
    esac
    # The page prints "chip junction" and "GPU" by name.  Tracking the real
    # maxima of those two clusters here -- instead of reading zones 13/23 a
    # second time afterwards -- is both cheaper and correct under spoofing:
    # 13 and 23 are exactly the zones the emul layer overwrites with 25 C,
    # while these maxima come from zones that were never written.
    case "$PM_CPU_ZONES" in
        *" $zn "*) [ "$v" -ne 25000 ] && [ "$v" -gt "$V_CPU" ] && V_CPU=$v ;;
    esac
    case "$PM_GPU_ZONES" in
        *" $zn "*) [ "$v" -ne 25000 ] && [ "$v" -gt "$V_GPU" ] && V_GPU=$v ;;
    esac
    m=""
    IFS= read -r m 2>/dev/null < "$z/mode"
    [ "$m" = "disabled" ] && ZD=$((ZD + 1))
done
BATT_T=""
IFS= read -r BATT_T 2>/dev/null < /sys/class/power_supply/battery/temp
case "$BATT_T" in ''|*[!0-9]*) BATT_T=0 ;; esac
# Tripwire pair without the $( ) subshell + echo fork: same parse
# pm_trip_pair does, inlined (its echo result was immediately re-split here).
TRIPC=105000; TRIPS=60000
_trip=""
IFS= read -r _trip 2>/dev/null < "$PM_TRIP"
if [ -n "$_trip" ]; then
    _x=${_trip%% *}
    _y=${_trip#* }
    case "$_x" in ''|*[!0-9]*) ;; *) TRIPC=$_x ;; esac
    [ "$_y" != "$_trip" ] && case "$_y" in ''|*[!0-9]*) ;; *) TRIPS=$_y ;; esac
fi
kv t_skin "$((T_SKIN_MAX / 1000))"
kv t_hot "$((T_HOT_MAX / 1000))"
kv trip_c "$((TRIPC / 1000))"
kv trip_s "$((TRIPS / 1000))"
# Real cluster maxima, taken in the walk above from zones the emul layer does
# not write.  Reading zone 13/23 directly made these two diagnostic fields
# report a fake 25 C chip whenever the spoof was on -- the only place in this
# UI where a spoofed value would have been presented as a measurement.
# When the emul layer is on, every zone in the CPU and GPU clusters reads the
# spoofed value, so there is no real per-cluster reading left to report --
# excluding 25000 and printing "0" would be a second kind of lie.  Fall back
# to the highest non-emulated sensor (PMIC junction, which spoofing never
# touches and which tracks the package): it is the closest honest number, and
# t_hot already publishes it with its true meaning.
# -1 is the explicit "not observable" marker the UI renders as a dash; a
# bare "—" would break the key=value integer contract every other field
# honours, and 0 would read as "sensor dead" and collide with the dead-sensor
# diagnostics.  Neither is acceptable for a measurement field.
# Arithmetic only -- no forks, no command substitutions.
if [ "$SPOOF_N" -gt 0 ]; then kv t_cpu -1; else kv t_cpu $(( V_CPU / 1000 )); fi
if [ "$SPOOF_N" -gt 0 ]; then kv t_gpu -1; else kv t_gpu $(( V_GPU / 1000 )); fi
kv t_batt "$(( BATT_T / 10 ))"
# lock has no emul zones by design, so it is reported from the tier rather than
# from a count that is legitimately zero there.
if [ "$SPOOF_TIER" = "lock" ]; then
    kv spoof lock
elif [ "$SPOOF_TIER" != "off" ] && [ "$SPOOF_N" -gt 0 ]; then
    kv spoof "$SPOOF_TIER"
else
    kv spoof off
fi
kv spoof_n "$SPOOF_N"
kv spoof_cap "$SPOOF_CAP"
kv trip "$TRIPC $TRIPS"
# The override flag only changes on a framework restart or a reset, and a
# dumpsys is the single most expensive read in this file (measured ~650 ms).
# The guard refreshes $PM_DIR/.override every 5 ticks while running, so the
# cache is at most ~5 s stale for a value that moves on framework restarts
# only.  Both modes read the cache; the dumpsys fallback covers the one case
# the guard cannot seed -- a status call on a box whose guard has not started
# yet this boot (no cache file) -- plus the cache being wiped by a restore.
# WebUI polling used to pay the full dumpsys every 3 s (cmd_snapshot runs
# full mode), which made the page's own refresh the heaviest thing it was
# observing.
OV_CACHE=""
IFS= read -r OV_CACHE 2>/dev/null < "$PM_DIR/.override"
if [ -n "$OV_CACHE" ]; then
    kv override "$OV_CACHE"
else
    # Guard has not seeded the cache yet: pay the dumpsys once rather than
    # reporting a blank.  The tr -d keeps the original output shape.
    kv override "$(dumpsys thermalservice 2>/dev/null | grep -m1 IsStatusOverride | tr -d ' ')"
fi

# ---- memory ---------------------------------------------------------
# One read of /proc/meminfo, three values out of it.  Three separate
# grep|tr|cut pipelines per refresh was three processes to answer a question
# the first one already had the text for.
MEMFREE=""; MEMAVAIL=""; CMAFREE=""
while IFS= read -r _ln; do
    case "$_ln" in
        MemFree:*)     set -- $_ln; MEMFREE=$2 ;;
        MemAvailable:*) set -- $_ln; MEMAVAIL=$2 ;;
        CmaFree:*)     set -- $_ln; CMAFREE=$2 ;;
    esac
done < /proc/meminfo 2>/dev/null
kv memfree "$MEMFREE"
kv memavail "$MEMAVAIL"
kv cmafree "$CMAFREE"

# ---- zones (counted in the temperature walk above) -------------------
kv zone_off "$ZD"
kv zone_on "$((ZTOT - ZD))"
kv zone_total "$ZTOT"
# spoof=on only when the state file says so AND at least one zone actually
# reads the spoof value; a stale .spoof with clean zones reports off.  The
# count is derived from the same compute set disable_compute_zones owns.

# ---- tunables the UI edits ------------------------------------------
# p_target / p_stage / the d_* diagnostics / p_refresh are UI polling keys:
# they read only module state files, so they run in every mode.  The rest of
# the block (the sliders' live values) stays full-only -- the WebUI pulls it
# once per session and after every write.  Reads go through the builtin
# (IFS= read -r) wherever the node type allows it; /proc/sys/* are seq_files
# that hand the builtin exactly one byte per read (measured: min_free_kbytes
# 40960 -> "4"), so those six nodes keep $(pm_cat).
if [ "$MODE" != "never" ]; then  # resident: UI polling keys, every MODE
_tg=""; IFS= read -r _tg 2>/dev/null < "$PM_TARGET"
_b0=""; _b6=""
case "$_tg" in *" "*) _b0=${_tg%% *} _b6=${_tg#* } ;; esac
case $_b0 in ''|*[!0-9]*) _b0=3532800 ;; esac
case $_b6 in ''|*[!0-9]*) _b6=4320000 ;; esac
kv p_target       "$_b0 $_b6"
_st=""; IFS= read -r _st 2>/dev/null < "$PM_STAGE"
kv p_stage        "${_st:--}"
# ---- dev diagnostics (she asked for richer observability, 2026-10-22):
# guard state files the page never surfaced before.
_t=""
IFS= read -r _t 2>/dev/null < "$PM_DIR/.gpu";      kv p_gpu "${_t:--}"
_t=""; IFS= read -r _t 2>/dev/null < "$PM_DIR/.gov";  kv d_gov "${_t:--}"
_t=""; IFS= read -r _t 2>/dev/null < "$PM_DIR/.trip"; kv d_trip "${_t:--}"
_t=""; IFS= read -r _t 2>/dev/null < "$PM_DIR/.spoof"; kv d_spoof_tier "${_t:--}"
# p_refresh rides the .refresh_cache (seeded by control.sh on every set),
# so it is free in the polling path too; the settings read only happens
# when the cache is missing.
_rfr=""
IFS= read -r _rfr 2>/dev/null < "$PM_DIR/.refresh_cache"
if [ -z "$_rfr" ]; then
    _rfr=$(settings get secure user_refresh_rate 2>/dev/null)
    [ -n "$_rfr" ] && [ "$_rfr" != "null" ] && echo "$_rfr" > "$PM_DIR/.refresh_cache" 2>/dev/null
fi
kv p_refresh "$_rfr"
fi

# ---- slider live values (full mode only: the WebUI pulls these once per
# session and after every write; the polling loop does not need them).
if [ "$MODE" != "snapshot" ]; then
    _v=""
    kv p_min_free   "$(pm_cat "/proc/sys/vm/min_free_kbytes")"
    kv p_extfrag    "$(pm_cat "/proc/sys/vm/extfrag_threshold")"
    kv p_proact     "$(pm_cat "/proc/sys/vm/compaction_proactiveness")"
    IFS= read -r _v 2>/dev/null < /sys/kernel/mm/lru_gen/min_ttl_ms;            kv p_min_ttl    "$_v"
    IFS= read -r _v 2>/dev/null < /sys/kernel/debug/sched/base_slice_ns;        kv p_slice      "$_v"
    IFS= read -r _v 2>/dev/null < /sys/kernel/debug/sched/migration_cost_ns;    kv p_mig        "$_v"
    IFS= read -r _v 2>/dev/null < /dev/cpuctl/top-app/cpu.uclamp.min;           kv p_uclamp_min "$_v"
    IFS= read -r _v 2>/dev/null < /dev/cpuctl/background/cpu.uclamp.max;        kv p_bg_max     "$_v"
    kv p_rtdef  "$(pm_cat "/proc/sys/kernel/sched_util_clamp_min_rt_default")"
    kv p_boost_ms   "$(pm_cat "/proc/sys/walt/input_boost/input_boost_ms")"
    kv p_edboost    "$(pm_cat "/proc/sys/walt/sched_ed_boost")"
    IFS= read -r _v 2>/dev/null < "$GPU/idle_timer";                            kv p_gpu_idle   "$_v"
    IFS= read -r _v 2>/dev/null < "$GPU/ifpc";                                  kv p_gpu_ifpc   "$_v"
    IFS= read -r _v 2>/dev/null < "$GPU/min_pwrlevel";                          kv p_gpu_minp   "$_v"
    IFS= read -r _v 2>/dev/null < "$BUS/DDR/soc:qcom,memlat:ddr:prime/min_freq"; kv p_ddr       "$_v"
    IFS= read -r _v 2>/dev/null < "$BUS/LLCC/soc:qcom,memlat:llcc:prime/min_freq"; kv p_llcc    "$_v"
    # p_watchdog: no cache file carries it and the last field of .state is
    # the governor, not the watchdog, so this stays a live settings read.
    kv p_watchdog "$(settings get global watchdog_timeout_millis 2>/dev/null)"
fi
