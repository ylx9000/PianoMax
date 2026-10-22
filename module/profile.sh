#!/system/bin/sh
# PianoMax - the four presets
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
#   sh profile.sh                  print the current preset
#   sh profile.sh list             list all four with their values
#   sh profile.sh <name>           switch to a preset and apply it
#
# A preset is only a bundle of values.  It writes the same files the sliders
# write, so switching to a preset and then dragging a slider behaves exactly
# like editing a slider after a fresh install -- no hidden second state.
#
# The keys are powersave / balanced / performance / extreme.

. "$(dirname "$0")/lib/common.sh"

# Snap an arbitrary number to the nearest step the kernel actually offers.
# Frequencies outside the ladder are accepted by sysfs and silently rounded, so
# the UI would show a value the module never asked for.
snap() {
    dir=$1; want=$2
    best=""; bestd=999999999
    for f in $(cat "$dir/scaling_available_frequencies" 2>/dev/null); do
        d=$((f > want ? f - want : want - f))
        if [ "$d" -lt "$bestd" ]; then bestd=$d; best=$f; fi
    done
    [ -n "$best" ] && echo "$best" || echo "$want"
}

snap_bus() {
    dir=$1; want=$2
    best=""; bestd=999999999
    for f in $(cat "$dir/available_frequencies" 2>/dev/null); do
        d=$((f > want ? f - want : want - f))
        if [ "$d" -lt "$bestd" ]; then bestd=$d; best=$f; fi
    done
    [ -n "$best" ] && echo "$best" || echo "$want"
}

# name | cpu0 | cpu6 | gpu_max_pwrlevel | ddr | llcc | trip_compute | trip_skin | zones
# Values live in presets.txt so the shell, the WebUI and the build all read
# one table.  The case below is the built-in copy used only when that file is
# missing from a broken install; keeping it in sync is a manual step; build.mjs does not compare them.
preset_line() {
    if [ -f "$PM_DIR/presets.txt" ]; then
        line=$(grep "^$1	" "$PM_DIR/presets.txt" 2>/dev/null | head -n 1)
        [ -n "$line" ] && { echo "$line" | cut -f2-10; return 0; }
    fi
    case "$1" in
        powersave)   echo "省电 1555200 1958400 10 1353000  533000  90000  50000 kernel" ;;
        balanced)    echo "均衡 2400000 2841600  6 3187000  933000 100000  55000 module" ;;
        performance) echo "性能 3072000 3513600  4 4224000 1066000 105000  62000 module" ;;
        extreme)     echo "极限 3532800 4320000  0 4761000 1211000 105000  75000 module" ;;
        *) return 1 ;;
    esac
}

canon_key() {
    case "$1" in
        powersave)   echo powersave ;;
        balanced)    echo balanced ;;
        performance) echo performance ;;
        extreme)     echo extreme ;;
        *)           return 1 ;;
    esac
}

show() {
    n=$(pm_profile_name)
    # .profile stores the display name; anything unrecognized falls back to
    # the default preset.
    case "$n" in
        省电) k=powersave ;; 均衡) k=balanced ;; 性能) k=performance ;; 极限) k=extreme ;;
        *) k=extreme ;;
    esac
    set -- $(preset_line "$k")
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
}

# Device gate before any state write: a preset switch stores .target/.trip
# etc. first, and on a foreign device those files would be dirty leftovers.
[ "$(getprop ro.product.device)" = "piano" ] || { echo "unsupported device: $(getprop ro.product.device)"; exit 1; }

case "$1" in
    "")
        show
        ;;
    list)
        for k in powersave balanced performance extreme; do
            set -- $(preset_line "$k")
            a=$(snap "$CFG/policy0" "$2")
            b=$(snap "$CFG/policy6" "$3")
            d=$(snap_bus "$BUS/DDR" "$5")
            l=$(snap_bus "$BUS/LLCC" "$6")
            echo "$k|$1|$a|$b|$4|$d|$l|$7|$8|$9"
        done
        ;;
    *)
        k=$(canon_key "$1") || { echo "usage: profile.sh [list|powersave|balanced|performance|extreme]"; exit 1; }
        set -- $(preset_line "$k")
        name=$1; c0=$2; c6=$3; gl=$4; ddr=$5; llcc=$6; tc=$7; ts=$8; zn=$9

        # Snap every frequency onto a real ladder entry before writing it.
        c0=$(snap "$CFG/policy0" "$c0")
        c6=$(snap "$CFG/policy6" "$c6")
        ddr=$(snap_bus "$BUS/DDR" "$ddr")
        llcc=$(snap_bus "$BUS/LLCC" "$llcc")

        echo "$name" > "$PM_PROFILE"
        echo "$c0 $c6" > "$PM_TARGET"
        echo "$tc $ts" > "$PM_TRIP"
        # One number: the kgsl performance level, 0 = 1100 MHz, higher = lower cap.
        echo "$gl" > "$PM_GPU"
        echo "$ddr $llcc" > "$PM_BUS"
        echo "$zn" > "$PM_ZONES"
        # Presets that own their zones ship a thermal table: the daemon then
        # enforces our ceiling itself and the guard stops fighting it.  The
        # kernel-zones preset (省电) keeps the vendor table -- its value is
        # letting the kernel handle silicon safety undisturbed.
        if [ "$zn" = "module" ] && [ -d "$PM_DIR/thermal/$k" ]; then
            . "$PM_DIR/lib/thermal.sh"
            pm_thermal_swap "$k" || pm_log "profile: thermal swap failed for $k (continuing with re-pin)"
        else
            . "$PM_DIR/lib/thermal.sh"
            pm_thermal_revert
        fi
        # A preset is a fresh start: a thermal back-off recorded under the preset
        # you are leaving is meaningless at the new clock ceiling.
        rm -f "$PM_STAGE"

        sh "$PM_DIR/tune.sh" apply
        echo "ok:$name $c0/$c6 gpu$gl ddr$ddr llcc$llcc trip$tc/$ts $zn"
        ;;
esac
