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

# Historical note: clear_emul used to sweep every zone reading emul_temp.
# That sweep could never see anything -- emul_temp is a write-only attribute
# (DEVICE_ATTR_WO, mode 0200, no show handler), so reading it back fails with
# EACCES by design -- and it cost 78 forks per apply for nothing.  Clearing is
# apply_temp_spoof's job now, which verifies through zone temperature.
# Kept as a no-op because pm_apply_all still calls it in sequence and the
# ordering there documents the apply pipeline.
clear_emul() { :; }

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
            m=""
            IFS= read -r m < "$z/mode" 2>/dev/null
            [ "$m" = "disabled" ] || continue
            echo enabled > "$z/mode" 2>/dev/null && n=$((n + 1))
        done
        # Handing the governor back also means dropping any emulation left
        # over from a module-governed preset: a zone that keeps reporting
        # 25 C would keep the governor blind even though it is in charge
        # again.  Clearing on the way in is what makes the handover real.
        e=0
        for z in /sys/class/thermal/thermal_zone*; do
            v=""
            IFS= read -r v < "$z/temp" 2>/dev/null
            [ "$v" = "25000" ] || continue
            echo 0 > "$z/emul_temp" 2>/dev/null && e=$((e + 1))
        done
        pm_log "zones re-enabled:$n cleared emul:$e (kernel in charge)"
        return 0
    fi
    n=0; kept=0
    # The governed set is the family the tripwires read (PM_SILICON_ZONES).
    # It used to be "every zone that is not protected", which quietly included
    # ddr, camera, video and the DSP zones that no tripwire watched -- 22
    # zones with the kernel governor switched off and nothing measuring them.
    # Deriving both sides from one list makes that class of gap impossible.
    for z in $PM_SILICON_ZONES; do
        node="/sys/class/thermal/thermal_zone$z/mode"
        [ -e "$node" ] || continue
        # Zones already disabled keep their state; rewriting the same value
        # every apply costs one write per zone per pass for nothing.
        m=""
        IFS= read -r m < "$node" 2>/dev/null
        [ "$m" = "disabled" ] && { n=$((n + 1)); kept=$((kept + 1)); continue; }
        echo disabled > "$node" 2>/dev/null && n=$((n + 1))
    done
    # Protected families stay enabled and are still counted for the log line.
    for z in /sys/class/thermal/thermal_zone*; do
        t=""
        IFS= read -r t < "$z/type" 2>/dev/null
        case "$t" in
            *bcl*|*batt*|*battery*|*charger*|*usb*|*ibat*|*vbat*|*wireless*|pm8550*|pmih010x*)
                # Self-heal: a protected zone must never sit disabled.  On one
                # boot the kernel governor itself was observed having flipped
                # thermal_zone57 (battery) to disabled -- not our write, but a
                # blind battery sensor is what the protected family exists to
                # prevent, so every pass flips it back and logs the flip.
                m=""
                zn=${z##*/zone}
                IFS= read -r m < "$z/mode" 2>/dev/null
                if [ "$m" = "disabled" ]; then
                    echo enabled > "$z/mode" 2>/dev/null && \
                        pm_log "protected zone$zn ($t) was disabled -- re-enabled"
                fi
                ;;
        esac
    done
    pm_log "zones off:$n kept:$kept"
}

# cpu_limits is a command channel: it reads back empty, but a write there is
# what actually moves the ceiling.  scaling_max_freq written alone gets
# reverted by mi_thermald within seconds, so both are written, ceiling first.
# Qualcomm's boost daemons are a third and fourth frequency writer nobody
# told us about: perfd re-arms cpu_limits on its own schedule and
# perfboostsconfig feeds it launch/boost events, both undoing our ceiling
# seconds after apply.  A systemless file swap is not available to a KSU
# userspace module, so the reversible slice is initctl-level: stop the
# services for the duration of the module's run.  restore.sh starts them
# back.  Everything here is best-effort: a service the ROM does not define
# makes stop a no-op, and perfd can still be re-spawned by property triggers
# -- the guard's own re-pin loop remains the real keeper.
pin_boost_daemons() {
    # Log per daemon and only when it was actually running.  setprop ctl.stop
    # succeeds for a service the ROM never defined, so the old
    # "stop perfd && pm_log" printed "perfd stopped" on every apply of every
    # device, including the ones that have no perfd at all -- a log line that
    # reads as proof of work that never happened.
    for svc in perfd perfd.dyn qti-perfd perf-l2; do
        [ "$(getprop "init.svc.$svc" 2>/dev/null)" = "running" ] || continue
        stop "$svc" 2>/dev/null || continue
        pm_log "boost daemon $svc stopped"
    done
}

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
    # numbering is not stable across kernel builds.  The scan is cached in
    # .gpu_cdev (apply runs on every preset switch and 40 type-reads per
    # pass were measurable); a cached node that stops answering triggers a
    # full rescan, so a kernel renumbering self-heals on the next pass.
    CDEV=$(cat "$PM_DIR/.gpu_cdev" 2>/dev/null)
    if [ -n "$CDEV" ] && [ "$(pm_cat "$CDEV/type")" = "gpu" ]; then
        cur=$(pm_cat "$CDEV/cur_state")
        if [ -n "$cur" ] && [ "$cur" != "0" ]; then
            echo 0 > "$CDEV/cur_state" 2>/dev/null
        fi
    else
        for c in /sys/class/thermal/cooling_device*; do
            [ "$(pm_cat "$c/type")" = "gpu" ] || continue
            echo "$c" > "$PM_DIR/.gpu_cdev" 2>/dev/null
            cur=$(pm_cat "$c/cur_state")
            if [ -n "$cur" ] && [ "$cur" != "0" ]; then
                echo 0 > "$c/cur_state" 2>/dev/null
            fi
        done
    fi

    # devfreq/max_freq is the knob kgsl actually honours; max_gpuclk is a
    # projection of it and rejects the write while a cap is in force.
    pm_wr "$GPU/devfreq/max_freq" 1100000000

    # kgsl indexes its table from the top: level 0 is 1100 MHz, level 11 is
    # 342 MHz.  Measured on this device:
    #   max_pwrlevel = 0  -> 1100 MHz   (no ceiling)
    #   max_pwrlevel = 6  ->  660 MHz   (capped)
    #   max_pwrlevel = 10 ->  389 MHz
    # so max_pwrlevel is the ceiling index, and min_pwrlevel is the idle floor
    # (default 12).  The WebUI slider drives the ceiling (max_pwrlevel); the floor has no UI row.
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

# --- temperature spoofing (optional, off by default) ------------------------
# Writes 25 C into the emul_temp of every compute zone the module already
# disables, so the kernel governor sees a cold chip and never ramps its
# cooling devices.  The protected families (battery, charger, BCL current,
# PMIC junction) are excluded by the same pattern as disable_compute_zones --
# the hardware safety net reads true temperature no matter what this switch
# does.
#
# mi_thermald is PARTIALLY fooled, and the earlier "NOT fooled" note here was
# wrong.  Measured on-device (thermal.dump, 2026-10-22): its VIRTUAL-SENSOR
# aggregates cpu_therm with weight 8, cpu_therm is zone 62, and zone 62 is in
# the spoofable set -- so while the emul layer is up the daemon's virtual
# sensor reads a constant 25000 contribution.  Its other inputs (quiet_therm
# and the chassis family) are not spoofable and keep reporting truth, and with
# a swapped table in charge the daemon enforces OUR ceiling anyway -- but any
# reasoning that treats the daemon as an untouched independent observer of the
# compute die is wrong under normal/max.  The guard's own tripwires read the
# same 57-zone family this function writes, which is why PM_REAL exists.
# State lives in .spoof: off/lock/normal/max.  apply runs on every preset
# switch, boot and re-arm, so the mode self-heals wherever those paths run.
PM_SPOOF_STATE="$PM_DIR/.spoof"

# Spoof tiers.  The switch is not on/off any more: the emul layer can blind
# the chip tripwire entirely, so the amount of it has to be a decision rather
# than a side effect.  Each tier trades coverage for the number of sensors
# that keep reporting the truth.
#
#   off    -- nothing.  Clear the framework lock first, then the emulated zones
#             (a lock left behind with clean zones would freeze the framework
#             at NONE forever -- the one direction that must never stick).
#   lock   -- framework override only.  Games and anything reading
#             PowerManager / AThermal see a cool device; the kernel governor
#             and mi_thermald are untouched, so no sensor is lost.  Costs one
#             cmd call every 5 s and nothing else.
#   normal -- CPU clusters + GPU emulated (PM_SPOOF_CORE_ZONES).  The zones that
#             heat under load are blinded; DSP, storage, camera and video keep
#             reporting, and so does the PMIC, so the tripwire still has real
#             input.
#   max    -- every spoofable zone.  The pre-tier behaviour.
#
# "on" is accepted as an alias for max so a state file written by an older
# build keeps meaning what it meant.
apply_temp_spoof() {
    want=$(cat "$PM_SPOOF_STATE" 2>/dev/null)
    case "$want" in
        on|max) TIER=max ;;
        normal) TIER=normal ;;
        lock)   TIER=lock ;;
        *)      TIER=off ;;
    esac
    n=0; c=0
    # The kernel-zones preset hands soft thermal policy back to the stock
    # governor on purpose (at 1.5 GHz nothing throttles, so silencing it only
    # removes a safety net).  Emulating 25 C on those zones would fake-cold
    # the very governor that preset just put back in charge, which silently
    # undoes the reason the preset exists.  So on that preset every emul tier
    # degrades to lock; only the framework override applies, and it stops at
    # PowerManager/AThermal without ever reaching a kernel governor.
    if [ "$TIER" != "off" ] && [ "$TIER" != "lock" ] && [ "$(pm_zones_kernel)" = "yes" ]; then
        cmd thermalservice override-status 0 >/dev/null 2>&1
        pm_log "temp spoof ($TIER): kernel-governed preset, degraded to framework lock only"
        TIER=lock
    fi
    # Clear whatever a wider tier left behind before deciding what this tier
    # writes.  Downgrading max -> normal used to leave the 21 zones only max
    # covers still reading 25 C, and max -> lock left all 48 -- so "lock" and
    # "off" would report themselves while the device still behaved like max.
    # The cleanup is keyed on the target list, so switching between emul tiers
    # clears exactly the difference and nothing else.
    if [ "$TIER" = "lock" ] || [ "$TIER" = "off" ]; then
        _keep=""
    elif [ "$TIER" = "normal" ]; then
        _keep=$(cat "$PM_DIR/.tz_spoofable_core" 2>/dev/null)
    else
        _keep=$(cat "$PM_DIR/.tz_spoofable" 2>/dev/null)
    fi
    _all=$(cat "$PM_DIR/.tz_spoofable" 2>/dev/null)
    # With no usable list there is nothing to compare against; fall back to
    # sweeping every classified zone so a stale 25 C can never survive.
    [ -n "$_all" ] || _all="0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21
22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 56 62"
    _stale=0
    for _sz in $_all; do
        case " $_keep " in
            *" $_sz "*) continue ;;
        esac
        _sv=""
        IFS= read -r _sv < "/sys/class/thermal/thermal_zone$_sz/temp" 2>/dev/null
        [ "$_sv" = "25000" ] || continue
        echo 0 > "/sys/class/thermal/thermal_zone$_sz/emul_temp" 2>/dev/null &&             _stale=$((_stale + 1))
    done
    [ "$_stale" -gt 0 ] && pm_log "temp spoof ($TIER): cleared $_stale zones from a wider tier"
    if [ "$TIER" = "lock" ]; then
        cmd thermalservice override-status 0 >/dev/null 2>&1
        pm_log "temp spoof (lock): framework status override, 0 zones emulated"
        return 0
    fi
    # Classify from the type cache (one build per boot, spot-checked), not
    # from a fork per zone per pass.
    pm_zone_cache_ok || pm_build_zone_cache
    if [ "$TIER" = "normal" ]; then
        LIST=$(cat "$PM_DIR/.tz_spoofable_core" 2>/dev/null)
        LISTFILE="$PM_DIR/.tz_spoofable_core"
    else
        LIST=$(cat "$PM_DIR/.tz_spoofable" 2>/dev/null)
        LISTFILE="$PM_DIR/.tz_spoofable"
    fi
    # An empty list turns the loop below into a silent no-op -- the module
    # would report the switch as on while writing nothing, which is exactly
    # the "looks correct, does nothing" failure this project has hit three
    # times.  Rebuild once, and if it is still empty say so out loud.
    if [ -z "$LIST" ]; then
        rm -f "$PM_DIR/.tz_types" "$PM_DIR/.tz_spoofable" "$PM_DIR/.tz_spoofable_core"
        pm_build_zone_cache
        LIST=$(cat "$LISTFILE" 2>/dev/null)
    fi
    if [ -z "$LIST" ]; then
        pm_log "temp spoof ($TIER) ABORTED: zone classification produced an empty set"
        return 1
    fi
    for zn in $LIST; do
        z="/sys/class/thermal/thermal_zone$zn"
        # emul_temp is a write-only attribute (DEVICE_ATTR_WO: mode 0200,
        # no show handler), so it cannot be read back -- that is the API, not
        # a node that disappears after a write.  Verification therefore goes
        # through the zone temperature, where exactly 25000 is this module's
        # signature.  The rewrite is idempotent, so counting a zone that is
        # genuinely at 25.000 C is harmless.
        # Test the resolved tier, not the raw file contents: $want is "max",
        # "normal", "lock" or absent, so comparing it against the pre-tier
        # spelling "on" sent every emul tier down the clear branch and the
        # switch wrote nothing while reporting success.
        if [ "$TIER" = "max" ] || [ "$TIER" = "normal" ]; then
            cur=$(cat "$z/temp" 2>/dev/null)
            [ "$cur" = "25000" ] && { n=$((n + 1)); continue; }
            echo 25000 > "$z/emul_temp" 2>/dev/null && n=$((n + 1))
        else
            cur=$(cat "$z/temp" 2>/dev/null)
            [ "$cur" = "25000" ] || continue
            echo 0 > "$z/emul_temp" 2>/dev/null && c=$((c + 1))
        fi
    done
    if [ "$TIER" = "max" ] || [ "$TIER" = "normal" ]; then
        # Framework layer: lock the thermal status to NONE.  Games and any
        # PowerManager/AThermal consumer see a permanently cool device even
        # when the emul layer decays; verified to hold until reset or a
        # framework restart.
        cmd thermalservice override-status 0 >/dev/null 2>&1
        pm_log "temp spoof ($TIER): $n zones at 25 C + framework status override"
    else
        # Unlock first: a locked override with clean zones would freeze the
        # framework at NONE forever, which is the one direction of this
        # switch that must never stick.
        cmd thermalservice reset >/dev/null 2>&1
        # c=0 is a NORMAL outcome here: a wider tier already cleared every
        # zone, or nothing was spoofed.  The bare A && B form made the
        # function return 1 on exactly that success case, control.sh turned
        # it into err:spoof_apply, and the UI toasted "application failed"
        # while the kernel had just been cleaned perfectly (3/3 reproduced
        # 2026-10-23).  Always succeed: off is only ever a cleanup.
        if [ "$c" -gt 0 ]; then
            pm_log "temp spoof off: cleared $c zones"
        fi
        return 0
    fi
}

tune_mem() {
    # 20480 sits between the vendor 11584 and the old 40960: the old value
    # raised every zone watermark 3.5x, which pulled MemAvailable under the
    # lmkd lines early and got the launcher killed on memory spikes.  Twice
    # vendor keeps headroom for bursts without starving the reclaim pool.
    pm_wr /proc/sys/vm/min_free_kbytes 20480
    # 500 is the vendor value; 300 made compaction fire on every small
    # fragmentation event.  Proactiveness 8 keeps background compaction on
    # a short leash instead of a permanent drain.
    pm_wr /proc/sys/vm/extfrag_threshold 500
    pm_wr /proc/sys/vm/compaction_proactiveness 8
    pm_wr /proc/sys/vm/compact_unevictable_allowed 1
    pm_wr /sys/kernel/mm/lru_gen/enabled Y
    pm_wr /sys/kernel/mm/lru_gen/min_ttl_ms 500
    # Cache drop + full compaction run once per boot, here.  Re-running
    # them on every preset switch and guard re-arm emptied the page cache,
    # made MemAvailable spike and crash back down, and widened the lmkd
    # kill window exactly when the user was interacting with the device.
    if [ ! -f "$PM_DIR/.mem_boot_done" ]; then
        sync
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null
        echo 1 > /proc/sys/vm/compact_memory 2>/dev/null
        echo boot > "$PM_DIR/.mem_boot_done" 2>/dev/null
    fi
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
    # status.sh prefers this cache over a live "settings get" (that read forks,
    # and the value only moves when someone sets it).  Without seeding it here
    # the page kept showing the pre-write rate until the next restore.
    echo 144 > "$PM_DIR/.refresh_cache" 2>/dev/null
}

# Full application.  Called once at boot and once per re-arm after a trip.
pm_apply_all() {
    PM_FAILS=0
    # Rebuild the working files from the preset the UI shows before anything
    # reads them.  restore.sh deletes .target as part of its factory cleanup
    # and pm_base0/6 fall back to the extreme values when it is gone, so every
    # "restore then apply" cycle -- the module card button, the WebUI toggle,
    # tune.sh apply, the guard's re-arm -- used to come back at the extreme
    # ceiling no matter which preset the label named.
    #
    # Doing it here rather than at each entry point is the whole point: there
    # were three callers, the first fix covered one of them, and the card
    # button silently kept the bug.
    pm_state_rebuild
    ensure_thermald
    clear_emul
    disable_compute_zones
    apply_temp_spoof
    pin_cpu
    pin_boost_daemons
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
