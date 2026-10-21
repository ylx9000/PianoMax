#!/system/bin/sh
# PianoMax - thermal policy table manager
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# mi_thermald reads an encrypted policy table once at start and applies it
# forever after.  Fighting that daemon with per-second sysfs writes loses by
# construction: it re-writes the same nodes from its own table.  This file
# replaces the table instead: capture what shipped, install a per-preset
# variant, and put the original back on restore.  The daemon then does our
# job for us.

# common.sh is normally already loaded by whoever called us (every entry
# point sources it first).  The fallback covers a direct call from the
# module root: this file lives in lib/, so the shared helpers are one
# directory down from $0.
[ -n "${PM_DIR:-}" ] || . "$(dirname "$0")/lib/common.sh"

# Where the vendor daemon looks for overrides.  init creates this directory
# (0771, root:system) at post-fs-data; anything placed here outranks
# /vendor/etc.  Verified against the running daemon through decrypt.txt,
# which always names the table it loaded last.
T_DIR=/data/vendor/thermal/config
T_ROOT=/data/vendor/thermal
# Our encrypted variants live inside the module; the directory doubles as
# the marker that the feature is installed at all.
T_SRC="$PM_DIR/thermal"
T_STAMP="$PM_DIR/.thermal_mode"

# One-time snapshot of every table the vendor shipped, encrypted and all.
# Without this the revert path is fiction, so the swap refuses to run until
# it has a capture from this boot.
# Stat signature for reload detection: stat -c %Y is second-granular,
# so a daemon that rewrites decrypt.txt inside the same second as the
# restart still looks "unchanged" and verify reports a false negative.
# %y keeps nanoseconds; size catches any same-instant rewrite.
pm_stat_sig() {
    stat -c "%y:%s" "$1" 2>/dev/null
}

pm_thermal_capture() {
    [ -d "$T_DIR" ] || { pm_log "thermal: no config dir, table swap unavailable"; return 1; }
    # A marker without a populated snapshot is worse than no marker: the
    # early return would bless an empty capture, and revert would then
    # refuse forever while our table sits in T_DIR with the immutable bit
    # set.  The marker only counts when the snapshot directory is real;
    # an empty boot-time T_DIR (daemon not started yet) re-captures.
    if [ -f "$PM_DIR/.thermal_captured" ]; then
        [ -d "$PM_DIR/.thermal_orig" ] && [ -n "$(ls "$PM_DIR/.thermal_orig" 2>/dev/null)" ] && return 0
        rm -f "$PM_DIR/.thermal_captured"
    fi
    mkdir -p "$PM_DIR/.thermal_orig" || return 1
    n=0
    for f in "$T_DIR"/*; do
        [ -f "$f" ] || continue
        cp "$f" "$PM_DIR/.thermal_orig/$(basename "$f")" 2>/dev/null && n=$((n + 1))
    done
    # Permissions and context belong to the snapshot too: a restore that
    # brings back content but loses ownership would leave the daemon
    # reading a table it cannot trust.
    chown -R root:system "$PM_DIR/.thermal_orig" 2>/dev/null
    chmod -R 660 "$PM_DIR/.thermal_orig" 2>/dev/null
    # Marker after the emptiness check: a capture of nothing must not
    # poison every later swap on this boot.
    [ "$n" -gt 0 ] || { pm_log "thermal: nothing to capture yet, will retry"; return 1; }
    echo "$n" > "$PM_DIR/.thermal_captured"
    pm_log "thermal: captured $n vendor tables"
    return 0
}

# Install the preset variant.  Files come pre-encrypted in the module tree
# (the daemon accepts nothing else), so this is a copy, a stamp and a daemon
# bounce -- the bounce is what makes the daemon re-read; nothing watches
# these files for changes.
pm_thermal_swap() {
    mode=$1
    [ -d "$T_SRC/$mode" ] || { pm_log "thermal: no table for $mode"; return 1; }
    pm_thermal_capture || return 1
    # Cloud control (powerkeeper/joyose) rewrites this directory whenever it
    # feels like it.  An immutable bit survives even root writes; take it
    # off first or our own copies land half-way.
    chattr -R -i "$T_DIR" 2>/dev/null
    for f in "$T_SRC/$mode"/*.conf; do
        [ -f "$f" ] || continue
        cp "$f" "$T_DIR/$(basename "$f")"
        chmod 444 "$T_DIR/$(basename "$f")" 2>/dev/null
        chown root:system "$T_DIR/$(basename "$f")" 2>/dev/null
    done
    echo "$mode" > "$T_STAMP"
    # Re-arm immutability after our own writes so the cloud cannot eat the
    # table ten minutes later.
    chattr +i "$T_DIR"/*.conf 2>/dev/null
    restorecon -DFR "$T_DIR" 2>/dev/null
    # Policy vacuum is 1-2 s while the daemon re-reads; acceptable at preset
    # switch, and the guard re-pins the ceiling as soon as it is back.
    # The pre-restart mtime goes to verify: the daemon may rewrite
    # decrypt.txt within a second of the restart, before verify gets to
    # sample anything, and a same-value comparison would then read as
    # "never reloaded".
    t_before=$(pm_stat_sig "$T_ROOT/decrypt.txt")
    setprop ctl.restart mi_thermald 2>/dev/null || { stop mi_thermald 2>/dev/null; start mi_thermald 2>/dev/null; }
    pm_thermal_verify "$mode" "$t_before"
}

# Put the vendor's own tables back.  Used by restore.sh and uninstall.
pm_thermal_revert() {
    [ -f "$PM_DIR/.thermal_captured" ] || return 0
    # The snapshot is the only proof of what "vendor" means.  A capture with
    # an empty or missing directory cannot restore anything: refuse, keep the
    # marker, and say so -- otherwise this path returns success forever while
    # our preset table stays in charge.
    if [ ! -d "$PM_DIR/.thermal_orig" ] || [ -z "$(ls "$PM_DIR/.thermal_orig" 2>/dev/null)" ]; then
        # Clear the immutable bit even on refusal: an uninstall must never
        # leave our table pinned in the vendor directory where neither the
        # user nor cloud control could replace it.
        chattr -R -i "$T_DIR" 2>/dev/null
        for f in "$T_DIR"/*.conf; do
            [ -f "$f" ] || continue
            h=$(md5sum "$f" | cut -d' ' -f1)
            if grep -q "$h" "$PM_DIR"/thermal/*/*.conf 2>/dev/null; then
                rm -f "$f"
                pm_log "thermal: removed our pinned table $(basename "$f")"
            fi
        done
        pm_log "thermal: revert refused, vendor snapshot missing or empty"
        return 1
    fi
    chattr -R -i "$T_DIR" 2>/dev/null
    for f in "$PM_DIR/.thermal_orig"/*; do
        [ -f "$f" ] || continue
        cp "$f" "$T_DIR/$(basename "$f")"
        chmod 444 "$T_DIR/$(basename "$f")" 2>/dev/null
        chown root:system "$T_DIR/$(basename "$f")" 2>/dev/null
    done
    # A preset conf the vendor never shipped is not in the snapshot: removing
    # the snapshot files alone would leave it behind, and the daemon would
    # keep reading our policy after a "restore".  Delete every table that the
    # snapshot does not name.
    for f in "$T_DIR"/*.conf; do
        [ -f "$f" ] || continue
        [ -f "$PM_DIR/.thermal_orig/$(basename "$f")" ] || {
            rm -f "$f"
            pm_log "thermal: removed non-vendor table $(basename "$f")"
        }
    done
    rm -f "$T_STAMP"
    restorecon -DFR "$T_DIR" 2>/dev/null
    tb=$(pm_stat_sig "$T_ROOT/decrypt.txt")
    setprop ctl.restart mi_thermald 2>/dev/null || { stop mi_thermald 2>/dev/null; start mi_thermald 2>/dev/null; }
    rm -f "$PM_DIR/.thermal_captured"
    # Same reload check as swap: the restore is only real once the daemon
    # re-read.  Failure here is logged, never fatal -- the vendor tables are
    # physically back in place either way.
    # Short poll on revert: the vendor tables are physically back either
    # way, and uninstall must not sit here for the full 10 s window.
    pm_thermal_verify vendor "$tb" 2 || true
    pm_log "thermal: vendor tables restored"
}

# Trust, but verify: decrypt.txt carries the plaintext of whatever the
# daemon loaded last, and its mtime moves on every reload.  File content
# cannot name our preset (the table is sensor data, not labels), so the
# checkable claim is "the daemon re-read something after our restart" --
# plus the stamp recording what we believe it read.  If the daemon ignored
# our table anyway, the guard's re-pin loop keeps the old behavior: a
# failed swap degrades to today's mechanics, never to something worse.
pm_thermal_verify() {
    mode=$1; before=$2; polls=${3:-10}
    # No decrypt.txt at all: the ROM either moved it or never exposes it.
    # There is nothing to watch, so the swap is accepted on faith and the
    # guard remains the safety net.
    [ -f "$T_ROOT/decrypt.txt" ] || { pm_log "thermal: no decrypt.txt, swap accepted unverified"; return 0; }
    i=0
    while [ "$i" -lt "$polls" ]; do
        sleep 1
        after=$(pm_stat_sig "$T_ROOT/decrypt.txt")
        if [ -n "$after" ] && [ "$after" != "$before" ]; then
            pm_log "thermal: daemon reloaded (table $mode stamped)"
            return 0
        fi
        i=$((i + 1))
    done
    pm_log "thermal: no reload detected after restart ($mode stamped)"
    return 1
}

# Deployment note (device-verified 2026-10-21): the file copied into
# T_DIR must carry its scenario name (thermal-normal.conf), not the map name.
# A stray thermal-map.conf in T_DIR makes the daemon reject its load and
# run with an empty table (decrypt.txt goes 0 bytes) until it is removed.
