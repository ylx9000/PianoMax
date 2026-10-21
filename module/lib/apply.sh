#!/system/bin/sh
# PianoMax - all tunable writes in one place
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# Sourced by tune.sh (one-shot apply) and guard.sh (re-apply after a trip).
# Keeping these functions here is the whole point: tune.sh and guard.sh used
# to carry their own copies and drifted apart.

# mi_thermald is the tsens interrupt consumer on this platform.  Stopping it
# leaves a level-triggered IRQ uncleared, the CPU services it thousands of
# times per second and the whole system collapses.  It is started, never
# killed; this module competes with it instead.
ensure_thermald() {
    if [ "$(getprop init.svc.mi_thermald)" != "running" ]; then
        start mi_thermald 2>/dev/null
        sleep 1
        pm_log "thermald was down, restarted"
    fi
}

# Older builds of this module family wrote emul_temp.  Clearing every zone
# is cheap and guarantees real sensors even after a reinstall over a dirty
# system.
clear_emul() {
    for z in /sys/class/thermal/thermal_zone*; do
        echo 0 > "$z/emul_temp" 2>/dev/null
    done
}

# Disabling a compute zone stops the kernel thermal governor from raising its
# cooling device.  It does NOT stop mi_thermald, which is a userspace daemon
# writing cpu_limits directly -- guard.sh covers that half.  Hardware
# protection zones (battery, charger, BCL current, PMIC junction) are never
# touched, so a genuine overheat still reaches the kernel.
disable_compute_zones() {
    if [ "$(pm_zones_kernel)" = "yes" ]; then
        # The powersave preset hands thermal management back to the kernel: at those
        # clocks the stock governor never actually throttles, so silencing it
        # would only remove a safety net.
        n=0
        for z in /sys/class/thermal/thermal_zone*; do
            [ "$(cat "$z/mode" 2>/dev/null)" = "disabled" ] || continue
            echo enabled > "$z/mode" 2>/dev/null && n=$((n + 1))
        done
        pm_log "zones re-enabled:$n (kernel in charge)"
        return 0
    fi
    n=0; kept=0
    for z in /sys/class/thermal/thermal_zone*; do
        t=$(cat "$z/type" 2>/dev/null)
        case "$t" in
            *bcl*|*batt*|*battery*|*charger*|*usb*|*ibat*|*vbat*|*wireless*|pm8550*|pmih010x*)
                kept=$((kept + 1)) ;;
            *) echo disabled > "$z/mode" 2>/dev/null && n=$((n + 1)) ;;
        esac
    done
    pm_log "zones off:$n kept:$kept"
}

# cpu_limits is a command channel: it reads back empty, but a write there is
# what actually moves the ceiling.  scaling_max_freq written alone gets
# reverted by mi_thermald within seconds, so both are written, ceiling first.
pin_cpu() {
    a=$(pm_target0); b=$(pm_target6)
    for i in 0 1 2 3 4 5; do echo "cpu$i $a" > "$TM/cpu_limits" 2>/dev/null; done
    for i in 6 7; do echo "cpu$i $b" > "$TM/cpu_limits" 2>/dev/null; done
    pm_wr /sys/module/perfmgr/parameters/perfmgr_enable 0
    echo 0 > /sys/devices/system/cpu/cpu0/core_ctl/enable 2>/dev/null
    echo 0 > /sys/devices/system/cpu/cpu6/core_ctl/enable 2>/dev/null
    # performance is the module's working assumption; the WebUI persists a
    # user override in .gov and it wins here, otherwise every apply would
    # silently undo the choice the UI just reported as accepted.
    PM_GOV=performance
    [ -f "$PM_DIR/.gov" ] && { g=$(pm_cat "$PM_DIR/.gov"); case "$g" in
        performance|walt|schedutil|powersave) PM_GOV="$g" ;;
    esac; }
    pm_wr "$CFG/policy0/scaling_governor" "$PM_GOV"
    pm_wr "$CFG/policy6/scaling_governor" "$PM_GOV"
    pm_wr "$CFG/policy0/scaling_max_freq" "$a"
    pm_wr "$CFG/policy6/scaling_max_freq" "$b"
    pm_log "cpu $(pm_cat $CFG/policy0/scaling_max_freq)/$(pm_cat $CFG/policy6/scaling_max_freq)"
}

# The GPU ceiling is latched by a thermal cooling device, not by max_pwrlevel.
# "gpu" (kgsl's msm-adreno-tz consumer) holds cur_state=4 after a hot spell and
# that alone pins thermal_pwrlevel to 4, which rewrites max_gpuclk to 832 MHz --
# writing thermal_pwrlevel or max_pwrlevel afterwards is silently clamped back.
# Releasing the cooling device first is the only thing that actually works;
# measured: cur_state 4 -> 0 takes max_gpuclk from 832 to 1100 MHz.
pin_gpu() {
    [ -d "$GPU" ] || return 0

    # Release the latch.  Find the device by type rather than by index: the
    # numbering is not stable across kernel builds.
    for c in /sys/class/thermal/cooling_device*; do
        [ "$(pm_cat "$c/type")" = "gpu" ] || continue
        cur=$(pm_cat "$c/cur_state")
        if [ -n "$cur" ] && [ "$cur" != "0" ]; then
            echo 0 > "$c/cur_state" 2>/dev/null
        fi
    done

    # devfreq/max_freq is the knob kgsl actually honours; max_gpuclk is a
    # projection of it and rejects the write while a cap is in force.
    pm_wr "$GPU/devfreq/max_freq" 1100000000

    # kgsl indexes its table from the top: level 0 is 1100 MHz, level 12 is
    # 342 MHz.  Measured on this device:
    #   max_pwrlevel = 0  -> 1100 MHz   (no ceiling)
    #   max_pwrlevel = 6  ->  660 MHz   (capped)
    #   max_pwrlevel = 10 ->  389 MHz
    # so max_pwrlevel is the ceiling index, and min_pwrlevel is the idle floor
    # (default 12).  The WebUI slider drives the floor; presets drive the ceiling.
    lvl=$(pm_gpu_level)

    tp=$(pm_cat "$GPU/thermal_pwrlevel")
    if [ "$tp" != "0" ]; then
        echo 0 > "$GPU/thermal_pwrlevel" 2>/dev/null
        sleep 1
        tp=$(pm_cat "$GPU/thermal_pwrlevel")
    fi
    if [ "$tp" = "0" ]; then
        # Order matters: kgsl clamps max_pwrlevel to min_pwrlevel, and a
        # clamped write still returns success.  Floor first, then ceiling.
        pm_wr "$GPU/min_pwrlevel" 12
        pm_wr "$GPU/max_pwrlevel" "$lvl"
    else
        # Stay honest: pin to whatever the latch still allows instead of
        # advertising a clock the hardware will not deliver.
        pm_wr "$GPU/max_pwrlevel" "$tp"
    fi

    pm_wr "$GPU/idle_timer" 10000000
    pm_wr "$GPU/ifpc" 0
    pm_wr "$GPU/wake_nice" -20
    pm_wr "$GPU/wake_timeout" 300
    pm_log "gpu $(pm_cat $GPU/clock_mhz)MHz tp=$(pm_cat $GPU/thermal_pwrlevel) max=$(pm_cat $GPU/max_gpuclk)"
}

pin_bus() {
    ddr=$(pm_bus_ddr)
    llcc=$(pm_bus_llcc)
    for v in prime prime-latfloor gold gold-compute; do
        pm_wr "$BUS/DDR/soc:qcom,memlat:ddr:$v/min_freq" "$ddr"
        d="$BUS/LLCC/soc:qcom,memlat:llcc:$v/min_freq"
        [ -e "$d" ] && pm_wr "$d" "$llcc"
    done
    for b in 240b3400.qcom,bwmon-llcc-gold 240b7400.qcom,bwmon-llcc-prime; do
        pm_wr "$BUS/LLCC/$b/max_freq" "$llcc"
        pm_wr "$BUS/LLCC/$b/min_freq" "$llcc"
    done
    pm_log "bus ddr=$(pm_cat $BUS/DDR/cur_freq)/$ddr llcc=$(pm_cat $BUS/LLCC/cur_freq)/$llcc"
}

tune_mem() {
    pm_wr /proc/sys/vm/min_free_kbytes 40960
    pm_wr /proc/sys/vm/extfrag_threshold 300
    pm_wr /proc/sys/vm/compaction_proactiveness 30
    pm_wr /proc/sys/vm/compact_unevictable_allowed 1
    pm_wr /sys/kernel/mm/lru_gen/enabled Y
    pm_wr /sys/kernel/mm/lru_gen/min_ttl_ms 500
    sync
    echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
    echo 1 > /proc/sys/vm/compact_memory 2>/dev/null
}

tune_sched() {
    [ -d /sys/kernel/debug/sched ] || mount -t debugfs none /sys/kernel/debug 2>/dev/null
    pm_wr /sys/kernel/debug/sched/base_slice_ns 1500000
    pm_wr /sys/kernel/debug/sched/migration_cost_ns 250000
    pm_wr /dev/cpuctl/top-app/cpu.uclamp.latency_sensitive 1
    pm_wr /dev/cpuctl/top-app/cpu.uclamp.min 40
    pm_wr /dev/cpuctl/background/cpu.uclamp.max 16
    pm_wr /proc/sys/kernel/sched_util_clamp_min_rt_default 512
}

tune_walt() {
    IB=/proc/sys/walt/input_boost
    [ -d "$IB" ] || return 0
    pm_wr "$IB/input_boost_freq" "2400000 2400000 2400000 2400000 2400000 2400000 4320000 4320000"
    pm_wr "$IB/input_boost_ms" 200
    pm_wr /proc/sys/walt/sched_high_perf_cluster_freq_cap 2147483647
    pm_wr /proc/sys/walt/sched_boost 1
    pm_wr /proc/sys/walt/sched_ravg_window_nr_ticks 2
    pm_wr /proc/sys/walt/walt_rtg_cfs_boost_prio 110
    pm_wr /proc/sys/walt/sched_ed_boost 20
    pm_wr /proc/sys/walt/sched_asymcap_boost 1
    pm_wr /proc/sys/walt/sched_pipeline_busy_boost_pct 15
}

tune_io() {
    pm_wr /sys/class/block/sda/queue/read_ahead_kb 1024
    pm_wr /sys/class/block/sda/queue/max_sectors_kb 1024
    pm_wr /sys/block/sda/queue/add_random 0
    for d in /sys/fs/f2fs/dm-*; do
        [ -d "$d" ] || continue
        pm_wr "$d/cp_interval" 120
        pm_wr "$d/ram_thresh" 2
    done
}

tune_display() {
    settings put secure user_refresh_rate 144 2>/dev/null
    settings put secure miui_refresh_rate 144 2>/dev/null
    settings put secure speed_mode_enable 1 2>/dev/null
}

# Full application.  Called once at boot and once per re-arm after a trip.
pm_apply_all() {
    PM_FAILS=0
    ensure_thermald
    clear_emul
    disable_compute_zones
    pin_cpu
    pin_bus
    pin_gpu
    tune_mem
    tune_sched
    tune_walt
    tune_io
    tune_display
    settings put global watchdog_timeout_millis 180000 2>/dev/null
    pm_log "apply done, failures:$PM_FAILS"
    echo $PM_FAILS
}
