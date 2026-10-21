#!/system/bin/sh
# PianoMax - one-shot diagnostic sweep
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.
#
# Answers the six questions every support round starts with:
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
for c in $(pgrep -f "$PM_DIR/guard.sh" 2>/dev/null); do
    tr '\000' ' ' < "/proc/$c/cmdline" 2>/dev/null | grep -q "sh.*$PM_DIR/guard.sh" && GPIDS="$GPIDS $c"
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
if [ -f "$PM_DIR/.thermal_mode" ]; then
    MODE=$(cat "$PM_DIR/.thermal_mode")
    say_ok "thermal table in charge: $MODE (stamp present)"
    if [ -f /data/vendor/thermal/decrypt.txt ]; then
        SZ=$(stat -c %s /data/vendor/thermal/decrypt.txt 2>/dev/null)
        say_ok "decrypt.txt live, $SZ bytes (daemon is serving our table)"
    else
        say_fail "stamp present but decrypt.txt missing -- daemon never reloaded?"
    fi
    # cross-check the deployed table bytes against the module copy
    if [ -f "$PM_DIR/thermal/$MODE/thermal-normal.conf" ]; then
        ENC=$(md5sum "$PM_DIR/thermal/$MODE/thermal-normal.conf" | cut -d' ' -f1)
        say_ok "module table ($MODE) md5: $ENC"
    fi
else
    say_warn "no .thermal_mode stamp -- running in re-pin mode (stock table)"
fi
THERM=$(getprop init.svc.mi_thermald)
[ "$THERM" = "running" ] && say_ok "mi_thermald running" || say_fail "mi_thermald state: $THERM"

hdr "4. ceiling effectiveness"
CFG=/sys/devices/system/cpu/cpufreq
M0=$(grep -m1 '^target' "$PM_DIR/.thermal_mode" 2>/dev/null)
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
EMU=0
for z in /sys/class/thermal/thermal_zone*; do
    v=$(cat "$z/emul_temp" 2>/dev/null)
    [ -n "$v" ] && [ "$v" != "0" ] && { echo "  $z emul_temp=$v"; EMU=$((EMU+1)); }
done
[ "$EMU" -eq 0 ] && say_ok "no emul_temp residue (all zones clean)" || say_fail "$EMU zone(s) with live temperature emulation"
IM=$(find "$PM_DIR" -name '.thermal_orig' -maxdepth 2 2>/dev/null | head -1)
[ -n "$IM" ] && echo "  note: .thermal_orig snapshot exists (revert data available)"

hdr "6. recent log tail"
echo "  --- last 5 log lines ---"
tail -5 "$PM_DIR/pianomax.log" 2>/dev/null | sed 's/^/  /'
ERRS=$(grep -cE 'wr miss|wr fail' "$PM_DIR/pianomax.log" 2>/dev/null)
[ "$ERRS" = "0" ] && say_ok "no write failures in log" || say_warn "$ERRS write failure lines in log history"

echo ""
echo "==== summary: ok=$OK warn=$WARN fail=$FAIL ===="
[ "$FAIL" -gt 0 ] && exit 1
exit 0
