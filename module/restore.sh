#!/system/bin/sh
# PianoMax - return every node to its measured factory value
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# The numbers below were captured from a clean boot on OS3.0.309.0.WPYCNXM
# with `cat`, not derived by inverting tune.sh.  Anything not measured says
# so in a comment rather than guessing.

. "$(dirname "$0")/lib/common.sh"

# Any thermal back-off the guard had put in force is not part of "factory".
# .state goes too: the guard rewrites it every tick while running, and a stale
# snapshot left behind after a restore is exactly what the UI must not show.
rm -f "$PM_STAGE" "$PM_TARGET" "$PM_STATE" "$PM_STATE.tmp" "$PM_DIR/.gov"

# Factory state means every zone enabled -- including ones the user or another
# module disabled on purpose.  That is deliberate: "restore" is the baseline
# the module promises, not a selective undo.
for z in /sys/class/thermal/thermal_zone*; do
    echo 0 > "$z/emul_temp" 2>/dev/null
    echo enabled > "$z/mode" 2>/dev/null
done

# Release the command channel so the stock daemon picks the policy again.
echo -n "" > "$TM/cpu_limits" 2>/dev/null

echo 1 > /sys/devices/system/cpu/cpu0/core_ctl/enable 2>/dev/null
echo 1 > /sys/devices/system/cpu/cpu6/core_ctl/enable 2>/dev/null

for p in policy0 policy6; do
    av=$(cat "$CFG/$p/scaling_available_governors" 2>/dev/null)
    case "$av" in
        *walt*) echo walt > "$CFG/$p/scaling_governor" 2>/dev/null ;;
        *)      echo schedutil > "$CFG/$p/scaling_governor" 2>/dev/null ;;
    esac
done

# Clearing cpu_limits does not rewrite scaling_max_freq, so the previous pin
# would survive a restore unless it is released explicitly.
for p in policy0 policy6; do
    hw=$(cat "$CFG/$p/cpuinfo_max_freq" 2>/dev/null)
    [ -n "$hw" ] && echo "$hw" > "$CFG/$p/scaling_max_freq" 2>/dev/null
done

echo 556800  > "$CFG/policy0/scaling_min_freq" 2>/dev/null
echo 1017600 > "$CFG/policy6/scaling_min_freq" 2>/dev/null

# perfmgr gate: the module disables it; the stock daemon expects it on.
echo 1 > /sys/module/perfmgr/parameters/perfmgr_enable 2>/dev/null

# GPU devfreq window: apply raised max_freq; the factory value is the level-0
# clock (1100 MHz on this part).  min_freq was never touched by apply.
echo 1100000000 > "$GPU/devfreq/max_freq" 2>/dev/null

# GPU factory: min_pwrlevel 12, max_pwrlevel 0.
# thermal_pwrlevel is deliberately NOT restored to its boot value (3): that
# value is just a stale latched state left by the stock thermal stack, and the
# guard re-releases the latch every tick while the module is on, so writing 3
# here would be undone a second later and "factory" would never hold.  Release
# the latch instead -- the stock governor re-arms it on its own once the module
# is actually off.
echo 12   > "$GPU/min_pwrlevel"     2>/dev/null
echo 0    > "$GPU/max_pwrlevel"     2>/dev/null
echo 0    > "$GPU/thermal_pwrlevel" 2>/dev/null
echo 80   > "$GPU/idle_timer"       2>/dev/null
echo 1    > "$GPU/ifpc"             2>/dev/null
echo -7   > "$GPU/wake_nice"        2>/dev/null
echo 100  > "$GPU/wake_timeout"     2>/dev/null

# sched
echo 3000000 > /sys/kernel/debug/sched/base_slice_ns 2>/dev/null
echo 500000  > /sys/kernel/debug/sched/migration_cost_ns 2>/dev/null
echo 0       > /dev/cpuctl/top-app/cpu.uclamp.latency_sensitive 2>/dev/null
echo 0       > /dev/cpuctl/top-app/cpu.uclamp.min 2>/dev/null
echo max     > /dev/cpuctl/background/cpu.uclamp.max 2>/dev/null
echo 0       > /proc/sys/kernel/sched_util_clamp_min_rt_default 2>/dev/null

# vm.  watermark_scale_factor 65 is the measured clean-boot value; vendor's
# perf daemon owns it at runtime, so restore writes what boot showed.
echo 65    > /proc/sys/vm/watermark_scale_factor 2>/dev/null
echo 11584 > /proc/sys/vm/min_free_kbytes 2>/dev/null
echo 0     > /proc/sys/vm/compaction_proactiveness 2>/dev/null
echo 500   > /proc/sys/vm/extfrag_threshold 2>/dev/null
echo 0     > /sys/kernel/mm/lru_gen/min_ttl_ms 2>/dev/null
echo 1     > /proc/sys/vm/compact_unevictable_allowed 2>/dev/null
echo Y     > /sys/kernel/mm/lru_gen/enabled 2>/dev/null   # kernel default; not measured per-device

# walt
echo "864000 0 0 0 0 0 0 0"              > /proc/sys/walt/input_boost/input_boost_freq 2>/dev/null
echo 0                                  > /proc/sys/walt/input_boost/input_boost_ms 2>/dev/null
echo "2400000 0 0 0 0 0 2841600 0"      > /proc/sys/walt/input_boost/powerkey_input_boost_freq 2>/dev/null
echo 400                                > /proc/sys/walt/input_boost/powerkey_input_boost_ms 2>/dev/null
echo 4                                  > /proc/sys/walt/sched_ravg_window_nr_ticks 2>/dev/null
echo 99                                 > /proc/sys/walt/walt_rtg_cfs_boost_prio 2>/dev/null
echo 10                                 > /proc/sys/walt/sched_ed_boost 2>/dev/null
echo 0                                  > /proc/sys/walt/sched_asymcap_boost 2>/dev/null
echo 0                                  > /proc/sys/walt/sched_pipeline_busy_boost_pct 2>/dev/null
echo 1                                  > /proc/sys/walt/sched_boost 2>/dev/null
echo 2147483647                         > /proc/sys/walt/sched_high_perf_cluster_freq_cap 2>/dev/null  # INT_MAX = uncapped, the boot value

# io
echo 512 > /sys/class/block/sda/queue/read_ahead_kb 2>/dev/null
echo 512 > /sys/class/block/sda/queue/max_sectors_kb 2>/dev/null
echo 1   > /sys/block/sda/queue/add_random 2>/dev/null
for d in /sys/fs/f2fs/dm-*; do
    [ -d "$d" ] || continue
    echo 200 > "$d/cp_interval" 2>/dev/null
    echo 1   > "$d/ram_thresh" 2>/dev/null
done

# DDR / LLCC factory votes.
for v in prime prime-latfloor gold gold-compute; do
    d="$BUS/DDR/soc:qcom,memlat:ddr:$v/min_freq"
    [ -e "$d" ] && echo 547000 > "$d" 2>/dev/null
    l="$BUS/LLCC/soc:qcom,memlat:llcc:$v/min_freq"
    [ -e "$l" ] && echo 350000 > "$l" 2>/dev/null
done
for d in "$BUS/LLCC/240b3400.qcom,bwmon-llcc-gold" "$BUS/LLCC/240b7400.qcom,bwmon-llcc-prime"; do
    [ -d "$d" ] || continue
    echo 350000 > "$d/min_freq" 2>/dev/null
    echo 806000 > "$d/max_freq" 2>/dev/null
done

# The daemon pins the launcher and SystemUI to oom_score_adj -1000.  0 is
# the normal starting value; lmkd re-tunes it at runtime anyway.
for p in $(pgrep -f com.miui.home 2>/dev/null) $(pgrep -f com.android.systemui 2>/dev/null); do
    # Same two-step check as the guard's launcher protection: an editor with
    # the package name in its command line must not match, and a wrong pid
    # pinned to -1000 becomes unkillable by lmkd.
    tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qE '(^|/)com\.(miui\.home|android\.systemui)' || continue
    echo 0 > "/proc/$p/oom_score_adj" 2>/dev/null
done

settings put secure user_refresh_rate 120 2>/dev/null
settings put secure miui_refresh_rate 120 2>/dev/null
settings delete secure speed_mode_enable 2>/dev/null
settings delete global watchdog_timeout_millis 2>/dev/null

sync
echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
echo 1 > /proc/sys/vm/compact_memory 2>/dev/null

# Factory includes the thermal policy: a swapped table would keep enforcing
# preset behavior with the module gone.  Runs last so the daemon reload
# happens after every sysfs node is already back.
if [ -f "$PM_DIR/lib/thermal.sh" ]; then
    . "$PM_DIR/lib/thermal.sh"
    pm_thermal_revert
fi

pm_log "restore done"
echo "restore done"
