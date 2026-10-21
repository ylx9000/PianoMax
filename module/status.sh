#!/system/bin/sh
# PianoMax - single-shot status collector
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# One exec() per widget would mean 22 value reads plus six status reads every
# four seconds, each one a fresh root shell, and ksu.exec serialises them on a
# single thread.  This collects the whole picture once and prints it as
# key=value lines, so a refresh costs exactly one call.

. "$(dirname "$0")/lib/common.sh"

MODE=${1:-full}
case "$MODE" in --snapshot) MODE=snapshot ;; esac

kv() { echo "$1=$2"; }

# ---- module ---------------------------------------------------------
kv version "$(grep -m1 '^version=' "$PM_DIR/module.prop" 2>/dev/null | cut -d= -f2)"
kv id "$(grep -m1 '^id=' "$PM_DIR/module.prop" 2>/dev/null | cut -d= -f2)"
if [ -f "$PM_DIR/disable" ]; then kv state disabled
elif [ -f "$PM_OFF" ]; then kv state off
else kv state on; fi
S=$(cat "$PM_STATE" 2>/dev/null)
kv hold "$(echo "$S" | cut -d'|' -f1)"
kv guard "$(pm_guard_pid 2>/dev/null || echo down)"
kv profile "$(pm_profile_name)"
kv thermald "$(getprop init.svc.mi_thermald)"

# ---- live clocks ----------------------------------------------------
kv cur0 "$(pm_cat "$CFG/policy0/scaling_cur_freq")"
kv cur6 "$(pm_cat "$CFG/policy6/scaling_cur_freq")"
kv max0 "$(pm_cat "$CFG/policy0/scaling_max_freq")"
kv max6 "$(pm_cat "$CFG/policy6/scaling_max_freq")"
kv min0 "$(pm_cat "$CFG/policy0/scaling_min_freq")"
kv min6 "$(pm_cat "$CFG/policy6/scaling_min_freq")"
kv gov  "$(pm_cat "$CFG/policy0/scaling_governor")"
kv hw0  "$(pm_cat "$CFG/policy0/cpuinfo_max_freq")"
kv hw6  "$(pm_cat "$CFG/policy6/cpuinfo_max_freq")"
kv gpu  "$(pm_cat "$GPU/clock_mhz")"
kv tp   "$(pm_cat "$GPU/thermal_pwrlevel")"
kv gpu_lvl "$(pm_cat "$GPU/max_pwrlevel")"
kv gpu_hw "$(pm_cat "$GPU/max_gpuclk")"
kv ddr  "$(pm_cat "$BUS/DDR/cur_freq")"
kv llcc "$(pm_cat "$BUS/LLCC/cur_freq")"

# ---- temperature, always real ---------------------------------------
kv t_skin "$(( $(pm_temp_skin) / 1000 ))"
kv t_hot "$(( $(pm_temp_compute) / 1000 ))"
kv trip_c "$(( $(pm_trip_compute) / 1000 ))"
kv trip_s "$(( $(pm_trip_skin) / 1000 ))"
kv t_cpu "$(( $(pm_cat /sys/class/thermal/thermal_zone13/temp || echo 0) / 1000 ))"
kv t_gpu "$(( $(pm_cat /sys/class/thermal/thermal_zone23/temp || echo 0) / 1000 ))"
kv t_batt "$(( $(pm_cat /sys/class/power_supply/battery/temp || echo 0) / 10 ))"
kv trip "$(pm_trip_compute) $(pm_trip_skin)"

# ---- memory ---------------------------------------------------------
kv memfree "$(grep MemFree /proc/meminfo 2>/dev/null | tr -s ' ' | cut -d' ' -f2)"
kv memavail "$(grep MemAvailable /proc/meminfo 2>/dev/null | tr -s ' ' | cut -d' ' -f2)"
kv cmafree "$(grep CmaFree /proc/meminfo 2>/dev/null | tr -s ' ' | cut -d' ' -f2)"

# ---- zones ----------------------------------------------------------
zd=0; ze=0
for z in /sys/class/thermal/thermal_zone*; do
    if [ "$(cat "$z/mode" 2>/dev/null)" = "disabled" ]; then zd=$((zd + 1)); else ze=$((ze + 1)); fi
done
kv zone_off "$zd"
kv zone_on "$ze"
kv zone_total "$((zd + ze))"

# ---- tunables the UI edits (full mode only) -------------------------
if [ "$MODE" != "snapshot" ]; then
    kv p_min_free     "$(pm_cat /proc/sys/vm/min_free_kbytes)"
    kv p_extfrag      "$(pm_cat /proc/sys/vm/extfrag_threshold)"
    kv p_proact       "$(pm_cat /proc/sys/vm/compaction_proactiveness)"
    kv p_min_ttl      "$(pm_cat /sys/kernel/mm/lru_gen/min_ttl_ms)"
    kv p_slice        "$(pm_cat /sys/kernel/debug/sched/base_slice_ns)"
    kv p_mig          "$(pm_cat /sys/kernel/debug/sched/migration_cost_ns)"
    kv p_uclamp_min   "$(pm_cat /dev/cpuctl/top-app/cpu.uclamp.min)"
    kv p_bg_max       "$(pm_cat /dev/cpuctl/background/cpu.uclamp.max)"
    kv p_rtdef        "$(pm_cat /proc/sys/kernel/sched_util_clamp_min_rt_default)"
    kv p_boost_ms     "$(pm_cat /proc/sys/walt/input_boost/input_boost_ms)"
    kv p_edboost      "$(pm_cat /proc/sys/walt/sched_ed_boost)"
    kv p_gpu_idle     "$(pm_cat "$GPU/idle_timer")"
    kv p_gpu_ifpc     "$(pm_cat "$GPU/ifpc")"
    kv p_gpu_minp     "$(pm_cat "$GPU/min_pwrlevel")"
    kv p_ddr          "$(pm_cat "$BUS/DDR/soc:qcom,memlat:ddr:prime/min_freq")"
    kv p_llcc         "$(pm_cat "$BUS/LLCC/soc:qcom,memlat:llcc:prime/min_freq")"
    kv p_watchdog     "$(settings get global watchdog_timeout_millis 2>/dev/null)"
    kv p_refresh      "$(settings get secure user_refresh_rate 2>/dev/null)"
    kv p_target       "$(pm_base0) $(pm_base6)"
    kv p_stage        "$(cat "$PM_STAGE" 2>/dev/null || echo -)"
fi
