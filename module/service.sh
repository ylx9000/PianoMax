#!/system/bin/sh
# PianoMax - late_start service
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.

# NoWait stage: this script must not block boot.  It waits for
# sys.boot_completed with a hard ceiling, applies once, then starts the
# supervisor and returns.

. "$(dirname "$0")/lib/common.sh"
PM_COMP=service   # log v2: RFC5424 APP-NAME equivalent, one per entry script

[ -f "$PM_DIR/disable" ] && exit 0

i=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
    i=$((i + 1))
    [ $i -gt 150 ] && { pm_logw "boot_wait: gave up after 150 rounds"; exit 0; }
done

sleep 8
[ -f "$PM_DIR/disable" ] && exit 0
[ -f "$PM_OFF" ] && { pm_logn "off: module switched off, service exiting"; exit 0; }
[ "$(getprop ro.product.device)" = "piano" ] || exit 0

chmod 755 "$PM_DIR"/*.sh "$PM_DIR"/lib/*.sh 2>/dev/null
sh "$PM_DIR/tune.sh" apply >/dev/null 2>&1
pm_guard_start >/dev/null 2>&1
pm_logn "up: guard=$(pm_guard_pid 2>/dev/null || echo down)"

# Magisk has no boot-completed stage, so the watchdog in that file only
# ever runs under KernelSU.  Start the same slow loop here for every
# manager: a guard killed by OOM or a crash comes back within five
# minutes instead of staying gone until the next reboot.  The guard.sh
# existence check is the uninstall latch -- the loop exits when the tree
# it watches is gone.
#
# KernelSU runs both this file and boot-completed.sh, so on KSU the two
# loops were identical twins waking every five minutes to race for the same
# guard.  pm_guard_start holds a lock, so the second one was harmless -- but
# it was two extra forks and a wakeup per five minutes doing nothing, and
# two places to fix the day this logic changes.  KSU keeps the
# boot-completed loop (it also covers the window before this file runs);
# every other manager keeps this one.
if [ -d /data/adb/ksu ] && [ -f "$PM_DIR/boot-completed.sh" ]; then
    pm_logd "watchdog: boot-completed.sh owns the loop on KernelSU"
else
(
    while true; do
        sleep 300
        [ -f "$PM_DIR/guard.sh" ] || exit 0
        [ -f "$PM_DIR/disable" ] && exit 0
        [ -f "$PM_OFF" ] && continue
        if ! pm_guard_pid >/dev/null 2>&1; then
            pm_logw "watchdog: guard gone, restarting"
            pm_guard_start >/dev/null 2>&1
        fi
    done
) </dev/null >/dev/null 2>&1 &
fi