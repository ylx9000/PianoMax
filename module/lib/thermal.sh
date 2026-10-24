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
# point sources it first).  The fallback covers a direct call: this file
# lives in lib/ next to common.sh, so the helper is a sibling, not a
# subdirectory -- "$0"'s own directory is already lib/.
[ -n "${PM_DIR:-}" ] || . "$(dirname "$0")/common.sh"

# Where the vendor daemon looks for overrides.  init creates this directory
# (0771, root:system) at post-fs-data; anything placed here outranks
# /vendor/etc.  Verified against the running daemon through decrypt.txt,
# which always names the table it loaded last.
T_DIR=/data/vendor/thermal/config
# Whether the immutable-bit tool exists at all.  Not every toybox build ships
# chattr/lsattr, and the module's own +i calls are all silenced with
# 2>/dev/null -- on a ROM without it the "cloud control cannot overwrite the
# table" guarantee would simply not exist while every log line still claimed
# it did.  Probed once here and reported by piano_diag.sh, so the claim is
# checkable from the device instead of assumed from the build.
PM_CHATTR=""
if command -v chattr >/dev/null 2>&1; then PM_CHATTR=1; fi
export PM_CHATTR
T_ROOT=/data/vendor/thermal
# Our encrypted variants live inside the module; the directory doubles as
# the marker that the feature is installed at all.
T_SRC="$PM_DIR/thermal"
T_STAMP="$PM_DIR/.thermal_mode"

# Is this file byte-identical to one of the module's own preset tables?
#
# The four call sites below used to answer with `grep -q "$h" module/thermal/*/*.conf`,
# which greps the hash STRING against the table's CONTENT.  A hex digest is not
# a substring of the ciphertext it describes, so the answer was always "no".
# Every one of those checks existed to stop the module mistaking its own table
# for a vendor table, and every one of them was dead: contaminated snapshots
# were captured, and "revert" would faithfully restore our own policy.  Compare
# digests on both sides instead -- one md5sum per candidate, same cost.
pm_is_own_table() {
    _pio=$1
    [ -f "$_pio" ] || return 1
    _pioh=$(md5sum "$_pio" 2>/dev/null | cut -d' ' -f1)
    [ -n "$_pioh" ] || return 1
    for _piot in "$T_SRC"/*/*.conf; do
        [ -f "$_piot" ] || continue
        [ "$(md5sum "$_piot" 2>/dev/null | cut -d' ' -f1)" = "$_pioh" ] && return 0
    done
    return 1
}

# Stat signature for reload detection: stat -c %Y is second-granular,
# so a daemon that rewrites decrypt.txt inside the same second as the
# restart still looks "unchanged" and verify reports a false negative.
# %y keeps nanoseconds; size catches any same-instant rewrite.
pm_stat_sig() {
    stat -c "%y:%s" "$1" 2>/dev/null
}

# The vendor's own table lives in /odm/etc, not in the writable override
# directory: /data/vendor/thermal/config is where overrides are *placed*, so
# whatever sits there may already be ours.  Capturing from the override
# directory alone is therefore circular -- on any boot after a swap it would
# snapshot our own table and call it the vendor's, and revert would then
# faithfully restore the thing it was supposed to undo.  That is exactly what
# happened before this comment existed: .thermal_orig held a copy of the
# extreme table (md5 76562364...) while the real vendor table (/odm/etc,
# 1e55b6a3...) was never touched.
#
# Order of preference, per file:
#   1. /odm/etc/<name>        -- the shipped table, immutable and always real
#   2. T_DIR/<name>           -- only when the ROM keeps it nowhere else
#   3. absent                 -- recorded as such so revert deletes our copy
T_VENDOR=/odm/etc

# One-time snapshot of every table the vendor shipped, encrypted and all.
# Without this the revert path is fiction, so the swap refuses to run until
# it has a capture from this boot.
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
    # Seed from the immutable vendor copy first, then fill in anything the
    # override directory has that /odm/etc does not ship.
    for f in "$T_VENDOR"/thermal*.conf; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        cp "$f" "$PM_DIR/.thermal_orig/$b" 2>/dev/null && n=$((n + 1))
    done
    for f in "$T_DIR"/*; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        # Already captured from the vendor tree: that copy is authoritative.
        [ -f "$PM_DIR/.thermal_orig/$b" ] && continue
        # Skip anything that is byte-identical to one of our own preset
        # tables -- that is not a vendor table, whatever directory it is in.
        if pm_is_own_table "$f"; then
            pm_log "thermal: skipped our own table in $b during capture"
            continue
        fi
        cp "$f" "$PM_DIR/.thermal_orig/$b" 2>/dev/null && n=$((n + 1))
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
    # Rival thermal tables from other modules shadow ours by mount order:
    # theirs lands later in the vendor config path and wins every daemon
    # reload, which reads back as "the preset stopped working" with nothing
    # in our own log.  A read-only sweep over the module tree right before
    # installing names the rival while there is still time to say so.  This
    # deliberately warns instead of refusing -- a preset switch must not be
    # hostage to some other module's files -- but the log line is the first
    # thing to check when a freshly stamped table changes nothing.
    for rival in /data/adb/modules/*/[Ss]ystem/vendor/thermal/config/*.conf \
                 /data/adb/modules/*/[Ss]ystem/vendor/etc/thermal*.conf; do
        [ -f "$rival" ] || continue
        case "$rival" in *"/pianomax/"*) continue ;; esac
        pm_log "thermal: rival table in $rival -- theirs may shadow ours (mount order)"
    done
    pm_thermal_capture || return 1
    # Cloud control (powerkeeper/joyose) rewrites this directory whenever it
    # feels like it.  An immutable bit survives even root writes; take it
    # off first or our own copies land half-way.
    chattr -R -i "$T_DIR" 2>/dev/null
    cp_ok=1
    for f in "$T_SRC/$mode"/*.conf; do
        [ -f "$f" ] || continue
        # An unchecked cp here installed an empty target on a failed copy and
        # the stamp below still recorded the mode -- the guard then trusted
        # TABLE_IN_CHARGE and stopped re-pinning on a table that was never
        # written.  Verify each copy byte-count before stamping.
        cp "$f" "$T_DIR/$(basename "$f")" || { cp_ok=0; break; }
        [ "$(wc -c < "$T_DIR/$(basename "$f")" 2>/dev/null)" = "$(wc -c < "$f")" ] || { cp_ok=0; break; }
        chmod 444 "$T_DIR/$(basename "$f")" 2>/dev/null
        chown root:system "$T_DIR/$(basename "$f")" 2>/dev/null
    done
    if [ "$cp_ok" != "1" ]; then
        # The old table is already half-overwritten at this point, so neither
        # "previous table" nor "new table" describes what is in T_DIR now.
        # Wipe the stamp as well: leaving it behind left the guard's table
        # gate reading a mode and an install time that belonged to a table
        # that is no longer whole, and it would hand the ceiling to a daemon
        # enforcing a half-copied policy.  No stamp means guard re-pins,
        # which is the safe state.
        rm -f "$T_STAMP" "$PM_DIR/.thermal_ts"
        pm_log "thermal: swap copy failed for $mode, stamp cleared -- guard keeps re-pinning"
        return 1
    fi
    restorecon -DFR "$T_DIR" 2>/dev/null
    # Policy vacuum is 1-2 s while the daemon re-reads; acceptable at preset
    # switch, and the guard re-pins the ceiling as soon as it is back.
    # The pre-restart mtime goes to verify: the daemon may rewrite
    # decrypt.txt within a second of the restart, before verify gets to
    # sample anything, and a same-value comparison would then read as
    # "never reloaded".
    t_before=$(pm_stat_sig "$T_ROOT/decrypt.txt")
    # Guard-side reference point: everything the daemon writes to decrypt.txt
    # from this moment on must carry an mtime at or after this second.  The
    # stamp itself gets written after verify, so comparing stamp-mtime against
    # decrypt-mtime directly would read backwards (the daemon rewrites decrypt
    # BEFORE the stamp lands) and disqualify healthy tables.
    date +%s > "$PM_DIR/.thermal_ts" 2>/dev/null
    setprop ctl.restart mi_thermald 2>/dev/null || { stop mi_thermald 2>/dev/null; start mi_thermald 2>/dev/null; }
    # The stamp goes down only after the daemon proves it re-read: a stamp
    # written earlier turned the guard's table gate into a lie whenever the
    # restart was swallowed or the load rejected, and the ceiling then lost
    # its keeper until the next preset switch.  On a failed verify the stamp
    # stays off and the guard keeps re-pinning -- the old behaviour, never
    # the worse one.
    if pm_thermal_verify "$mode" "$t_before"; then
        echo "$mode" > "$T_STAMP"
    else
        rm -f "$T_STAMP"
        pm_log "thermal: verify failed, stamp withheld -- guard keeps re-pinning"
    fi
    # Pin the override directory immutable: joyose/powerkeeper rewrite T_DIR
    # "whenever it feels like it" (its own comment in this file), and a cloud
    # overwrite here silently reverted the preset table while the stamp kept
    # claiming otherwise.  Revert and uninstall already clear the bit first.
    chattr -R +i "$T_DIR" 2>/dev/null
}

# Put the vendor's own tables back.  Used by restore.sh and uninstall.
pm_thermal_revert() {
    # Unconditional unlock, before anything else.  The early returns below
    # (missing snapshot) previously skipped it, which mattered after a module
    # update that lost .thermal_captured while the preset table still carried
    # +i: vendor bytes and cloud control alike then bounced off the immutable
    # directory with nothing left in the module tree able to clear it.
    chattr -R -i "$T_DIR" 2>/dev/null
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
            if pm_is_own_table "$f"; then
                rm -f "$f"
                pm_log "thermal: removed our pinned table $(basename "$f")"
            fi
        done
        pm_log "thermal: revert refused, vendor snapshot missing or empty"
        return 1
    fi
    chattr -R -i "$T_DIR" 2>/dev/null
    # A snapshot entry that is byte-identical to one of our own preset tables
    # is contamination from before this check existed, not a vendor table.
    # Restoring it would put our policy back and call it a revert, so it is
    # dropped here and the file is removed from T_DIR below instead.
    _restored=0
    for f in "$PM_DIR/.thermal_orig"/*; do
        [ -f "$f" ] || continue
        b=$(basename "$f")
        if pm_is_own_table "$f"; then
            pm_log "thermal: dropping contaminated snapshot entry $b"
            rm -f "$f"
            continue
        fi
        cp "$f" "$T_DIR/$b"
        chmod 444 "$T_DIR/$b" 2>/dev/null
        chown root:system "$T_DIR/$b" 2>/dev/null
        _restored=$((_restored + 1))
    done
    # If the vendor tree still has the real table, put it back directly --
    # that is the recovery path for an already-poisoned snapshot.
    if [ "$_restored" -eq 0 ]; then
        for f in "$T_VENDOR"/thermal*.conf; do
            [ -f "$f" ] || continue
            b=$(basename "$f")
            cp "$f" "$T_DIR/$b" 2>/dev/null || continue
            chmod 444 "$T_DIR/$b" 2>/dev/null
            chown root:system "$T_DIR/$b" 2>/dev/null
            _restored=$((_restored + 1))
        done
        [ "$_restored" -gt 0 ] && pm_log "thermal: recovered $_restored table(s) from $T_VENDOR"
    fi
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
    # .thermal_ts goes with the stamp.  Leaving it behind is harmless for the
    # gate (which requires both) but it survives into the next boot as a
    # timestamp that refers to no installed table, and the next swap would
    # write a fresh one anyway -- a stale file whose only effect is to make
    # "re-pin mode" look like it once had a table.
    rm -f "$T_STAMP" "$PM_DIR/.thermal_ts"
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
    # Poll in 0.25 s steps instead of sleeping a second per round: the
    # daemon usually rewrites decrypt.txt within ~1-2 s of the restart, so
    # the common case returns in a quarter of the old wall time and the
    # worst case is unchanged (polls * 0.25 s).  read -t is the portable
    # sub-second sleep on mksh; verified on this box (rc=1 on timeout).
    # No decrypt.txt at all: the ROM either moved it or never exposes it.
    # There is nothing to watch, so the swap is accepted on faith and the
    # guard remains the safety net.
    [ -f "$T_ROOT/decrypt.txt" ] || { pm_log "thermal: no decrypt.txt, swap accepted unverified"; return 0; }
    i=0
    while [ "$i" -lt $((polls * 4)) ]; do
        # mksh read -t needs an fd that can BLOCK.  /dev/null is always EOF
        # (rc=0, instantly) so the whole loop burned through 40 polls in ~3 ms
        # and never observed a reload that lands 1-2 s after the restart --
        # every "no reload detected" was an artifact (FIFO-verified
        # 2026-10-22).  sleep 0.25 is a real sub-second wait on toybox.
        sleep 0.25
        after=$(pm_stat_sig "$T_ROOT/decrypt.txt")
        if [ -n "$after" ] && [ "$after" != "$before" ]; then
            pm_log "thermal: daemon reloaded (table $mode stamped, after $((i + 1)) polls)"
            return 0
        fi
        i=$((i + 1))
    done
    pm_log "thermal: no reload detected after restart ($mode stamped, waited $((polls))s)"
    return 1
}

# Deployment note (device-verified 2026-10-21): the file copied into
# T_DIR must carry its scenario name (thermal-normal.conf), not the map name.
# A stray thermal-map.conf in T_DIR makes the daemon reject its load and
# run with an empty table (decrypt.txt goes 0 bytes) until it is removed.
