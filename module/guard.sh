#!/system/bin/sh
# PianoMax - supervisor daemon
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.

# Two jobs, both of which decide whether the module works at all:
#   1. hold the ceiling.  mi_thermald is a userspace daemon that rewrites
#      cpu_limits every couple of seconds; disabling thermal zones does not
#      reach it.  Without a re-pin loop in this file the ceiling decays to
#      ~1.9 GHz within seconds and every number shown in the UI is fiction.
#   2. stay alive.  A one-shot daemon that exits on the first trip leaves the
#      module half applied until the next reboot, and every reader (status,
#      WebUI) then shows a stale snapshot.  This one restores, waits, and
#      resumes by itself.

. "$(dirname "$0")/lib/common.sh"
. "$(dirname "$0")/lib/apply.sh"

# Put the ceiling back to the full spec.  Called on re-arm so a stale staged
# value does not survive a full restore.
held_reset() {
    rm -f "$PM_STAGE"
    STAGE=0
    RECOVER=0
    STAGE_HOLD=0
}

[ -f "$PM_DIR/disable" ] && exit 0
[ -f "$PM_OFF" ] && exit 0

# ---- single instance ----
# mkdir is atomic; two concurrent starters cannot both win the lock.  A stale
# lock (crash between mkdir and the trap) is broken by probing the pid left
# inside it: if that process is not a running guard, the lock is junk.
if ! mkdir "$PM_DIR/.guard_lock" 2>/dev/null; then
    old=$(cat "$PM_DIR/.guard_lock/pid" 2>/dev/null)
    if [ -n "$old" ] && [ -d "/proc/$old" ] && \
       tr '\000' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q guard.sh; then
        pm_log "guard start refused: pid $old already holds the lock"
        exit 0
    fi
    if [ -z "$old" ]; then
        # Lock exists but carries no pid yet: a starter between mkdir and the
        # pid write.  Breaking the lock now would orphan that starter and end
        # with two guards.  Wait once and re-read; a genuinely dead starter
        # still leaves the pid empty, and only then is the lock junk.
        sleep 2
        old=$(cat "$PM_DIR/.guard_lock/pid" 2>/dev/null)
        if [ -n "$old" ] && [ -d "/proc/$old" ] && \
           tr '\000' ' ' < "/proc/$old/cmdline" 2>/dev/null | grep -q guard.sh; then
            pm_log "guard start refused: pid $old took the lock late"
            exit 0
        fi
    fi
    pm_log "guard start: breaking stale lock${old:+ (pid $old gone)}"
    rm -rf "$PM_DIR/.guard_lock"
    mkdir "$PM_DIR/.guard_lock" || { pm_log "guard start failed: lock still held"; exit 1; }
fi
echo $$ > "$PM_DIR/.guard_lock/pid"

# Signals terminate.  INT/TERM must actually end the process: the old
# one-line trap ran under TERM and the interpreter then resumed the main
# loop, so pm_guard_stop, uninstall.sh and every other stop path were
# no-ops against a running guard.  Cleanup keeps one guardrail: only the
# process whose pid the lock records may delete it, so a dying duplicate
# can never strip the lock of the guard that owns it (an update flow
# recreates this directory and leaves exactly that pair behind).
cleanup() {
    [ "$(cat "$PM_DIR/.guard_lock/pid" 2>/dev/null)" = "$$" ] && \
        rm -rf "$PM_DIR/.guard_lock"
    exit 0
}
trap cleanup INT TERM
trap cleanup EXIT

# ---- takeover sweep --------------------------------------------------
# After a module update the directory -- and the old lock with it -- is
# rebuilt while the previous daemon keeps running without any lock.  Every
# management function trusts the lock pid, so that stale instance stays
# invisible to restarts, stops and the watchdog, and two guards then
# double every sample, log line and re-pin.  The new lock holder sweeps
# the leftovers itself, once, before entering the loop: plain kill first
# so a well-behaved instance exits cleanly, SIGKILL after for instances
# still running the old trap code that swallows TERM.
for p in /proc/[0-9]*; do
    [ "${p##*/}" = "$$" ] && continue
    c=$(tr '\000' ' ' < "$p/cmdline" 2>/dev/null) || continue
    case "$c" in
        *"$PM_DIR/guard.sh"*) kill "${p##*/}" 2>/dev/null ;;
    esac
done
sleep 1
for p in /proc/[0-9]*; do
    [ "${p##*/}" = "$$" ] && continue
    c=$(tr '\000' ' ' < "$p/cmdline" 2>/dev/null) || continue
    case "$c" in
        *"$PM_DIR/guard.sh"*)
            kill -9 "${p##*/}" 2>/dev/null
            pm_log "guard takeover: killed stale instance ${p##*/}"
            ;;
    esac
done
# A ghost still running the old trap code rm's the shared lock as it dies
# from the plain kill above; re-assert ownership so the fast path of
# pm_guard_pid works from the first tick.
mkdir -p "$PM_DIR/.guard_lock" 2>/dev/null
echo $$ > "$PM_DIR/.guard_lock/pid"

pm_log "guard up"

# Two independent tripwires, because the two sensor families answer different
# questions:
#   compute -- is the silicon getting dangerous?  Threshold defaults to 105 C,
#              above anything sustained load produces, below the 110 C shutdown.
#   skin    -- is the chassis boiling / is the battery being cooked?
#              Threshold defaults to 60 C, hot to hold but safe for the cell.
#              52 C was tried first and tripped on every burst of load.
# A single threshold across both does not work here: the PMIC family peaks near
# 57 C while the CPU junction idles in the high 80s under load.
# Give the boot sequence time to settle.  service.sh already waits for
# boot_completed; this covers a manual start from the WebUI.
# Apply FIRST, then settle: pm_apply_all before the sleep means the ceiling is
# live within one tick of the start command instead of after the full settle.
pm_apply_all >/dev/null 2>&1
sleep 3

# State machine:
#   HELD=1   we own the ceiling at its current stage
#   HELD=0   we handed everything back and are waiting for a real cooldown
# STAGE tracks how many notches the ceiling has been dropped.  Stage 0 is the
# full SoC spec; each stage steps down to a real ladder entry.  Past stage 2
# the module stops trying.
HELD=1
COOL=0
SAVED_FAILS=0
STREAK=0
STAGE=0
RECOVER=0
STAGE_HOLD=0
DEAD=0
DEAD_C=0
DEAD_S=0
# Re-adopt any back-off that was in force before this process started.  The
# saved file is the only evidence of the stage, so trust it as "we are in a
# back-off" rather than trying to match a string that depends on the preset.
[ -f "$PM_STAGE" ] && STAGE=1

# The profile name the guard last acted on.  When it changes, the thresholds and
# the ceiling both changed, and the heat still in the chip belongs to the old
# one -- so trips are ignored for a short grace window instead of dropping the
# new preset a stage the instant it is selected.
SEEN_PROFILE=$(pm_profile_name)
GRACE=0

while true; do
    # ---- shutdown paths -------------------------------------------------
    if [ -f "$PM_DIR/disable" ]; then
        pm_log "kernelsu disabled, restoring"
        sh "$PM_DIR/restore.sh" >/dev/null 2>&1
        exit 0
    fi
    if [ -f "$PM_OFF" ]; then
        # Same atomicity as the live tick: a reader hitting the O_TRUNC
        # window would show the UI a blank snapshot every third second.
        echo "off|0|0|0|0|0|0|0|off" > "$PM_STATE.tmp" 2>/dev/null
        mv "$PM_STATE.tmp" "$PM_STATE" 2>/dev/null
        sleep 3
        continue
    fi

    # ---- stay out of the app freezer -------------------------------------
    # A guard launched from an adb shell or a WebUI exec lands in an app
    # cgroup the Android freezer suspends (wchan do_freezer_trap, no logs,
    # no exit -- the loop simply stops).  Boot-spawned instances sit outside
    # that tree and never hit this.  Moving the pid to the root group is
    # the only escape; a frozen process cannot do it itself, so this also
    # re-arms after any freeze that started before the check ran.  Cheap:
    # one procfs read per tick, one write only when off-root.
    CG=$(grep "^0::" /proc/$$/cgroup 2>/dev/null | cut -d: -f3)
    if [ -n "$CG" ] && [ "$CG" != "/" ]; then
        echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null \
            && pm_log "guard: left frozen cgroup $CG"
    fi

    # ---- thermald must live ---------------------------------------------
    if [ "$(getprop init.svc.mi_thermald)" != "running" ]; then
        start mi_thermald 2>/dev/null
        # Log only on the state transition: a daemon that never comes up would
        # otherwise write this line every tick and flush the real history out
        # of the 64 KB log window.
        [ "$THERMALD_WAS" = "down" ] || pm_log "thermald restarted"
        THERMALD_WAS=down
    else
        THERMALD_WAS=""
    fi

    # Ticks since the last back-off.  Escalation requires the silicon to have
    # had ~15 seconds to react to the lower ceiling first.
    STAGE_HOLD=$((STAGE_HOLD + 1))

    # A slider write clears $PM_STAGE on disk but cannot reach this process:
    # drop the in-memory stage too, or the recovery path below would re-derive
    # and re-write the back-off the user just replaced.
    if [ "$STAGE" != "0" ] && [ ! -f "$PM_STAGE" ]; then
        STAGE=0
        RECOVER=0
        pm_log "stage cleared externally, back-off state reset"
    fi

    # A preset switch resets the thermal state: different thresholds, different
    # ceiling, and residual heat left over from the preset you just left.
    now_profile=$(pm_profile_name)
    if [ "$now_profile" != "$SEEN_PROFILE" ]; then
        SEEN_PROFILE=$now_profile
        HELD=1
        STAGE=0
        COOL=0
        RECOVER=0
        STAGE_HOLD=0
        GRACE=15
        rm -f "$PM_STAGE"
        pm_log "profile -> $now_profile, thermal state reset (grace 15)"
    fi

    # ---- temperature -----------------------------------------------------
    # Steady state sweeps a quarter of the silicon family per tick (thermal
    # time constants make a 4 s sweep lossless); the full family runs whenever
    # the sweep suspects a trip, so a back-off always decides on real maxima.
    TC=$(pm_temp_compute_rot)
    TS=$(pm_temp_skin)
    TRIPC=$(pm_trip_compute)
    TRIPS=$(pm_trip_skin)
    if [ "$TC" -ge "$TRIPC" ] || [ "$TS" -ge "$TRIPS" ]; then
        TC=$(pm_temp_compute)
    fi
    # Every sensor dead reads as 0/0, which can never trip: the module would
    # hold the full ceiling forever with nothing watching the silicon.  Zone
    # numbers are hardcoded and a ROM update can move them, so this is a real
    # failure mode, not a hypothetical.  30 consecutive dead ticks (~30 s)
    # force a stage-1 back-off and log it; one live reading re-arms silently.
    # The two families fail independently (hardcoded zone numbers drift per
    # ROM), so each gets its own dead counter: a skin-only outage must not
    # look healthy just because the silicon zones still answer.
    if [ "$TC" -eq 0 ]; then DEAD_C=$((DEAD_C + 1)); else
        [ "$DEAD_C" -ge 30 ] && pm_log "silicon sensors back after $DEAD_C ticks"
        DEAD_C=0
    fi
    if [ "$TS" -eq 0 ]; then DEAD_S=$((DEAD_S + 1)); else
        [ "$DEAD_S" -ge 30 ] && pm_log "skin sensors back after $DEAD_S ticks"
        DEAD_S=0
    fi
    if [ "$DEAD_C" -ge 30 ] || [ "$DEAD_S" -ge 30 ]; then
        DEAD=$((DEAD + 1))
        if [ "$DEAD" -ge 30 ]; then
            if [ "$STAGE" -lt 1 ]; then
                STAGE=1
                NA=$(pm_step_down "$CFG/policy0" "$(pm_base0)" 88)
                NB=$(pm_step_down "$CFG/policy6" "$(pm_base6)" 88)
                echo "$NA $NB" > "$PM_STAGE"
                for i in 0 1 2 3 4 5; do echo "cpu$i $NA" > "$TM/cpu_limits" 2>/dev/null; done
                for i in 6 7; do echo "cpu$i $NB" > "$TM/cpu_limits" 2>/dev/null; done
                echo "backoff $STAGE" > "$PM_STATE" 2>/dev/null
                pm_log "sensor outage 30+30 ticks (silicon ${DEAD_C}/skin ${DEAD_S}), forced back-off to stage 1 ($NA/$NB)"
            elif [ $((DEAD % 300)) -eq 0 ]; then
                pm_log "sensor outage $DEAD ticks, still backing off"
            fi
        fi
    fi

    if [ "$GRACE" -gt "0" ]; then
        GRACE=$((GRACE - 1))
        # Held, but not yet trusted to trip: the reading still reflects the
        # preset we just left.
    elif [ "$TC" -ge "$TRIPC" ] || [ "$TS" -ge "$TRIPS" ]; then
        if [ "$HELD" = "1" ]; then
            WHICH=silicon; LIM="$TC"
            [ "$TS" -ge "$TRIPS" ] && { WHICH=skin; LIM="$TS"; }
            if [ "$STAGE" -ge "2" ]; then
                # Out of stages: hand the whole machine back.
                pm_log "trip($WHICH) at $LIM mC, stage 2 exceeded, restoring everything"
                sh "$PM_DIR/restore.sh" >/dev/null 2>&1
                HELD=0; COOL=0
                echo "tripped $WHICH" > "$PM_STATE" 2>/dev/null
            elif [ "$STAGE_HOLD" -ge 15 ]; then
                # Staged back-off.  Nothing is restored: the ceiling is
                # simply lowered a notch and the module keeps holding there.
                # This is what stops it oscillating between max and idle on
                # any workload long enough to heat the chassis.
                STAGE=$((STAGE + 1))
                # Percentages of the ceiling the user or the preset chose, not
                # absolute numbers: powersave runs at 1.55 GHz and an absolute stage
                # would push it back up to 3.07.
                case "$STAGE" in
                    1) PCT=88 ;;
                    *) PCT=78 ;;
                esac
                NA=$(pm_step_down "$CFG/policy0" "$(pm_base0)" "$PCT")
                NB=$(pm_step_down "$CFG/policy6" "$(pm_base6)" "$PCT")
                echo "$NA $NB" > "$PM_STAGE"
                a=$NA; b=$NB
                for i in 0 1 2 3 4 5; do echo "cpu$i $a" > "$TM/cpu_limits" 2>/dev/null; done
                for i in 6 7; do echo "cpu$i $b" > "$TM/cpu_limits" 2>/dev/null; done
                echo "backoff $STAGE" > "$PM_STATE" 2>/dev/null
                pm_log "trip($WHICH) at $LIM mC, back-off to stage $STAGE ($a/$b)"
                COOL=0
                STAGE_HOLD=0
            else
                # Inside the 15-tick hold window: deliberately ignored, so a
                # single sensor spike cannot chatter the ceiling.  Logged at a
                # slow cadence anyway -- silence at 105 C is indistinguishable
                # from a dead sensor from the outside.
                [ $((STREAK % 30)) -eq 0 ] && pm_log "trip($WHICH) inside hold window (${STAGE_HOLD}/15), ignored"
            fi
            # (fallthrough: keep the current stage)
        fi
    else
        if [ "$HELD" = "1" ] && [ "$STAGE" != "0" ]; then
            # Warm but not tripping: give one notch back after two minutes of
            # headroom, so the ceiling recovers after a burst of load.
            # A dead sensor family reads 0 and would pass this check forever,
            # clearing the forced back-off every 120 ticks; with no thermal
            # data the back-off stays until real numbers return.
            if [ "$TC" -le $((TRIPC - 8000)) ] && [ "$TS" -le $((TRIPS - 5000)) ] && [ "$DEAD_C" -eq 0 ] && [ "$DEAD_S" -eq 0 ]; then
                RECOVER=$((RECOVER + 1))
                # 120 ticks = one notch back every ~2 min at the nominal 1 s
                # tick, matching what README and the WebUI promise.
                if [ "$RECOVER" -ge 120 ]; then
                    STAGE=$((STAGE - 1))
                    case "$STAGE" in
                        0) rm -f "$PM_STAGE" ;;
                        1)
                            # Stage 1 is 88% of the preset base -- the same
                            # ratio the down-step used, so recovery mirrors
                            # back-off whatever preset is active.  The old
                            # hardcoded value was the extreme preset's 88%
                            # and would over-clock every other preset.
                            na=$(pm_step_down "$CFG/policy0" "$(pm_base0)" 88)
                            nb=$(pm_step_down "$CFG/policy6" "$(pm_base6)" 88)
                            echo "$na $nb" > "$PM_STAGE" ;;
                    esac
                    pm_log "recover to stage $STAGE"
                    RECOVER=0
                fi
            else
                RECOVER=0
            fi
        fi
        if [ "$HELD" = "0" ]; then
            # Re-arm only after both families have come back down and stayed
            # there for 30 ticks (~30 s at the 1 s tick), otherwise the module
            # would chatter at the threshold.
            if [ "$TC" -le $((TRIPC - 15000)) ] && [ "$TS" -le $((TRIPS - 8000)) ]; then
                COOL=$((COOL + 1))
            else
                COOL=0
            fi
            if [ "$COOL" -ge 30 ]; then
                pm_log "re-arm at silicon ${TC} / skin ${TS} mC (stage ${STAGE})"
                # A stage-2-exceeded exit went through restore.sh, which wipes
                # .target as part of its factory cleanup.  Rebuild the working
                # files from the preset the UI still shows, or the module runs
                # full-throttle defaults under a mismatched preset label until
                # the next explicit preset switch.
                if [ ! -f "$PM_TARGET" ]; then
                    case "$(pm_profile_name)" in
                        省电) PK=powersave ;;
                        均衡) PK=balanced ;;
                        性能) PK=performance ;;
                        *)    PK=extreme ;;
                    esac
                    LINE=""
                    [ -f "$PM_DIR/presets.txt" ] && LINE=$(grep "^$PK	" "$PM_DIR/presets.txt" | head -n 1)
                    [ -n "$LINE" ] || case "$PK" in
                        powersave)   LINE="powersave	省电	1555200	1958400	10	1353000	533000	90000	50000	kernel" ;;
                        balanced)    LINE="balanced	均衡	2400000	2841600	6	3187000	933000	100000	55000	module" ;;
                        performance) LINE="performance	性能	3072000	3513600	4	4224000	1066000	105000	62000	module" ;;
                        *)           LINE="extreme	极限	3532800	4320000	0	4761000	1211000	105000	75000	module" ;;
                    esac
                    # Columns after cut -f2-10: name c0 c6 gpu ddr llcc tc ts zones
                    set -- $(echo "$LINE" | cut -f2-10)
                    echo "$2 $3" > "$PM_TARGET"
                    echo "$7 $8" > "$PM_TRIP"
                    echo "$4" > "$PM_GPU"
                    echo "$5 $6" > "$PM_BUS"
                    echo "$9" > "$PM_ZONES"
                    # restore.sh already wiped the governor preference with
                    # the rest of the state; make that explicit here so a
                    # rebuilt state never carries a stale .gov.
                    rm -f "$PM_DIR/.gov"                    # A module-zones preset also ships a thermal table; restore
                    # put the vendor one back, so re-install ours.  Failure is
                    # logged and non-fatal: the re-pin loop still holds.
                    if [ "$9" = "module" ] && [ -d "$PM_DIR/thermal/$PK" ]; then
                        . "$PM_DIR/lib/thermal.sh"
                        pm_thermal_swap "$PK" >/dev/null 2>&1 || pm_log "re-arm: thermal swap failed for $PK"
                    fi
                    pm_log "re-arm: state rebuilt from preset $PK"
                fi
                pm_apply_all >/dev/null 2>&1
                held_reset
                HELD=1; COOL=0
                echo "held" > "$PM_STATE" 2>/dev/null
            fi
        fi
    fi

    # ---- hold the ceiling ---------------------------------------------
    c0=$(pm_cat "$CFG/policy0/scaling_max_freq")
    c6=$(pm_cat "$CFG/policy6/scaling_max_freq")
    if [ "$HELD" = "1" ]; then
        # Snapped, not raw: the kernel rounds whatever it is given, so the
        # readback can only ever equal a value that is on the ladder.
        a=$(pm_hold0); b=$(pm_hold6)
        # A thermal table in charge (profile.sh installed one) makes the
        # daemon enforce the ceiling itself; re-pinning every tick would
        # only fight the policy doing our job.  Reads stay, writes gate.
        TABLE_IN_CHARGE=0
        [ -f "$PM_DIR/.thermal_mode" ] && TABLE_IN_CHARGE=1
        if { [ "$c0" != "$a" ] || [ "$c6" != "$b" ]; } && [ "$TABLE_IN_CHARGE" = "0" ]; then
            # cpu_limits first: writing scaling_max_freq under a lower ceiling
            # is accepted and then clamped back, which looks like a failure.
            for i in 0 1 2 3 4 5; do echo "cpu$i $a" > "$TM/cpu_limits" 2>/dev/null; done
            for i in 6 7; do echo "cpu$i $b" > "$TM/cpu_limits" 2>/dev/null; done
            echo "$a" > "$CFG/policy0/scaling_max_freq" 2>/dev/null
            echo "$b" > "$CFG/policy6/scaling_max_freq" 2>/dev/null
            SAVED_FAILS=$((SAVED_FAILS + 1))
            # Log the first few and then only every 60th, so a permanent
            # fight does not fill the log file.
            if [ "$SAVED_FAILS" -le 3 ] || [ $((SAVED_FAILS % 60)) -eq 0 ]; then
                pm_log "re-pin ${a}/${b} (was ${c0}/${c6}) n=$SAVED_FAILS"
            fi
        fi
        # Keep the GPU latch open.  msm-adreno-tz re-arms it after any thermal
        # event, and a single re-latch costs 270 MHz until the next reboot.
        g=$(pm_cat "$GPU/thermal_pwrlevel")
        if [ "$g" != "0" ]; then
            for c in /sys/class/thermal/cooling_device*; do
                [ "$(pm_cat "$c/type")" = "gpu" ] || continue
                echo 0 > "$c/cur_state" 2>/dev/null
            done
            echo 1100000000 > "$GPU/devfreq/max_freq" 2>/dev/null
            echo 0 > "$GPU/thermal_pwrlevel" 2>/dev/null
            g2=$(pm_cat "$GPU/thermal_pwrlevel")
            if [ "$g2" = "0" ]; then
                # Re-assert the ceiling the user or the preset chose, not the
                # full ladder: pin_gpu() writes pm_gpu_level for the same
                # reason, and a hardcoded 0 would quietly undo a lower preset's
                # GPU cap on the first thermal re-latch.
                pm_wr "$GPU/max_pwrlevel" "$(pm_gpu_level)"
                pm_log "gpu latch released (was $g)"
            fi
        fi
    fi

    # ---- launcher protection ---------------------------------------------
    # A dying launcher is what turns a memory spike into a reboot loop; the
    # kernel picks victims by oom_score_adj.  pgrep forks, so this runs every
    # fifth tick rather than on every pass.  Only real processes get written:
    # the pid must still exist and its cmdline must name the package at the
    # start (an editor open on a file with that name must not match).
    if [ $((STREAK % 5)) -eq 0 ]; then
        for p in $(pgrep -f com.miui.home 2>/dev/null) $(pgrep -f com.android.systemui 2>/dev/null); do
            [ -r "/proc/$p/cmdline" ] || continue
            tr '\000' ' ' < "/proc/$p/cmdline" 2>/dev/null | grep -qE '(^|/)com\.(miui\.home|android\.systemui)' || continue
            adj=$(cat "/proc/$p/oom_score_adj" 2>/dev/null)
            if [ -n "$adj" ] && [ "$adj" != "-1000" ]; then
                echo -1000 > "/proc/$p/oom_score_adj" 2>/dev/null
            fi
        done
    fi

    # ---- snapshot for the UI ---------------------------------------------
    # Single line, pipe separated, no spaces: the WebUI splits it and never
    # runs a second command to learn the same thing.
    # state|p0|p6|gpu|ddr|llcc|tempC|gov
    p0=$(pm_cat "$CFG/policy0/scaling_cur_freq")
    p6=$(pm_cat "$CFG/policy6/scaling_cur_freq")
    gclk=$(pm_cat "$GPU/clock_mhz")
    ddr=$(pm_cat "$BUS/DDR/cur_freq")
    llc=$(pm_cat "$BUS/LLCC/cur_freq")
    if [ "$HELD" = "1" ]; then
        if [ "$STAGE" -gt "0" ]; then st="backoff $STAGE"; else st=on; fi
    elif [ "$TC" -ge "$TRIPC" ] || [ "$TS" -ge "$TRIPS" ]; then st="tripped silicon"
    else st="tripped waiting"
    fi
    echo "$st|$p0|$p6|$gclk|$ddr|$llc|$((TS / 1000))|$((TC / 1000))|$(pm_cat $CFG/policy0/scaling_governor)" > "$PM_STATE.tmp" 2>/dev/null
    mv "$PM_STATE.tmp" "$PM_STATE" 2>/dev/null

    STREAK=$((STREAK + 1))
    if [ $((STREAK % 30)) -eq 0 ]; then
        pm_log "alive held=$HELD silicon=${TC} skin=${TS} max=${c0:-?}/${c6:-?}"
    fi
    if [ $((STREAK % 600)) -eq 0 ]; then
        pm_log_trim
    fi

    sleep 1
done
