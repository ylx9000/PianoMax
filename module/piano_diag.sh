#!/system/bin/sh
# PianoMax - one-shot diagnostic sweep
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# Answers the eight questions every support round starts with:
# is the module alive, does it hold the lock alone, is the thermal table
# ours, can anything override the ceiling, is the daemon fresh, and did
# anything leave emulation or latch residue behind.  Read-only by design:
# the only writes are inside /data/local/tmp/pianomax_diag, never sysfs.

PM_DIR=${PM_DIR:-/data/adb/modules/pianomax}
PM_DEBUG_TMP=/data/local/tmp/pianomax_diag
OK=0; WARN=0; FAIL=0

say_ok()   { echo "[ OK ] $1"; OK=$((OK+1)); }
say_warn() { echo "[WARN] $1"; WARN=$((WARN+1)); }
say_fail() { echo "[FAIL] $1"; FAIL=$((FAIL+1)); }
hdr()      { echo ""; echo "==== $1 ===="; }

hdr "1. module presence"
if [ -d "$PM_DIR" ]; then
    say_ok "module dir present: $PM_DIR"
    if [ -f "$PM_DIR/disable" ]; then say_warn "module is DISABLED (disable file present)"; else say_ok "module enabled"; fi
else
    say_fail "module dir missing -- install first"
    echo ""; echo "summary: ok=$OK warn=$WARN fail=$FAIL"; exit 1
fi

hdr "2. guard instance & lock"
# pgrep -f matches any cmdline containing the pattern, including transient
# su/sh wrappers whose arguments merely quote the path -- every hit is
# verified against /proc/<pid>/cmdline naming the real script before counting.
GPIDS=""
MYSELF=$
for c in $(pgrep -f "$PM_DIR/guard.sh" 2>/dev/null); do
    # Exclude our own process tree: transient pipeline children (the diag
    # shell spawning this very probe) inherit the pattern in their cmdline
    # and were counted as a second guard (F3, hit live 2026-10-23).
    ppid=$(awk '/^PPid:/{print $2}' "/proc/$c/status" 2>/dev/null)
    case " $MYSELF $c " in *" $ppid "*) continue ;; esac
    tr '\000' ' ' < "/proc/$c/cmdline" 2>/dev/null | grep -q "^sh $PM_DIR/guard.sh" && GPIDS="$GPIDS $c"
done
GPIDS=$(echo $GPIDS)
LOCKPID=$(cat "$PM_DIR/.guard_lock/pid" 2>/dev/null)
N=$(echo $GPIDS | wc -w)
[ -z "$GPIDS" ] && N=0
if [ "$N" -eq 0 ]; then
    say_fail "no guard running (lock pid: ${LOCKPID:-none})"
elif [ "$N" -eq 1 ]; then
    if [ "$GPIDS" = "$LOCKPID" ]; then
        say_ok "single guard, pid $GPIDS, holds the lock"
    else
        say_fail "single guard pid $GPIDS but lock records $LOCKPID -- lock mismatch"
    fi
else
    say_fail "MULTIPLE guard instances: $(echo $GPIDS | tr '\n' ' ') (lock: ${LOCKPID:-none}) -- takeover sweep should have cleaned this"
fi

hdr "3. thermal table ownership"
# The immutable bit belongs to this section because it is part of the claim
# the module makes about this directory: cloud control cannot overwrite the
# table.  chattr is absent on some toybox builds and every +i call in
# thermal.sh is silenced, so without a check here the guarantee could be
# missing on a device whose log still reads as if it held.
if command -v chattr >/dev/null 2>&1; then
    if command -v lsattr >/dev/null 2>&1; then
        # toybox and e2fsprogs both print the flags first, but the field
        # widths are not guaranteed identical across vendor builds, so match
        # the flag run rather than a fixed column: the immutable bit is the
        # fifth character in the standard layout, and "no i anywhere before
        # the path" is the answer that matters.
        _line=$(lsattr -d /data/vendor/thermal/config 2>/dev/null)
        case "$_line" in
            ????i*) say_ok "override dir carries the immutable bit (cloud control cannot overwrite it)" ;;
            "")     say_warn "lsattr returned nothing for the override dir -- cannot confirm the immutable bit" ;;
            *)      say_warn "override dir is NOT immutable (lsattr: $_line) -- joyose/powerkeeper can rewrite the table" ;;
        esac
    else
        say_warn "lsattr missing -- cannot confirm the immutable bit (chattr present)"
    fi
else
    say_warn "chattr missing on this ROM -- the table cannot be pinned; cloud control may overwrite it"
fi
if [ -f "$PM_DIR/.thermal_mode" ]; then
    MODE=$(cat "$PM_DIR/.thermal_mode")
    say_ok "thermal stamp present: $MODE"
    if [ -f /data/vendor/thermal/decrypt.txt ]; then
        SZ=$(stat -c %s /data/vendor/thermal/decrypt.txt 2>/dev/null)
        say_ok "decrypt.txt live, $SZ bytes"
        # The stamp is what the module believes; this block reports what the
        # guard is actually doing with it.  They disagree in two real states
        # -- daemon never re-read, or no install-time reference -- and in
        # both the guard re-pins.  Calling that "table in charge" would be
        # the same half-truth the old one-line check was.
        if [ -f "$PM_DIR/.thermal_ts" ]; then
            TS_M=$(stat -c %Y "$PM_DIR/.thermal_ts" 2>/dev/null)
            DT_M=$(stat -c %Y /data/vendor/thermal/decrypt.txt 2>/dev/null)
            if [ -n "$TS_M" ] && [ -n "$DT_M" ]; then
                if [ "$DT_M" -ge "$TS_M" ]; then
                    say_ok "table in charge ($MODE) -- guard handed the ceiling to the daemon"
                else
                    say_warn "table installed but daemon did not re-read -- guard is re-pinning instead (ceiling still held)"
                fi
            else
                say_warn "install-time reference unreadable -- guard is re-pinning instead (ceiling still held)"
            fi
        else
            say_warn "no .thermal_ts reference -- guard is re-pinning instead (ceiling still held)"
        fi
    else
        say_fail "stamp present but decrypt.txt missing -- daemon never reloaded; guard is re-pinning"
    fi
    # Cross-check the deployed table bytes against the module copy.  The
    # earlier version only printed the module-side md5, which could never fail
    # -- a check that has no false branch is a decoration, not a diagnostic.
    # What it should answer is: is the file the daemon is actually reading
    # still byte-identical to the table this module shipped?
    if [ -f "$PM_DIR/thermal/$MODE/thermal-normal.conf" ]; then
        ENC=$(md5sum "$PM_DIR/thermal/$MODE/thermal-normal.conf" | cut -d' ' -f1)
        LIVE=$(md5sum /data/vendor/thermal/config/thermal-normal.conf 2>/dev/null | cut -d' ' -f1)
        if [ -z "$LIVE" ]; then
            say_warn "deployed thermal-normal.conf unreadable -- cannot cross-check"
        elif [ "$LIVE" = "$ENC" ]; then
            say_ok "deployed table == module table ($MODE, md5 $LIVE)"
        else
            say_fail "deployed table md5 $LIVE != module $MODE md5 $ENC -- cloud overwrote or swap failed"
        fi
    fi
else
    # No stamp means "never swapped" (stock table, re-pin mode) or "swap
    # failed after copying" (our bytes sit in T_DIR and the guard is
    # re-pinning over them).  Different problems -- look before labelling.
    _deployed=$(md5sum /data/vendor/thermal/config/thermal-normal.conf 2>/dev/null | cut -d' ' -f1)
    _ours=no
    if [ -n "$_deployed" ]; then
        for _cand in "$PM_DIR"/thermal/*/*.conf; do
            [ -f "$_cand" ] || continue
            if [ "$(md5sum "$_cand" 2>/dev/null | cut -d' ' -f1)" = "$_deployed" ]; then _ours=yes; break; fi
        done
    fi
    if [ "$_ours" = "yes" ]; then
        say_warn "no stamp but OUR table is deployed -- swap failed after the copy; guard is re-pinning (ceiling still held). Re-select the preset to repair"
    else
        say_ok "no table deployed -- running in re-pin mode on the stock table"
    fi
fi
THERM=$(getprop init.svc.mi_thermald)
[ "$THERM" = "running" ] && say_ok "mi_thermald running" || say_fail "mi_thermald state: $THERM"

hdr "4. ceiling effectiveness"
CFG=/sys/devices/system/cpu/cpufreq
A0=$(cat "$CFG/policy0/scaling_max_freq" 2>/dev/null)
A6=$(cat "$CFG/policy6/scaling_max_freq" 2>/dev/null)
C0=$(cat "$CFG/policy0/scaling_cur_freq" 2>/dev/null)
C6=$(cat "$CFG/policy6/scaling_cur_freq" 2>/dev/null)
echo "  policy0 max=$A0 cur=$C0 / policy6 max=$A6 cur=$C6"
if [ "$A0" = "0" ] || [ -z "$A0" ]; then say_fail "policy0 scaling_max unreadable"; fi
HW0=$(cat "$CFG/policy0/cpuinfo_max_freq" 2>/dev/null)
HW6=$(cat "$CFG/policy6/cpuinfo_max_freq" 2>/dev/null)
echo "  hw tops: $HW0 / $HW6"
if [ "$A0" -lt "$HW0" ] && [ ! -f "$PM_DIR/.thermal_mode" ]; then
    say_warn "ceiling below hw top without an owned table -- daemon or someone else is clamping"
fi
# freezer check: a frozen guard cannot hold anything
DIAGPID=${LOCKPID:-$(echo $GPIDS | cut -d' ' -f1)}
CG=""
[ -n "$DIAGPID" ] && CG=$(grep '^0::' /proc/$DIAGPID/cgroup 2>/dev/null | cut -d: -f3)
if [ "$CG" != "/" ]; then
    say_warn "guard cgroup: $CG (not root -- Android freezer may freeze it, see .guard_freezer history)"
else
    say_ok "guard in root cgroup (freezer-safe)"
fi
FRZ=$(cat /sys/fs/cgroup/uid_0/cgroup.freeze 2>/dev/null)
[ -n "$FRZ" ] && echo "  uid_0 cgroup.freeze=$FRZ"

hdr "5. residue checks"
# emul_temp is a DEVICE_ATTR_WO node (mode 0200, no show handler), so reading
# it back is impossible by design -- not because the node disappears.  Residue
# is therefore detected through the zone temperature: exactly 25000 is the
# module signature, and the .spoof state file says which tier asked for it.
EMU=0
POLL=0
for z in /sys/class/thermal/thermal_zone*; do
    v=$(cat "$z/temp" 2>/dev/null)
    [ "$v" = "25000" ] || continue
    EMU=$((EMU+1))
    case " 47 48 49 50 51 52 53 54 55 57 58 59 60 61 63 64 65 66 67 68 77 " in
        *" ${z#/sys/class/thermal/thermal_zone} "*) POLL=$((POLL+1)); echo "  PROTECTED zone emulated: $z" ;;
    esac
done
# Only the emul tiers can legitimately leave 25000 behind; lock and off both
# promise zero zones, so any residue under those two is a real fault.
case "$(cat "$PM_DIR/.spoof" 2>/dev/null)" in
    on|max|normal)
        if [ "$EMU" -gt 0 ]; then
            say_ok "temp spoof active: $EMU zone(s) at 25 C"
        else
            say_warn "spoof tier is emul but no zone reads 25 C (between refreshes)"
        fi ;;
    *)
        [ "$EMU" -eq 0 ] && say_ok "no temperature emulation residue" \
            || say_fail "$EMU zone(s) still emulated with the switch off" ;;
esac
# The check that must never pass: a protection-family zone reading the spoofed
# value means the spoof reached somewhere it must not, whatever tier is active.
[ "$POLL" -eq 0 ] && say_ok "protection family clean (0 of 21 zones emulated)" \
    || say_fail "$POLL protection zone(s) emulated -- spoof escaped its set"
[ -d "$PM_DIR/.thermal_orig" ] && echo "  note: .thermal_orig snapshot exists (revert data available)"

hdr "6. tripwire coverage"
# Structural check, not a count.  disable_compute_zones switches the kernel
# governor off for a set of zones; the guard's tripwire has to read that same
# set.  When it did not, several thermal zones had the governor silenced, were
# spoofed to 25 C, and were read by nothing -- three protective layers off at
# once with no visible symptom.  The gap came from maintaining two hardcoded
# lists; both sides now derive from PM_SILICON_ZONES, and this check proves it
# on the device rather than in the source.
. "$PM_DIR/lib/common.sh" 2>/dev/null
OFFLIST=""; OFFN=0
for z in /sys/class/thermal/thermal_zone*; do
    m=""; IFS= read -r m < "$z/mode" 2>/dev/null
    [ "$m" = "disabled" ] || continue
    zn=${z##*/}; zn=${zn#thermal_zone}
    OFFLIST="$OFFLIST $zn"; OFFN=$((OFFN + 1))
done
UNGOV=""; UNGOVN=0
for zn in $OFFLIST; do
    case "$PM_SILICON_ZONES" in
        *" $zn "*) ;;
        *) UNGOV="$UNGOV $zn"; UNGOVN=$((UNGOVN + 1)) ;;
    esac
done
if [ "$UNGOVN" -eq 0 ]; then
    say_ok "tripwire covers every disabled zone ($OFFN/$OFFN)"
else
    say_warn "$UNGOVN disabled zone(s) no tripwire reads:$UNGOV -- governor off, module blind; update PM_SILICON_ZONES"
fi

hdr "7. recent log tail"
echo "  --- last 5 log lines ---"
tail -5 "$PM_DIR/pianomax.log" 2>/dev/null | sed 's/^/  /'
ERRS=$(grep -cE 'wr miss|wr fail' "$PM_DIR/pianomax.log" 2>/dev/null)
[ "$ERRS" = "0" ] && say_ok "no write failures in log" || say_warn "$ERRS write failure lines in log history"

hdr "8. state drift"
# .target must equal the active preset's own row in presets.txt.  A
# mismatch is the "UI shows one thing, the box runs another" class: a
# slider write the user forgot, or a stage frozen into the wrong file.
CUR=$(cat "$PM_DIR/.profile" 2>/dev/null)
case "$CUR" in
    省电) PK=powersave ;; 均衡) PK=balanced ;; 性能) PK=performance ;;
    *) PK=extreme ;;
esac
LINE=$(grep "^$PK	" "$PM_DIR/presets.txt" 2>/dev/null | head -n 1)
if [ -n "$LINE" ] && [ -f "$PM_DIR/.target" ]; then
    P0=$(echo "$LINE" | cut -f3); P6=$(echo "$LINE" | cut -f4)
    T=$(cat "$PM_DIR/.target")
    T0=$(echo "$T" | cut -d' ' -f1); T6=$(echo "$T" | cut -d' ' -f2)
    if [ "$T0" = "$P0" ] && [ "$T6" = "$P6" ]; then
        say_ok ".target matches preset $PK ($T0/$T6)"
    else
        say_warn ".target $T0/$T6 differs from preset $PK row $P0/$P6 (slider override or stale state)"
    fi
else
    say_warn ".profile or .target missing (fresh install?)"
fi
# A back-off stage older than a day is stale: the guard clears it on the
# first live reading, so a persistent .stage means no guard is running.
[ -f "$PM_DIR/.stage" ] && say_warn ".stage present: $(cat "$PM_DIR/.stage") (active back-off)"

echo ""
echo "==== summary: ok=$OK warn=$WARN fail=$FAIL ===="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
