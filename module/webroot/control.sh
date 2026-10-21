#!/system/bin/sh
# PianoMax - WebUI control surface
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# Every button in the UI ends up here.  One entry point means one place to
# validate, one place to log, and a stable contract: the UI never builds a
# shell command out of user input.
#
#   control.sh snapshot              -> key=value status line set
#   control.sh set <key> <value>     -> validated write, echoes ok|err:<why>
#   control.sh toggle                -> flip the module on/off
#   control.sh apply | restore       -> full pass

MODDIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
. "$MODDIR/lib/common.sh"

# Same device gate as every other entry point: the node map below is
# piano-specific sysfs, and a foreign device must not be able to write
# it from a WebUI tap.  The read-only snapshot path is exempted so the
# UI can still show why nothing works.
pm_device_gate() {
    [ "$(getprop ro.product.device)" = "piano" ] && return 0
    case "$1" in
        snapshot | presets) return 0 ;;
        *)        echo "err:unsupported_device"; exit 2 ;;
    esac
}
pm_device_gate "${1:-}"

# Whitelist: key -> node, accepted range, step.  Anything not on this list
# is rejected, so a typo in the UI cannot write to an arbitrary sysfs node.
node_of() {
    case "$1" in
        min_free)      echo /proc/sys/vm/min_free_kbytes ;;
        extfrag)       echo /proc/sys/vm/extfrag_threshold ;;
        proact)        echo /proc/sys/vm/compaction_proactiveness ;;
        min_ttl)       echo /sys/kernel/mm/lru_gen/min_ttl_ms ;;
        slice)         echo /sys/kernel/debug/sched/base_slice_ns ;;
        mig)           echo /sys/kernel/debug/sched/migration_cost_ns ;;
        uclamp_min)    echo /dev/cpuctl/top-app/cpu.uclamp.min ;;
        bg_max)        echo /dev/cpuctl/background/cpu.uclamp.max ;;
        rtdef)         echo /proc/sys/kernel/sched_util_clamp_min_rt_default ;;
        boost_ms)      echo /proc/sys/walt/input_boost/input_boost_ms ;;
        edboost)       echo /proc/sys/walt/sched_ed_boost ;;
        gpu_idle)      echo "$GPU/idle_timer" ;;
        gpu_ifpc)      echo "$GPU/ifpc" ;;
        gpu_minp)      echo "$GPU/min_pwrlevel" ;;
        gpu_lvl)       echo "$GPU/max_pwrlevel" ;;
        ddr)           echo "$BUS/DDR/soc:qcom,memlat:ddr:prime/min_freq" ;;
        llcc)          echo "$BUS/LLCC/soc:qcom,memlat:llcc:prime/min_freq" ;;
        *)             return 1 ;;
    esac
}

# Declared bounds, so the UI cannot ask for something the kernel would clamp
# anyway and then show a value it never reached.
bounds() {
    case "$1" in
        min_free)   echo "8192 131072" ;;
        extfrag)    echo "0 1000" ;;
        proact)     echo "0 100" ;;
        min_ttl)    echo "0 5000" ;;
        slice)      echo "500000 10000000" ;;
        mig)        echo "50000 2000000" ;;
        uclamp_min) echo "0 100" ;;
        bg_max)     echo "0 100" ;;
        rtdef)      echo "0 1024" ;;
        boost_ms)   echo "0 2000" ;;
        edboost)    echo "0 100" ;;
        gpu_idle)   echo "80 10000000" ;;
        gpu_ifpc)   echo "0 1" ;;
        gpu_minp)   echo "0 12" ;;
        gpu_lvl)    echo "0 12" ;;
        ddr)        echo "547000 4761000" ;;
        llcc)       echo "350000 1211000" ;;
        *)          echo "0 0" ;;
    esac
}

cmd_snapshot() { sh "$MODDIR/status.sh" full; }

cmd_set() {
    k=$1; v=$2
    [ -n "$k" ] && [ -n "$v" ] || { echo "err:missing"; exit 2; }
    # A write under PM_OFF would report ok and then never take effect:
    # tune.sh apply refuses to run while the switch is off.  Fail loudly
    # instead of letting the UI show a success that did not happen.
    [ -f "$PM_OFF" ] && { echo "err:switched_off"; exit 2; }

    # CPU ceiling is special: writing scaling_max_freq does nothing durable,
    # the ceiling has to be moved through cpu_limits.  The daemon reads the
    # .target file, so storing the request there is what actually holds.
    case "$k" in
        cpu_max0|cpu_max6)
            pm_num "$v" || { echo "err:not_a_number"; exit 2; }
            # Snap to a ladder entry before persisting.  Storing a number the
            # kernel will round means .target never matches the readback, and
            # the guard then re-writes cpu_limits on every tick forever.
            if [ "$k" = "cpu_max0" ]; then
                [ "$v" -ge 556800 ] && [ "$v" -le 3532800 ] || { echo "err:out_of_range"; exit 2; }
                v=$(pm_step_down "$CFG/policy0" "$v" 100)
                # Base, not target: during a thermal back-off the target holds
                # the staged value.  Writing it here would freeze the temporary
                # stage into the new permanent ceiling.
                b6=$(pm_base6); echo "$v $b6" > "$PM_TARGET"
            else
                [ "$v" -ge 1017600 ] && [ "$v" -le 4320000 ] || { echo "err:out_of_range"; exit 2; }
                v=$(pm_step_down "$CFG/policy6" "$v" 100)
                b0=$(pm_base0); echo "$b0 $v" > "$PM_TARGET"
            fi
            # Clear the back-off BEFORE computing the hold values: pm_hold0/6
            # read through pm_target*, which prefers a stage still on disk.
            # Removing it first makes the new ceiling take effect in the same
            # pass instead of one guard tick later.
            rm -f "$PM_STAGE"   # a new ceiling invalidates any back-off it replaces
            a=$(pm_hold0); b=$(pm_hold6)
            for i in 0 1 2 3 4 5; do echo "cpu$i $a" > "$TM/cpu_limits" 2>/dev/null; done
            for i in 6 7; do echo "cpu$i $b" > "$TM/cpu_limits" 2>/dev/null; done
            echo "$a" > "$CFG/policy0/scaling_max_freq" 2>/dev/null
            echo "$b" > "$CFG/policy6/scaling_max_freq" 2>/dev/null
            pm_log "target set $a/$b"
            echo "ok:$a $b"; exit 0 ;;
        gov)
            case "$v" in
                performance|walt|schedutil|powersave)
                    # Persist the choice: pin_cpu rewrites the governor on
                    # every apply (boot, re-arm, manual), so writing sysfs
                    # here alone reported ok and was silently undone seconds
                    # later.  The state file is the source pin_cpu reads.
                    echo "$v" > "$PM_DIR/.gov"
                    echo "$v" > "$CFG/policy0/scaling_governor" 2>/dev/null
                    echo "$v" > "$CFG/policy6/scaling_governor" 2>/dev/null
                    pm_log "governor set $v"
                    echo "ok:$v"; exit 0 ;;
                *) echo "err:bad_governor"; exit 2 ;;
            esac ;;
        trip|trip_skin)
            # Two independent tripwires.  trip = silicon, trip_skin = chassis.
            pm_num "$v" || { echo "err:not_a_number"; exit 2; }
            cur=$(cat "$PM_TRIP" 2>/dev/null || echo "105000 60000")
            a=$(echo "$cur" | cut -d' ' -f1); b=$(echo "$cur" | cut -d' ' -f2)
            pm_num "$a" || a=105000; pm_num "$b" || b=60000
            if [ "$k" = "trip" ]; then
                [ "$v" -ge 85000 ] && [ "$v" -le 110000 ] || { echo "err:out_of_range"; exit 2; }
                a=$v
            else
                [ "$v" -ge 45000 ] && [ "$v" -le 75000 ] || { echo "err:out_of_range"; exit 2; }
                b=$v
            fi
            echo "$a $b" > "$PM_TRIP"; echo "ok:$a $b"; exit 0 ;;
        watchdog)
            pm_num "$v" || { echo "err:not_a_number"; exit 2; }
            [ "$v" -ge 60000 ] && [ "$v" -le 600000 ] || { echo "err:out_of_range"; exit 2; }
            settings put global watchdog_timeout_millis "$v" 2>/dev/null
            # settings(1) exits 0 even when the provider drops the write.
            got=$(settings get global watchdog_timeout_millis 2>/dev/null)
            [ "$got" = "$v" ] || { echo "err:readback_$got"; exit 3; }
            echo "ok:$v"; exit 0 ;;
        refresh)
            pm_num "$v" || { echo "err:not_a_number"; exit 2; }
            [ "$v" -ge 60 ] && [ "$v" -le 144 ] || { echo "err:out_of_range"; exit 2; }
            settings put secure user_refresh_rate "$v" 2>/dev/null
            settings put secure miui_refresh_rate "$v" 2>/dev/null
            got=$(settings get secure user_refresh_rate 2>/dev/null)
            [ "$got" = "$v" ] || { echo "err:readback_$got"; exit 3; }
            echo "ok:$v"; exit 0 ;;
        zones)
            # on  = the module takes over the compute zones (soft thermal
            #       throttling disabled, daemon still holds the ceiling)
            # off = hand the compute zones back to the kernel governor; apply
            #       re-enables every zone it had disabled.  Neither direction
            #       touches PM_OFF or restores frequencies -- this switch is
            #       only about who runs the soft thermal policy.
            case "$v" in
                on)  echo "module" > "$PM_ZONES"; sh "$MODDIR/tune.sh" apply >/dev/null 2>&1; echo "ok:on" ;;
                off) echo "kernel" > "$PM_ZONES"; sh "$MODDIR/tune.sh" apply >/dev/null 2>&1; echo "ok:off" ;;
                *)   echo "err:bad_value"; exit 2 ;;
            esac ; exit 0 ;;
    esac

    # The GPU ceiling lives in .gpu so the presets and the slider share one
    # source of truth; apply a fresh pass afterwards or the next `apply`
    # would put the value from before back.
    if [ "$k" = "gpu_lvl" ]; then
        # Same validation as the generic path: this branch only exists because
        # the write order differs, not to skip the checks.
        pm_num "$v" || { echo "err:not_a_number"; exit 2; }
        [ "$v" -ge 0 ] && [ "$v" -le 12 ] || { echo "err:out_of_range"; exit 2; }
        lvl=$(node_of gpu_lvl)
        # kgsl clamps max_pwrlevel to min_pwrlevel and still reports success, so
        # push the idle floor out of the way first -- exactly what apply.sh does.
        echo 12 > "$GPU/min_pwrlevel" 2>/dev/null
        pm_wr "$lvl" "$v" || { echo "err:write"; exit 3; }
        echo "$v" > "$PM_GPU"
        got=$(cat "$lvl" 2>/dev/null)
        [ "$got" = "$v" ] || { echo "warn:clamped:$got"; exit 0; }
        echo "ok:$v"; exit 0
    fi
    node=$(node_of "$k") || { echo "err:unknown_key"; exit 2; }
    pm_num "$v" || { echo "err:not_a_number"; exit 2; }
    set -- $(bounds "$k")
    lo=$1; hi=$2
    [ "$v" -ge "$lo" ] && [ "$v" -le "$hi" ] || { echo "err:out_of_range"; exit 2; }

    if echo "$v" > "$node" 2>/dev/null; then
        back=$(cat "$node" 2>/dev/null)
        if [ "$back" = "$v" ]; then echo "ok:$back"; else echo "warn:clamped:$back"; fi
    else
        echo "err:write_failed"; exit 3
    fi
}

cmd_toggle() {
    if [ -f "$PM_OFF" ]; then
        rm -f "$PM_OFF"
        r=$(sh "$MODDIR/tune.sh" apply 2>&1)
        pm_guard_start >/dev/null 2>&1
        echo "ok:on|$r"
    else
        touch "$PM_OFF"
        pm_guard_stop
        r=$(sh "$MODDIR/restore.sh" 2>&1)
        echo "ok:off|$r"
    fi
}

# Preset table passthrough: one row per preset, "k|name|cpu0|cpu6|gpu|ddr".
# The UI renders its preset buttons from this instead of a second copy of the
# numbers, so editing presets.txt changes every surface at once.
cmd_presets() {
    [ -f "$MODDIR/presets.txt" ] || { echo "err:no-table"; return 1; }
    grep -v '^#' "$MODDIR/presets.txt" | while IFS="$(printf '\t')" read -r k name c0 c6 gpu ddr rest; do
        echo "$k|$name|$c0|$c6|$gpu|$ddr"
    done
}

case "$1" in
    presets)  cmd_presets ;;
    snapshot) cmd_snapshot ;;
    set)      cmd_set "$2" "$3" ;;
    toggle)   cmd_toggle ;;
    apply)
        # The UI treats "ok:" as success; tune.sh's own output does not carry
        # it, and passing it through verbatim made the verdict chip report an
        # error after every successful re-assert.
        r=$(sh "$MODDIR/tune.sh" apply 2>&1)
        echo "ok:$r" ;;
    restore)
        # Same sequence as toggle-off: without stopping the guard first, it
        # would keep re-pinning full clocks over the freshly restored values
        # and "factory state" would never actually hold.
        touch "$PM_OFF"
        pm_guard_stop
        sh "$MODDIR/restore.sh" ;;
    *)        echo "usage: control.sh {snapshot|set <k> <v>|toggle|apply|restore}"; exit 1 ;;
esac
