#!/system/bin/sh
# PianoMax - cold boot GPU window
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.

# Runs before zygote.  This is the only moment in the boot where the GPU
# frequency ladder still contains the 1100 MHz rung: thermal_pwrlevel is 0
# until something latches it, and once latched the ladder shrinks with it
# (tp=4 leaves 832 MHz as the top rung, not 1050).  Two seconds of head
# start is worth more than any amount of userspace fighting later.

. "$(dirname "$0")/lib/common.sh"
PM_COMP=boot   # log v2: RFC5424 APP-NAME equivalent, one per entry script

[ -f "$PM_DIR/disable" ] && exit 0
[ -f "$PM_OFF" ] && exit 0
[ "$(getprop ro.product.device)" = "piano" ] || exit 0
[ -d "$GPU" ] || exit 0

tp=$(pm_cat "$GPU/thermal_pwrlevel")
pm_logd "gpu_prewarm: tp=$tp"

if [ "$tp" != "0" ]; then
    echo 0 > "$GPU/thermal_pwrlevel" 2>/dev/null
    sleep 1
    tp=$(pm_cat "$GPU/thermal_pwrlevel")
fi

if [ "$tp" = "0" ]; then
    echo 0 > "$GPU/max_pwrlevel" 2>/dev/null
    # Deliberately NOT min_pwrlevel=0: pinning the idle floor to the top rung
    # holds the GPU at 1100 MHz until service.sh runs -- minutes, not the
    # "two seconds" the old comment claimed.  max_pwrlevel=0 only opens the
    # ceiling; the devfreq governor still idles the GPU at its own floor.
    pm_logn "gpu_ladder: opened (all rungs exposed)"
else
    pm_logd "gpu_prewarm: tp already latched at $tp"
fi