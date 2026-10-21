#!/system/bin/sh
# PianoMax - apply / restore / status entry point
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.

. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/apply.sh"

DEV=$(getprop ro.product.device)

case "$1" in
    apply)
        [ "$DEV" = "piano" ] || { echo "unsupported device: $DEV"; exit 1; }
        if [ -f "$PM_OFF" ]; then echo "switched off"; exit 0; fi
        n=$(pm_apply_all)
        # The daemon is what keeps the ceiling in place; without it the module
        # looks applied for about two seconds and then drifts back down.
        pm_guard_start >/dev/null 2>&1
        echo "apply done, failures:$n, guard:$(pm_guard_pid 2>/dev/null || echo down)"
        ;;
    restore)
        # Same sequence as toggle-off: the guard would re-pin full clocks
        # over the restored values within one tick, so restore without
        # stopping it first never actually holds.
        touch "$PM_OFF"
        pm_guard_stop
        sh "$(dirname "$0")/restore.sh" ;;
    status)   sh "$(dirname "$0")/status.sh" ;;
    snapshot) sh "$(dirname "$0")/status.sh" --snapshot ;;
    *)        echo "usage: tune.sh {apply|restore|status|snapshot}"; exit 1 ;;
esac
