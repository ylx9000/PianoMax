#!/system/bin/sh
# PianoMax - shared helpers
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.

# Every runtime script sources this so the paths and the log helper exist
# in exactly one place.  MODDIR is derived, never hardcoded: the module can
# be installed under modules_update while an update is pending, and a
# hardcoded /data/adb/modules path would then read and write the wrong tree.

# Find the module root by walking up from the calling script until module.prop
# appears.  Hardcoding /data/adb/modules/pianomax is wrong while an update
# sits in modules_update, and a plain dirname($0) is wrong for the scripts
# that live one level deeper (webroot/control.sh).  A caller that already
# located the module exports PM_DIR and wins -- this matters for tools that
# run from outside the module tree.
if [ -n "${PM_DIR:-}" ] && [ -f "$PM_DIR/module.prop" ]; then :; else
PM_DIR=$(dirname "$0")
i=0
while [ $i -lt 4 ] && [ ! -f "$PM_DIR/module.prop" ]; do
    PM_DIR=$(dirname "$PM_DIR")
    i=$((i + 1))
done
PM_DIR=$(cd "$PM_DIR" 2>/dev/null && pwd) || PM_DIR=$(dirname "$0")
fi
PM_LOG=$PM_DIR/pianomax.log
PM_STATE=$PM_DIR/.state
PM_TARGET=$PM_DIR/.target
PM_STAGE=$PM_DIR/.stage
PM_TRIP=$PM_DIR/.trip
PM_GPU=$PM_DIR/.gpu
PM_BUS=$PM_DIR/.bus
PM_ZONES=$PM_DIR/.zones
PM_PROFILE=$PM_DIR/.profile
PM_OFF=/data/adb/modules/.pianomax_off

CFG=/sys/devices/system/cpu/cpufreq
TM=/sys/devices/virtual/thermal/thermal_message
GPU=/sys/class/kgsl/kgsl-3d0
BUS=/sys/devices/system/cpu/bus_dcvs

pm_log() { echo "[$(date +%m-%d\ %H:%M:%S)] $*" >> "$PM_LOG" 2>/dev/null; }

# The daemon writes a heartbeat every 30 s forever; without a cap the log
# grows without bound.  Checked by size, truncated to the last 400 lines and
# only when past 64 KB, so normal bursts are never cut mid-trace.
pm_log_trim() {
    [ -f "$PM_LOG" ] || return 0
    sz=$(wc -c < "$PM_LOG" 2>/dev/null)
    [ "${sz:-0}" -gt 65536 ] || return 0
    tail -n 400 "$PM_LOG" > "$PM_LOG.tmp" 2>/dev/null && mv "$PM_LOG.tmp" "$PM_LOG"
}

# Read a sysfs node, print an empty string on any failure.
pm_cat() { cat "$1" 2>/dev/null; }

# Write, and report whether the kernel accepted it.  Silence is the default
# failure mode of shell redirection, so every tunable write is counted.
PM_FAILS=0
pm_wr() {
    [ -e "$1" ] || { PM_FAILS=$((PM_FAILS + 1)); pm_log "wr miss $1"; return 1; }
    if echo "$2" > "$1" 2>/dev/null; then return 0; fi
    PM_FAILS=$((PM_FAILS + 1)); pm_log "wr fail $1 (=$2)"; return 1
}

# --- install environment ----------------------------------------------------
# The manager that shipped us decides where updates live and which features
# make sense, and three managers set disjoint marker variables.  Probe the
# strongest evidence first (installer-provided variables), then fall back to
# filesystem traces an already-running manager always leaves behind.  A root
# box with no manager at all is still usable: the verdict then says so and
# the caller decides how far it is willing to go without one.
# Output: one line, "manager|module_root", no spaces.
pm_detect_root() {
    m=unknown
    root=/data/adb/modules
    if [ -n "${KSU:-}" ] || [ -x /data/adb/ksud ]; then
        m=ksu
    elif [ -n "${APATCH:-}" ] || [ -x /data/adb/apd ]; then
        m=apatch
    elif [ -n "${MAGISK_VER_CODE:-}" ]; then
        # Both KernelSU and APatch impersonate this variable with fixed
        # values (25200 / 27000); those cases are caught above, so a value
        # here means the real thing.
        m=magisk
    elif [ -x /data/adb/magisk/busybox ] || command -v magisk >/dev/null 2>&1; then
        # Env-less fallback for a shell that was never spawned by an
        # installer (adb su and friends): go by the daemons on disk.
        m=magisk
    elif [ -d /sbin/.magisk ] || [ -d /debug_ramdisk ]; then
        m=magisk
    elif [ "$(id -u 2>/dev/null)" = "0" ]; then
        m=rootonly
    fi
    # Every current manager keeps modules under /data/adb/modules; the
    # per-manager trees (ksu/, apd state) hold binaries and metadata only.
    # Verify rather than assume: a custom data layout must not silently
    # redirect writes, so the directory has to exist to be reported.
    [ -d "$root" ] || root=unknown
    echo "$m|$root"
}

# Numeric guard: is $1 a plain non-negative integer?
pm_num() { case "$1" in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

# Highest temperature among the sensors the module never disables.
# Returns millidegrees.  Falls back to 0 so callers must range-check.
#
# Temperatures come in two families on this platform and they measure very
# different things, so they get separate thresholds and separate loops.  A
# single shared threshold cannot work: the PMIC and skin sensors idle around
# 32-48 C while the CPU junction idles near 85 C under load, so one number
# either never fires (PMIC peaks around 57 C) or fires constantly.

# Silicon: CPU clusters, GPU, and the PMIC junctions that feed them.  These
# are the parts that get damaged.  Sustained full load sits in the high 80s,
# and thermal shutdown is around 110 C.
pm_temp_compute() {
    t=0
    for z in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 16 17 18 19 20 21 \
             23 24 25 26 27 28 29 30 \
             69 70 71 72 73 74 75 76; do
        v=$(cat /sys/class/thermal/thermal_zone$z/temp 2>/dev/null)
        pm_num "$v" || continue
        [ "$v" -gt "$t" ] && t=$v
    done
    echo $t
}

# Rotating variant: reads one quarter of the silicon family per call (chosen
# by position, so each sweep sees a fixed set), covering all 36 zones over
# four calls -- 9 reads a tick instead of 36.  Silicon time constants are far
# above the four-second sweep, so the tripwire loses nothing.  The full sweep
# still runs at every suspected trip so the back-off decision sees the true
# maximum.
PM_ROT=0
pm_temp_compute_rot() {
    t=0
    i=0
    for z in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 16 17 18 19 20 21 \
             23 24 25 26 27 28 29 30 \
             69 70 71 72 73 74 75 76; do
        case $((i % 4)) in
            $PM_ROT) ;;
            *) i=$((i + 1)); continue ;;
        esac
        i=$((i + 1))
        v=$(cat /sys/class/thermal/thermal_zone$z/temp 2>/dev/null)
        pm_num "$v" || continue
        [ "$v" -gt "$t" ] && t=$v
    done
    PM_ROT=$(( (PM_ROT + 1) % 4 ))
    echo $t
}

# Skin and battery: the sensors that track what the chassis and the cell are
# actually doing.  quiet_therm is the board's quiet-zone proxy for case
# temperature; the rest are the panel, connectivity and charging paths.
pm_temp_skin() {
    t=0
    for z in 57 58 59 60 63 64 65 66 67 68; do
        v=$(cat /sys/class/thermal/thermal_zone$z/temp 2>/dev/null)
        pm_num "$v" || continue
        [ "$v" -gt "$t" ] && t=$v
    done
    echo $t
}

# Thresholds.  Silicon defaults just below thermal shutdown -- the module is
# meant to run hot, so this one is a damage guard, not a comfort guard.  Skin
# defaults where the chassis is genuinely hot rather than merely warm: 60 C is
# uncomfortable to hold and safe for the cell, 52 C tripped on every mouse
# movement.
pm_trip_compute() {
    v=$(cat "$PM_TRIP" 2>/dev/null | cut -d' ' -f1)
    pm_num "$v" && echo "$v" || echo 105000
}
pm_trip_skin() {
    v=$(cat "$PM_TRIP" 2>/dev/null | cut -d' ' -f2)
    pm_num "$v" && echo "$v" || echo 60000
}

# Four presets write these four files; the module reads them here so the
# presets and the individual sliders share one source of truth.  Every default
# below is the extreme value, i.e. "no preset chosen" behaves like the first
# release did.
pm_gpu_level() { v=$(pm_cat "$PM_GPU" | tr -d ' '); pm_num "$v" && echo "$v" || echo 0; }
pm_bus_ddr()   { v=$(pm_cat "$PM_BUS" | cut -d' ' -f1); pm_num "$v" && echo "$v" || echo 4761000; }
pm_bus_llcc()  { v=$(pm_cat "$PM_BUS" | cut -d' ' -f2); pm_num "$v" && echo "$v" || echo 1211000; }

# kernel = leave the stock thermal governor in charge; module = silence the
# compute zones ourselves.  The powersave preset keeps the kernel, because at
# low clocks there is nothing to gain from fighting it.
pm_zones_kernel() {
    v=$(pm_cat "$PM_ZONES")
    [ "$v" = "kernel" ] && echo yes || echo no
}
pm_profile_name() { v=$(pm_cat "$PM_PROFILE"); [ -n "$v" ] && echo "$v" || echo 极限; }

# Nearest entry on a cpufreq ladder to `target * pct / 100`.  The guard needs
# this because a stage that is not a real ladder entry gets silently rounded by
# the kernel, and the UI would then show a number the module never asked for.
pm_step_down() {
    dir=$1; t=$2; pct=$3
    want=$((t * pct / 100))
    best=0; bestd=999999999
    for f in $(cat "$dir/scaling_available_frequencies" 2>/dev/null); do
        d=$((f > want ? f - want : want - f))
        if [ "$d" -lt "$bestd" ]; then bestd=$d; best=$f; fi
    done
    if [ "$best" -gt 0 ]; then echo "$best"; else echo "$t"; fi
}

# CPU ceiling the module should hold, per policy.  Two files, because they mean
# different things and must not overwrite each other:
#   .target  the user's preference, set from the WebUI, survives restarts
#   .stage   the guard's thermal back-off, transient by definition
# A stage written into .target was indistinguishable from a user preference, so
# a thermal event would permanently lower the ceiling the user had asked for.
pm_stage0() { v=$(pm_cat "$PM_STAGE" | cut -d' ' -f1); pm_num "$v" && echo "$v"; }
pm_stage6() { v=$(pm_cat "$PM_STAGE" | cut -d' ' -f2); pm_num "$v" && echo "$v"; }
# The ceiling the user or the preset asked for.  Never affected by a thermal
# back-off, so the guard can always compute a stage from a fixed reference.
pm_base0() { v=$(pm_cat "$PM_TARGET" | cut -d' ' -f1); pm_num "$v" && echo "$v" || echo 3532800; }
pm_base6() { v=$(pm_cat "$PM_TARGET" | cut -d' ' -f2); pm_num "$v" && echo "$v" || echo 4320000; }

# The ceiling currently in force: the back-off stage if one is active.
pm_target0() { v=$(pm_stage0); [ -n "$v" ] && echo "$v" || pm_base0; }
pm_target6() { v=$(pm_stage6); [ -n "$v" ] && echo "$v" || pm_base6; }

# The ceiling the kernel will actually hold.  sysfs accepts any number and
# rounds it to the nearest ladder entry, so comparing a raw request against the
# readback can never converge -- this is what every comparison must use.
pm_hold0() { pm_step_down "$CFG/policy0" "$(pm_target0)" 100; }
pm_hold6() { pm_step_down "$CFG/policy6" "$(pm_target6)" 100; }
# Match the guard by the absolute path it was started with.  A literal
# "pianomax/guard.sh" pattern only works when the module happens to live at
# that exact path, which is false during an update and false in the test copy.
pm_guard_pid() {
    # Fast path: the guard records its pid in the lock dir at startup.  The
    # WebUI snapshot calls this every few seconds and a full /proc scan per
    # call is pure waste when the lock is intact.
    p=$(cat "$PM_DIR/.guard_lock/pid" 2>/dev/null)
    if [ -n "$p" ] && [ -d "/proc/$p" ] && \
       tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -q guard.sh; then
        echo "$p"; return 0
    fi
    # Slow path: lock dir gone (SIGKILL, stop, stale) but a guard may still
    # be winding down -- fall back to the scan.
    for p in /proc/[0-9]*; do
        c=$( { tr '\000' ' ' < "$p/cmdline"; } 2>/dev/null ) || continue
        case "$c" in
            *"$PM_DIR/guard.sh"*) echo "${p##*/}"; return 0 ;;
        esac
    done
    return 1
}

pm_guard_up() {
    [ -f "$PM_DIR/disable" ] && return 1
    [ -f "$PM_OFF" ] && return 1
    return 0
}

# Start the daemon detached and verify it actually took.  The check-then-start
# race is closed inside guard.sh itself (mkdir lock): two concurrent starters
# both spawn a candidate, and the loser exits before touching any state.
pm_guard_start() {
    pm_guard_up || return 1
    if pm_guard_pid >/dev/null; then
        # The fast path only reports a guard whose pid the lock records.
        # After a module update the old daemon survives without any lock and
        # the /proc scan still finds it -- trusting that answer here would
        # never start the new code and the takeover sweep would never run.
        # A live guard without a matching lock is a ghost: kill it and start.
        lp=$(cat "$PM_DIR/.guard_lock/pid" 2>/dev/null)
        gp=$(pm_guard_pid)
        if [ -n "$lp" ] && [ "$lp" = "$gp" ] && [ -d "/proc/$lp" ]; then
            return 0
        fi
        [ -n "$gp" ] && [ -d "/proc/$gp" ] && kill -9 "$gp" 2>/dev/null
        rm -rf "$PM_DIR/.guard_lock" 2>/dev/null
        pm_log "guard start: removed lockless instance $gp"
    fi
    setsid sh "$PM_DIR/guard.sh" </dev/null >/dev/null 2>&1 &
    n=0
    while [ $n -lt 10 ]; do
        sleep 0.5 2>/dev/null || sleep 1
        if pm_guard_pid >/dev/null; then pm_log "guard started (pid $(pm_guard_pid))"; return 0; fi
        n=$((n + 1))
    done
    pm_log "guard start failed"
    return 1
}

pm_guard_stop() {
    for p in /proc/[0-9]*; do
        c=$( { tr '\000' ' ' < "$p/cmdline"; } 2>/dev/null ) || continue
        case "$c" in
            *"$PM_DIR/guard.sh"*) kill "${p##*/}" 2>/dev/null ;;
        esac
    done
    sleep 1
    # A clean kill lets the guard's EXIT trap remove the lock, but a SIGKILL
    # or a kill during start does not; make stop always leave a clean slate.
    # Only when the recorded pid is not a live guard anymore: removing the
    # directory while a concurrent start already re-armed it would birth a
    # lockless instance, the exact bug the takeover sweep has to clean up.
    lp=$(cat "$PM_DIR/.guard_lock/pid" 2>/dev/null)
    if [ -n "$lp" ] && [ -d "/proc/$lp" ] && \
       tr '\000' ' ' < "/proc/$lp/cmdline" 2>/dev/null | grep -q guard.sh; then
        :  # a fresh guard owns the lock now; leave it alone
    else
        rm -rf "$PM_DIR/.guard_lock" 2>/dev/null
    fi
}
