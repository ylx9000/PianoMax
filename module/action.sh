#!/system/bin/sh
# PianoMax - the button on the module card
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# KernelSU shows whatever this prints after the user taps the action button.
# Wide CJK glyphs cannot be aligned with an ASCII border, so the card is
# open on the right on purpose instead of pretending to be a box.

. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/apply.sh"

# The card button writes every node apply.sh knows; on a foreign device
# that is exactly what must not happen.
if [ "$(getprop ro.product.device)" != "piano" ]; then
    echo "PianoMax: unsupported device $(getprop ro.product.device)"
    exit 1
fi

card() {
    ver=$(grep -m1 '^version=' "$PM_DIR/module.prop" 2>/dev/null | cut -d= -f2)
    echo " ----------------------------------------"
    echo "  PianoMax $ver"
    echo ""
    echo "  $1"
    [ -n "$2" ] && { echo "  $2"; }
    echo ""
    mhz() { n=$(cat "$1" 2>/dev/null); pm_num "$n" && echo $((n / 1000)) || echo 0; }
    echo "  CPU   $(mhz "$CFG/policy0/scaling_cur_freq") / $(mhz "$CFG/policy6/scaling_cur_freq") MHz"
    echo "  GPU   $(pm_cat "$GPU/clock_mhz") MHz"
    echo "  总线  DDR $(mhz "$BUS/DDR/cur_freq") · LLCC $(mhz "$BUS/LLCC/cur_freq")"
    t1=$(pm_cat /sys/class/thermal/thermal_zone13/temp); pm_num "$t1" || t1=0
    t2=$(pm_cat /sys/class/thermal/thermal_zone23/temp); pm_num "$t2" || t2=0
    t3=$(pm_cat /sys/class/power_supply/battery/temp);   pm_num "$t3" || t3=0
    echo "  温度  CPU $((t1 / 1000))° GPU $((t2 / 1000))° 电池 $((t3 / 10))°"
    av=$(grep MemAvailable /proc/meminfo 2>/dev/null | tr -s ' ' | cut -d' ' -f2)
    pm_num "$av" && echo "  内存  $((av / 1024)) MB 可用"
    echo "  守护  $(pm_guard_pid >/dev/null 2>&1 && echo 运行中 || echo 已停止)"
    echo ""
    echo " ----------------------------------------"
}

if [ -f "$PM_OFF" ]; then
    rm -f "$PM_OFF"
    n=$(pm_apply_all)
    pm_guard_start >/dev/null 2>&1
    card "已开启" "全部参数已应用到设备"
else
    touch "$PM_OFF"
    pm_guard_stop
    sh "$PM_DIR/restore.sh" >/dev/null 2>&1
    card "已关闭" "全部参数已还原为出厂值"
fi
