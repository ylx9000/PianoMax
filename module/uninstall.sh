#!/system/bin/sh
# PianoMax - uninstall
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# ksu runs this with ScriptWait::Forever, so nothing here may block.  No
# loops that wait for a condition, no interactive reads.

. "$(dirname "$0")/lib/common.sh"

rm -f "$PM_OFF"
pm_guard_stop
# The boot-completed watchdog scans every five minutes and would restart
# nothing after this tree is gone, but its sleeping shell still lingers.
# Killing by cmdline is safe here: uninstall runs before the files vanish.
for p in /proc/[0-9]*; do
    c=$(tr '\000' ' ' < "$p/cmdline" 2>/dev/null) || continue
    case "$c" in
        *"$PM_DIR/boot-completed.sh"*) kill "${p##*/}" 2>/dev/null ;;
        *"$PM_DIR/service.sh"*) kill "${p##*/}" 2>/dev/null ;;
    esac
done
# restore.sh would run the full thermal revert including the daemon-reload
# verify loop; uninstall only needs the vendor bytes back in place.  Copy
# the snapshot directly and bounce the daemon once -- no polling, so the
# uninstaller never sits in a 10 s wait against its own no-block rule.
if [ -d "$PM_DIR/.thermal_orig" ] && [ -n "$(ls "$PM_DIR/.thermal_orig" 2>/dev/null)" ]; then
    . "$PM_DIR/lib/thermal.sh"
    chattr -R -i /data/vendor/thermal/config 2>/dev/null
    for f in "$PM_DIR/.thermal_orig"/*; do
        [ -f "$f" ] || continue
        cp "$f" /data/vendor/thermal/config/$(basename "$f")
    done
    # A table of ours the vendor never shipped must not survive either:
    # the snapshot names everything that was factory.
    for f in /data/vendor/thermal/config/*.conf; do
        [ -f "$f" ] || continue
        [ -f "$PM_DIR/.thermal_orig/$(basename "$f")" ] || rm -f "$f"
    done
    rm -f "$PM_DIR/.thermal_mode" "$PM_DIR/.thermal_captured"
    restorecon -DFR /data/vendor/thermal/config 2>/dev/null
    setprop ctl.restart mi_thermald 2>/dev/null
fi
sh "$PM_DIR/restore.sh" >/dev/null 2>&1
start mi_thermald 2>/dev/null
settings delete global watchdog_timeout_millis 2>/dev/null
rm -f "$PM_STATE" "$PM_STATE.tmp" "$PM_TARGET" "$PM_STAGE" "$PM_TRIP" \
      "$PM_GPU" "$PM_BUS" "$PM_ZONES" "$PM_PROFILE"
echo "PianoMax removed, factory values restored"
