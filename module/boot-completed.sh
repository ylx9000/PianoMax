#!/system/bin/sh
# PianoMax - post-boot watchdog of last resort
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# KernelSU runs this with NoWait after boot completes.  Its only job is to
# notice that the supervisor is gone and put it back.  Without this file a
# daemon that died -- crash, OOM kill, a trip it never recovered from --
# stays gone until the next reboot, and every reading the UI shows is a
# stale snapshot from the moment it died.

. "$(dirname "$0")/lib/common.sh"
PM_COMP=boot   # log v2: RFC5424 APP-NAME equivalent, one per entry script

[ -f "$PM_DIR/disable" ] && exit 0
[ -f "$PM_OFF" ] && exit 0

sleep 30
pm_logd "boot_completed: check"

if ! pm_guard_pid >/dev/null 2>&1; then
    pm_logw "boot_completed: guard missing, restarting"
    pm_guard_start >/dev/null 2>&1
fi

# Keep watching in the background at a slow cadence.  A fast loop here would
# duplicate guard.sh's own work; one check every five minutes is enough to
# turn an unrecoverable state into a five-minute blip.
(
    while true; do
        sleep 300
        # Uninstall removes the tree while this loop sleeps; a watcher that
        # outlives its module is a zombie writing nothing but still costing
        # a wakeup every five minutes.  Exit the moment the scripts are gone.
        [ -f "$PM_DIR/guard.sh" ] || exit 0
        [ -f "$PM_DIR/disable" ] && exit 0
        [ -f "$PM_OFF" ] && continue
        if ! pm_guard_pid >/dev/null 2>&1; then
            pm_logw "watchdog: guard gone, restarting"
            pm_guard_start >/dev/null 2>&1
        fi
    done
) </dev/null >/dev/null 2>&1 &

exit 0