#!/system/bin/sh
# PianoMax - late_start service
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.

# NoWait stage: this script must not block boot.  It waits for
# sys.boot_completed with a hard ceiling, applies once, then starts the
# supervisor and returns.

. "$(dirname "$0")/lib/common.sh"

[ -f "$PM_DIR/disable" ] && exit 0

i=0
while [ "$(getprop sys.boot_completed)" != "1" ]; do
    sleep 2
    i=$((i + 1))
    [ $i -gt 150 ] && { pm_log "boot wait gave up"; exit 0; }
done

sleep 8
[ -f "$PM_DIR/disable" ] && exit 0
[ -f "$PM_OFF" ] && { pm_log "service: switched off"; exit 0; }
[ "$(getprop ro.product.device)" = "piano" ] || exit 0

chmod 755 "$PM_DIR"/*.sh "$PM_DIR"/lib/*.sh 2>/dev/null
sh "$PM_DIR/tune.sh" apply >/dev/null 2>&1
pm_guard_start >/dev/null 2>&1
pm_log "service up, guard $(pm_guard_pid 2>/dev/null || echo down)"

# Magisk has no boot-completed stage, so the watchdog in that file only
# ever runs under KernelSU.  Start the same slow loop here for every
# manager: a guard killed by OOM or a crash comes back within five
# minutes instead of staying gone until the next reboot.  The guard.sh
# existence check is the uninstall latch -- the loop exits when the tree
# it watches is gone.
(
    while true; do
        sleep 300
        [ -f "$PM_DIR/guard.sh" ] || exit 0
        [ -f "$PM_DIR/disable" ] && exit 0
        [ -f "$PM_OFF" ] && continue
        if ! pm_guard_pid >/dev/null 2>&1; then
            pm_log "service watchdog: guard gone, restarting"
            pm_guard_start >/dev/null 2>&1
        fi
    done
) </dev/null >/dev/null 2>&1 &
