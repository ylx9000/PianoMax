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
# verify loop; uninstall only needs the vendor bytes back in place.
#
# This used to copy the snapshot straight across.  That path bypassed the
# contamination checks pm_thermal_revert gained -- and uninstall is the worst
# possible place for a poisoned snapshot to win, because the module tree is
# about to be deleted and there is no later chance to fix it.  A device that
# last ran a pre-fix build still carries a .thermal_orig holding our own
# extreme table; copying it back would end the uninstall with the message
# "factory values restored" and our table in charge.  Reuse the checked path
# with no argument (pm_thermal_revert takes none) so the no-block rule survives (the revert's own comment
# explains why 2 is enough for the delete-right-after case).
#
# The immutable bit is cleared unconditionally, before that guard.  A KSU
# update replaces the module directory, which loses .thermal_captured and
# .thermal_orig while the previous build's table can still be sitting in
# T_DIR with +i on it.  The old order skipped the revert entirely in that
# case, and with the module gone nothing was left that could clear the bit --
# the vendor directory stayed locked against cloud control with no uninstall
# path to undo it.  One idempotent -i costs nothing on the paths where the
# directory is already writable.
chattr -R -i /data/vendor/thermal/config 2>/dev/null
if [ -d "$PM_DIR/.thermal_orig" ] && [ -n "$(ls "$PM_DIR/.thermal_orig" 2>/dev/null)" ]; then
    . "$PM_DIR/lib/thermal.sh"
    pm_thermal_revert 2
fi
sh "$PM_DIR/restore.sh" >/dev/null 2>&1
start mi_thermald 2>/dev/null
settings delete global watchdog_timeout_millis 2>/dev/null
rm -f "$PM_STATE" "$PM_STATE.tmp" "$PM_TARGET" "$PM_STAGE" "$PM_TRIP" \
      "$PM_GPU" "$PM_BUS" "$PM_ZONES" "$PM_PROFILE"
echo "PianoMax removed, factory values restored"
