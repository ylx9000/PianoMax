#!/system/bin/sh
# PianoMax - configuration export
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# Packs the live configuration into a module-flashable zip.  A store-only
# zip is three fixed record layouts from PKWARE APPNOTE.TXT section V;
# sizes and the per-member CRC-32 are the only variable parts.  The CRC
# needs bitwise xor: toybox awk has none, the manager bundled busybox awk
# does (verified on-device against a reference implementation).  Probe
# before use; probe failure degrades to a plain kv text file, never dies.

# common.sh is normally already loaded by the caller.  The fallback walks
# up from this file (lib/ inside the module) until module.prop shows up,
# mirroring common.sh's own root-finding.
if [ -z "${PM_DIR:-}" ] || [ ! -f "$PM_DIR/module.prop" ]; then
    PM_DIR=$(dirname "$0")
    i=0
    while [ "$i" -lt 4 ] && [ ! -f "$PM_DIR/module.prop" ]; do
        PM_DIR=$(dirname "$PM_DIR")
        i=$((i + 1))
    done
    . "$PM_DIR/lib/common.sh"
fi

# The gate probes the same applet pm_crc32 uses, so "zip possible" and
# "CRC computable" can never disagree.  An earlier version probed bitwise
# awk here while pm_crc32 only needed the crc32 applet: on a box with awk
# but no crc32 the gate passed, every member then got CRC 0, and the zip
# only died in the self-check -- safe, but the gate was testing the wrong
# thing and the awk path itself was dead code (nothing ever called it).
pm_crc32_available() {
    for a in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox busybox; do
        if "$a" crc32 /data/adb/modules/pianomax/module.prop >/dev/null 2>&1; then return 0; fi
    done
    if busybox crc32 /data/adb/modules/pianomax/module.prop >/dev/null 2>&1; then return 0; fi
    return 1
}

# CRC-32 over the file named by $1.  The manager bundled busybox ships a
# crc32 applet whose output is the zip polynomial (reflected IEEE 0xEDB88320,
# hex, no padding quirks); both busybox builds on this device returned
# byte-identical values to a reference implementation.
pm_crc32() {
    for a in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox busybox; do
        if "$a" crc32 "$1" >/dev/null 2>&1; then "$a" crc32 "$1" | awk '{print $1}'; return 0; fi
    done
    return 1
}

u16() { printf "\x$(printf %02x $(( $1 & 255)))\x$(printf %02x $(( ($1 >> 8) & 255)))"; }
u32() { printf "\x$(printf %02x $(( $1 & 255)))\x$(printf %02x $(( ($1 >> 8) & 255)))\x$(printf %02x $(( ($1 >> 16) & 255)))\x$(printf %02x $(( ($1 >> 24) & 255)))"; }

# Append one stored member.  Local header, name, raw bytes, then an index
# line for the central directory pass.
zip_member() {
    zname="$1"; zsrc="$2"; zout="$3"; zidx="$4"
    # APPNOTE: the central directory carries each member's offset from the
    # start of the file.  Writing a constant 0 here made every entry point
    # at member one -- strict unpackers then fail members two and three,
    # and the one-pass self-check validated the same first member three
    # times without noticing.
    off=$(wc -c < "$zout")
    sz=$(wc -c < "$zsrc")
    crc=$(pm_crc32 "$zsrc")
    nl=${#zname}
    {
        u32 0x04034b50; u16 20; u16 0; u16 0
        u16 0; u16 0
        u32 "0x$crc"; u32 "$sz"; u32 "$sz"
        u16 "$nl"; u16 0
        printf '%s' "$zname"
        cat "$zsrc"
    } >> "$zout"
    echo "$off $crc $sz $nl $zname" >> "$zidx"
}

pm_export_run() {
    out="$PM_DIR/exports"
    mkdir -p "$out" || return 1
    name="pianomax-config-$(date +%Y%m%d-%H%M%S)"
    kv="$out/$name.txt"
    {
        echo "# PianoMax configuration export"
        echo "# the module's intent (state files + preset table), not a live"
        echo "# kernel readback -- for what the kernel is actually enforcing"
        echo "# right now, run status.sh full"
        echo "profile=$(pm_profile_name)"
        echo "target=$(cat "$PM_TARGET" 2>/dev/null)"
        echo "trip=$(cat "$PM_TRIP" 2>/dev/null)"
        echo "gpu=$(cat "$PM_GPU" 2>/dev/null)"
        echo "bus=$(cat "$PM_BUS" 2>/dev/null)"
        echo "zones=$(cat "$PM_ZONES" 2>/dev/null)"
        echo "thermal_mode=$(cat "$PM_DIR/.thermal_mode" 2>/dev/null)"
        echo ""
        sh "$PM_DIR/profile.sh" list
    } > "$kv" 2>/dev/null
    echo "export: $kv"

    pm_crc32_available || { pm_log "export: no crc32 applet, kv text only"; return 2; }
    zip="$out/$name.zip"
    idx="$out/.idx"
    : > "$zip"; : > "$idx"
    zip_member "module.prop" "$PM_DIR/module.prop" "$zip" "$idx"
    zip_member "presets.txt" "$PM_DIR/presets.txt" "$zip" "$idx"
    zip_member "config.txt" "$kv" "$zip" "$idx"
    cd_start=$(wc -c < "$zip")
    while read -r off crc sz nl zname; do
        {
            u32 0x02014b50; u16 20; u16 20; u16 0; u16 0
            u16 0; u16 0
            u32 "0x$crc"; u32 "$sz"; u32 "$sz"
            u16 "$nl"; u16 0; u16 0; u16 0; u16 0
            # Field order after the name length cluster: a 4-byte external
            # attributes word FIRST, then the local-header offset.  wc -c
            # counts in decimal and u32 evaluates arithmetic, so no 0x
            # prefix here either -- 636 must enter as 636, not 0x636.
            u32 0; u32 "$off"
            printf '%s' "$zname"
        } >> "$zip"
    done < "$idx"
    cdsize=$(( $(wc -c < "$zip") - cd_start ))
    {
        u32 0x06054b50; u16 0; u16 0
        u16 3; u16 3
        u32 "$cdsize"; u32 "$cd_start"
        u16 0
    } >> "$zip"
    rm -f "$idx"
    # Self-check before shipping: a silently corrupt container is worse than
    # no container.  busybox unzip -t validates every CRC; on any failure
    # the zip is removed and the kv text stands alone as the deliverable.
    # unzip has nothing to do with the awk choice: reusing $PM_AWK here turns
    # "awk unzip -t" into a guaranteed failure whenever the awk probe picked
    # the bare interpreter, and a working zip then dies in the self-check on
    # a box without standalone unzip.  Probe the unzip carriers separately.
    PM_UNZIP=""
    for u in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox busybox unzip; do
        if "$u" unzip -t "$zip" >/dev/null 2>&1; then PM_UNZIP="$u"; break; fi
    done
    if [ -n "$PM_UNZIP" ]; then
        pm_log "export: zip $zip"
        echo "export: $zip"
    else
        rm -f "$zip"
        pm_log "export: zip failed self-check, removed (kv text is the export)"
        echo "export: zip container failed validation; the kv text above is the export"
        return 3
    fi
    # Retention: every export leaves a kv + a zip, and nothing ever removed
    # them -- the device had accumulated ten pairs before this existed.  Keep
    # the six newest zips (their matching .txt goes with each); ls -t walks
    # newest first so the cap is an age bound that never needs find -mtime.
    # Failures here are cosmetic -- an old export staying one more round
    # harms nothing -- so the sweep is silent.
    _n=0
    for f in $(ls -t "$out"/pianomax-config-*.zip 2>/dev/null); do
        _n=$((_n + 1))
        [ "$_n" -le 6 ] && continue
        rm -f "$f" "${f%.zip}.txt" 2>/dev/null
    done
    unset _n
}

# Runnable standalone (export.sh run); silent when sourced as a library.
case "${0##*/}" in
    export.sh)
        case "$1" in
            run) pm_export_run ;;
            *)   echo "usage: export.sh run" ;;
        esac
        ;;
esac
