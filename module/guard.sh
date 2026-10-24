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
PM_COMP=guard   # log v2: RFC5424 APP-NAME equivalent, one per entry script
. "$(dirname "$0")/lib/apply.sh"

# Mirror of thermal.sh's T_ROOT: the table gate below reads the daemon's
# decrypt.txt there.  Kept literal instead of sourcing thermal.sh: sourcing
# only defines constants and functions today, but it is the file that owns
# table swap and revert, and an edit there must not be able to acquire side
# effects inside the guard loop by accident.
T_ROOT=/data/vendor/thermal

# Deliberately empty.  There is no correct fixed adj for a managed app (see
# the launcher block below), so this is the off switch, not a tunable: the
# assignment exists so the sweep branches cleanly and so anyone reading the
# config cannot mistake its absence for an oversight.  Setting it to a value
# makes the guard fight AMS for that process, which is the bug, not the fix.
PM_LAUNCHER_PIN=""

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
    c_old=""
    [ -n "$old" ] && c_old=$(timeout 1 tr '\000' ' ' < "/proc/$old/cmdline" 2>/dev/null)
    case "$c_old" in
        sh*" "*$PM_DIR/guard.sh*|$PM_DIR/guard.sh*) alive_old=1 ;;
        *) alive_old=0 ;;
    esac
    if [ -n "$old" ] && [ -d "/proc/$old" ] && [ "$alive_old" = "1" ]; then
        pm_logw "refused: lock held by pid $old (single-instance contract)"
        exit 0
    fi
    if [ -z "$old" ]; then
        # Lock exists but carries no pid yet: a starter between mkdir and the
        # pid write.  Breaking the lock now would orphan that starter and end
        # with two guards.  Wait once and re-read; a genuinely dead starter
        # still leaves the pid empty, and only then is the lock junk.
        sleep 2
        old=$(cat "$PM_DIR/.guard_lock/pid" 2>/dev/null)
        # argv-head match, not substring: an editor with guard.sh open in a
        # pane must not read as "an old guard is alive" (a substring would
        # also hit grep/tail on the log path). A guard is always "sh <path>".
        c_old=""
        [ -n "$old" ] && c_old=$(timeout 1 tr '\000' ' ' < "/proc/$old/cmdline" 2>/dev/null)
        alive_old=0
        case "$c_old" in
            sh*$PM_DIR/guard.sh*|*"sh "$PM_DIR/guard.sh*|$PM_DIR/guard.sh*) alive_old=1 ;;
        esac
        if [ -n "$old" ] && [ -d "/proc/$old" ] && [ "$alive_old" = "1" ]; then
            pm_logw "refused: pid $old took the lock late (benign race lost)"
            exit 0
        fi
    fi
    pm_logn "stale_lock: breaking (old pid $old gone)"
    rm -rf "$PM_DIR/.guard_lock"
    mkdir "$PM_DIR/.guard_lock" || { pm_loge "refused: lock mkdir failed, still held"; exit 1; }
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
    # A dying process can wedge a plain read on /proc/<pid>/cmdline forever
            # (procfs race, hit live 2026-10-23: guard stuck 8 min in pipe_read).
            # timeout 1 caps the worst case; a live process reads in microseconds.
            c=$(timeout 1 tr '\000' ' ' < "$p/cmdline" 2>/dev/null) || continue
    case "$c" in
        sh*$PM_DIR/guard.sh*|*"sh "$PM_DIR/guard.sh*|$PM_DIR/guard.sh*) kill "${p##*/}" 2>/dev/null ;;
    esac
done
sleep 1
for p in /proc/[0-9]*; do
    [ "${p##*/}" = "$$" ] && continue
    # A dying process can wedge a plain read on /proc/<pid>/cmdline forever
            # (procfs race, hit live 2026-10-23: guard stuck 8 min in pipe_read).
            # timeout 1 caps the worst case; a live process reads in microseconds.
            c=$(timeout 1 tr '\000' ' ' < "$p/cmdline" 2>/dev/null) || continue
    case "$c" in
        *$PM_DIR/guard.sh*)
            # Substring would also hit an editor or a grep on this path:
            # require the argv text before the script path to end in an
            # interpreter name ("sh"/"mksh"). Editors/grep fail this and
            # are left alone; every real guard form passes it.
            pre=" ${c%%$PM_DIR/guard.sh*} "
            case "$pre" in
                *" sh "|*" /system/bin/sh "|*" /system/bin/mksh ") ;;
                *) continue ;;
            esac
            kill -9 "${p##*/}" 2>/dev/null
            pm_logn "takeover: killed stale instance ${p##*/}"
            ;;
    esac
done
# A ghost still running the old trap code rm's the shared lock as it dies
# from the plain kill above; re-assert ownership so the fast path of
# pm_guard_pid works from the first tick.
mkdir -p "$PM_DIR/.guard_lock" 2>/dev/null
echo $$ > "$PM_DIR/.guard_lock/pid"

pm_logn "up: tick loop entered (pid $$, pmax v1.0.0-beta.5)"

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

# Seed the snapshot before the first tick.  The WebUI polls every three
# seconds, and the gap between "apply finished" and "first tick wrote .state"
# is exactly the window in which the page would render a blank hold field.
# Seeded AFTER apply on purpose: seeding before it would publish the restored
# factory values for a second, which is worse than blank.
_s0=""; IFS= read -r _s0 < "$CFG/policy0/scaling_max_freq" 2>/dev/null
_s6=""; IFS= read -r _s6 < "$CFG/policy6/scaling_max_freq" 2>/dev/null
_sg=""; IFS= read -r _sg < "$CFG/policy0/scaling_governor" 2>/dev/null
echo "on|${_s0}|${_s6}|0|0|0|0|0|${_sg}" > "$PM_STATE.tmp" 2>/dev/null
mv "$PM_STATE.tmp" "$PM_STATE" 2>/dev/null

# State machine:
#   HELD=1   we own the ceiling at its current stage
#   HELD=0   we handed everything back and are waiting for a real cooldown
# STAGE tracks how many notches the ceiling has been dropped.  Stage 0 is the
# full SoC spec; each stage steps down to a real ladder entry.  Past stage 2
# the module stops trying.
HELD=1
COOL=0
SAVED_FAILS=0
GPULOST=0
ST_TBL_OK=""
STREAK=0
STAGE=0
RECOVER=0
STAGE_HOLD=0
DEAD=0
DEAD_C=0
DEAD_S=0
# How many silicon inputs last reported something other than the spoofed
# 25000.  Only a full sweep can answer that, so it is refreshed on a slower
# cadence than the peak and starts optimistic: 0 here would fire the dead-sensor
# backstop on the very first tick, before any sweep has run.
PM_REAL=99
# Highest silicon reading across the current rotation window, plus how many
# ticks ago it was last refreshed.  The rotating sweep reads a quarter of the
# family per tick, so a single reading is not the family maximum; this is,
# and the trip decision uses it.
PEAK_C=0
PEAK_AGE=0
# Consecutive samples in which the framework override read back false.  Drives
# the "spoof lost / recovered" log lines; reset on the first true sample.
OV_LOSS=0
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
# Seeded here for the start-up window before the first tick; the loop body
# re-reads it every tick so a WebUI toggle takes effect within one second.
SPOOF_MODE=$(cat "$PM_DIR/.spoof" 2>/dev/null)

while true; do
    # Tick counter advances at the top of the body so every throttled block
    # below sees the same beat.  It used to advance after the snapshot write,
    # which meant the launcher scan (five-tick cadence) ran one tick stale
    # against the override re-assert (also five-tick) -- two periodic jobs
    # that were meant to interleave silently drifted apart.
    STREAK=$((STREAK + 1))

    # ---- shutdown paths -------------------------------------------------
    if [ -f "$PM_DIR/disable" ]; then
        pm_logn "ksu: disabled, restoring"
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
    # a few builtin reads per tick, one write only when off-root.
    # The freezer line is "0::<cgroup>" and it is NOT the first line of
    # /proc/<pid>/cgroup (lines 2-4 carry blkio/cpu/cpuset/memory), so the
    # file must be walked line by line -- a single read saw only
    # "4:memory:/apps/..." and matched nothing, making this guard a
    # permanent no-op that still looked correct in the source.  The doubled dollar
    # here has also been silently folded to a single one twice by editors
    # that treat it as an escape sequence; build.mjs now refuses to package
    # the degraded form.
    CG=""

    while IFS= read -r _cg_line_; do
        case "$_cg_line_" in
            0::*) CG=${_cg_line_#0::} ;;
        esac
    done < "/proc/$$/cgroup" 2>/dev/null
    if [ -n "$CG" ] && [ "$CG" != "/" ]; then
        echo $$ > /sys/fs/cgroup/cgroup.procs 2>/dev/null \
            && pm_logw "cgroup: left frozen cgroup $CG (Android freezer may suspend the tick loop)"
    fi

    # ---- thermald must live ---------------------------------------------
    if [ "$(getprop init.svc.mi_thermald)" != "running" ]; then
        start mi_thermald 2>/dev/null
        # Log only on the state transition: a daemon that never comes up would
        # otherwise write this line every tick and flush the real history out
        # of the 32 KB log window.
        [ "$THERMALD_WAS" = "down" ] || pm_logn "thermald: restarted"
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
        pm_logw "stage_reset: stage file cleared externally, back-off state reset"
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
        pm_logn "profile: switched to $now_profile, thermal state reset (grace 15)"
    fi

    # ---- temperature -----------------------------------------------------
    # Steady state sweeps a quarter of the silicon family per tick (thermal
    # time constants make a 4 s sweep lossless); the full family runs whenever
    # the sweep suspects a trip, so a back-off always decides on real maxima.
    # One fork for both thresholds instead of four: they live on the same line
    # of the same file and the guard asks for both every second.
    set -- $(pm_trip_pair)
    TRIPC=$1
    TRIPS=$2
    # The switch can be flipped from the WebUI at any moment, so it is read
    # every tick rather than only on a preset change (the old placement meant
    # toggling it did nothing until the next preset switch).  Two builtin
    # reads, no fork.
    SPOOF_MODE=""; IFS= read -r SPOOF_MODE < "$PM_DIR/.spoof" 2>/dev/null
    ZONES_KERNEL=""; IFS= read -r ZONES_KERNEL < "$PM_ZONES" 2>/dev/null
    # While the spoof is on, every zone the silicon tripwire reads reports
    # 25 C: the chip side of the protection story is off, and the chassis
    # tripwire is the last software layer still measuring anything real.
    # Tightening it by 3 C costs nothing and buys back a little margin.
    # The framework override alone does not blind the sensors, so the kernel
    # preset (which only uses the lock) keeps the normal threshold.
    # Only the emul tiers blind the silicon tripwire; "lock" leaves every
    # sensor reporting, so it keeps the normal chassis threshold.
    case "$SPOOF_MODE" in
        normal|max|on)
            [ "$ZONES_KERNEL" != "kernel" ] && TRIPS=$((TRIPS - 3000)) ;;
    esac
    # The rotating sweep reads a quarter of the silicon family per tick, so a
    # single reading is not the family maximum: a hot zone that lands on one of
    # the three skipped quarters is invisible for that tick.  PEAK_C holds the
    # highest reading over the last four ticks (a full rotation) and the trip
    # decision uses it, so no peak can slip between quarters.
    #
    # It is a sliding window, not a boundary reset.  The earlier version
    # overwrote PEAK_C with the current quarter's TC every fourth tick, which
    # collapsed a four-tick peak back to a one-quarter sample on exactly the
    # tick the window closed -- the opposite of what the accumulator is for.
    # Now the peak is only replaced when it is re-read lower (PEAK_AGE counts
    # how long that has been true) and it is dropped after five ticks, one
    # more than a full rotation, so it can never go stale by construction.
    pm_temp_compute_rot
    TC=$PM_TROT
    if [ "$TC" -ge "$PEAK_C" ]; then
        PEAK_C=$TC
        PEAK_AGE=0
    else
        PEAK_AGE=$((PEAK_AGE + 1))
        [ "$PEAK_AGE" -ge 5 ] && { PEAK_C=$TC; PEAK_AGE=0; }
    fi
    TS=$(pm_temp_skin)
    if [ "$TC" -ge "$TRIPC" ] || [ "$PEAK_C" -ge "$TRIPC" ] || [ "$TS" -ge "$TRIPS" ]; then
        # Decide on real maxima, never on a quarter sample.
        pm_temp_compute
        TC=$PM_TMAX
        PEAK_C=$TC
        PEAK_AGE=0
        TS=$(pm_temp_skin)
    fi
    # Every sensor dead reads as 0/0, which can never trip: the module would
    # hold the full ceiling forever with nothing watching the silicon.  Zone
    # numbers are hardcoded and a ROM update can move them, so this is a real
    # failure mode, not a hypothetical.  30 consecutive dead ticks (~30 s)
    # force a stage-1 back-off and log it; one live reading re-arms silently.
    # The two families fail independently (hardcoded zone numbers drift per
    # ROM), so each gets its own dead counter: a skin-only outage must not
    # look healthy just because the silicon zones still answer.
    # A zero maximum is the obvious dead case, but with the emul layer on it can
    # never happen: 48 of the 57 inputs are pinned at 25000, so even a total
    # PMIC outage still reports a healthy-looking peak.
    #
    # What is checked instead is how many inputs are NOT reading the spoofed
    # value.  That set is exactly the sensors still telling the truth -- 8 PMIC
    # junctions under max, 29 under normal, all 57 with the spoof off -- and
    # its floor is what the backstop should defend, not a fixed zone count.
    # PM_MIN_LIVE is that floor, set per tick from the active tier.
    # PM_REAL only means anything after a full sweep; the rotating read above
    # sees a quarter of the family and would report a quarter of the truth.
    # It is refreshed on a 30-tick cadence below, which matches DEAD_C's own
    # 30-tick threshold, so no outage can hide inside the sampling gap.
    #
    # Floor is 1: under any tier at least one PMIC junction must still report
    # something other than the spoofed value.  Zero means the silicon family
    # has gone dark and the peak being trusted is an artefact.
    if [ "$TC" -eq 0 ] || [ "$PM_REAL" -lt 1 ]; then
        DEAD_C=$((DEAD_C + 1))
    else
        [ "$DEAD_C" -ge 30 ] && pm_logn "sensors_back: silicon after $DEAD_C dead ticks"
        DEAD_C=0
    fi
    if [ "$TS" -eq 0 ]; then DEAD_S=$((DEAD_S + 1)); else
        [ "$DEAD_S" -ge 30 ] && pm_logn "sensors_back: skin after $DEAD_S dead ticks"
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
                # scaling_max_freq moves with the stage.  cpu_limits alone is
                # invisible to anything reading scaling_max_freq / cur_freq --
                # under TABLE_IN_CHARGE the hold block skips, so the enforced
                # stage showed in cpu_limits while scaling_max_freq (and every
                # detector app reading it) still reported the preset ceiling:
                # the UI said 4.32, the device ran 3.80, neither lied and
                # nothing explained the difference.
                echo "$NA" > "$CFG/policy0/scaling_max_freq" 2>/dev/null
                echo "$NB" > "$CFG/policy6/scaling_max_freq" 2>/dev/null
                echo "backoff $STAGE" > "$PM_STATE.tmp" 2>/dev/null; mv "$PM_STATE.tmp" "$PM_STATE" 2>/dev/null
                pm_loge "outage: sensors dead 30+30 ticks, forcing stage 1 silicon_dead=$DEAD_C skin_dead=$DEAD_S ceiling=$NA/$NB"
            elif [ $((DEAD % 300)) -eq 0 ]; then
                pm_logw "outage: sensors dead $DEAD ticks, holding back-off"
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
                pm_loge "trip: $WHICH limit exceeded, restoring everything lim=$LIM tc=$TC ts=$TS stage=$STAGE ceiling=$(pm_base0)/$(pm_base6)"
                sh "$PM_DIR/restore.sh" >/dev/null 2>&1
                HELD=0; COOL=0
                echo "tripped $WHICH" > "$PM_STATE.tmp" 2>/dev/null; mv "$PM_STATE.tmp" "$PM_STATE" 2>/dev/null
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
                # Same scaling_max_freq sync as the outage path: the stage
                # must be visible on the nodes detector apps and the UI read,
                # not only inside thermal_message's cpu_limits.
                echo "$a" > "$CFG/policy0/scaling_max_freq" 2>/dev/null
                echo "$b" > "$CFG/policy6/scaling_max_freq" 2>/dev/null
                echo "backoff $STAGE" > "$PM_STATE.tmp" 2>/dev/null; mv "$PM_STATE.tmp" "$PM_STATE" 2>/dev/null
                pm_logw "trip: $WHICH limit exceeded, backing off lim=$LIM tc=$TC ts=$TS stage=$STAGE ceiling=$a/$b was=$c0/$c6"
                COOL=0
                STAGE_HOLD=0
            else
                # Inside the 15-tick hold window: deliberately ignored, so a
                # single sensor spike cannot chatter the ceiling.  Logged at a
                # slow cadence anyway -- silence at 105 C is indistinguishable
                # from a dead sensor from the outside.
                [ $((STREAK % 30)) -eq 0 ] && pm_logd "trip_hold: inside hold window $STAGE_HOLD/15, ignored sensor=$WHICH"
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
                        0)
                            rm -f "$PM_STAGE"
                            # Scaling must follow the stage back up.  Under
                            # TABLE_IN_CHARGE the hold block skips writes, so
                            # without this the scaling_max_freq nodes stayed
                            # at the stage-1 value after every recovery: the
                            # daemon held the real ceiling per its table while
                            # scaling_max_freq (what detector apps display)
                            # kept reporting the back-off.
                            echo "$(pm_base0)" > "$CFG/policy0/scaling_max_freq" 2>/dev/null
                            echo "$(pm_base6)" > "$CFG/policy6/scaling_max_freq" 2>/dev/null ;;
                        1)
                            # Stage 1 is 88% of the preset base -- the same
                            # ratio the down-step used, so recovery mirrors
                            # back-off whatever preset is active.  The old
                            # hardcoded value was the extreme preset's 88%
                            # and would over-clock every other preset.
                            na=$(pm_step_down "$CFG/policy0" "$(pm_base0)" 88)
                            nb=$(pm_step_down "$CFG/policy6" "$(pm_base6)" 88)
                            echo "$na $nb" > "$PM_STAGE"
                            echo "$na" > "$CFG/policy0/scaling_max_freq" 2>/dev/null
                            echo "$nb" > "$CFG/policy6/scaling_max_freq" 2>/dev/null ;;
                    esac
                    pm_logn "recover: to stage $STAGE tc=$TC ts=$TS ceiling=$a/$b"
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
                pm_logn "rearm: temp back under limits, swapping table for $PK tc=$TC ts=$TS stage=$STAGE"
                # A stage-2-exceeded exit went through restore.sh, which put
                # the vendor thermal table back and wiped the working files.
                # pm_apply_all re-creates the latter (pm_state_rebuild is its
                # first step); the table needs re-installing afterwards,
                # because it is the one thing apply does not own.
                pm_apply_all >/dev/null 2>&1
                PKZ=$(cat "$PM_ZONES" 2>/dev/null)
                case "$now_profile" in
                    省电) PK=powersave ;;
                    均衡) PK=balanced ;;
                    性能) PK=performance ;;
                    *)    PK=extreme ;;
                esac
                # Failure is logged and non-fatal: the re-pin loop holds.
                if [ "$PKZ" = "module" ] && [ -d "$PM_DIR/thermal/$PK" ]; then
                    . "$PM_DIR/lib/thermal.sh"
                    pm_thermal_swap "$PK" >/dev/null 2>&1 || pm_loge "rearm: thermal swap FAILED for $PK (thermald keeps old table)"
                fi
                held_reset
                HELD=1; COOL=0
                echo "held" > "$PM_STATE.tmp" 2>/dev/null; mv "$PM_STATE.tmp" "$PM_STATE" 2>/dev/null
            fi
        fi
    fi

    # ---- hold the ceiling ---------------------------------------------
    # Builtin reads: these two are compared every tick and a cat fork each is
    # 6 ms of a 1 s budget spent on eight ASCII digits.
    c0=""; IFS= read -r c0 < "$CFG/policy0/scaling_max_freq" 2>/dev/null
    c6=""; IFS= read -r c6 < "$CFG/policy6/scaling_max_freq" 2>/dev/null
    if [ "$HELD" = "1" ]; then
        # Snapped, not raw: the kernel rounds whatever it is given, so the
        # readback can only ever equal a value that is on the ladder.
        a=$(pm_hold0); b=$(pm_hold6)
        # A thermal table in charge (profile.sh installed one) makes the
        # daemon enforce the ceiling itself; re-pinning every tick would
        # only fight the policy doing our job.  Reads stay, writes gate.
        # Trusting the stamp alone once bit us: the stamp was written before
        # the daemon reload was verified, and joyose/powerkeeper can wipe the
        # override directory behind our back -- either way the table was gone
        # while the gate said otherwise, and the ceiling lost its keeper
        # until the next preset switch.  Three conditions must hold: the
        # stamp exists, the daemon's last-decrypted table is non-empty, and
        # that decrypt is not older than the stamp (i.e. the daemon re-read
        # AFTER we installed our table).  Otherwise fall back to re-pinning.
        TABLE_IN_CHARGE=0
        # Two stat forks per tick would double the loop's fork budget, and a
        # cloud overwrite does not happen at second granularity: refresh the
        # check every 5th tick, reuse the verdict between.  ST_TBL_OK stays
        # uninitialized until the first evaluation so tick 1 never inherits a
        # stale "yes".
        #
        # The freshness test compares decrypt.txt against .thermal_ts, the
        # second the swap wrote down right before bouncing the daemon: any
        # decrypt produced by OUR restart is at or after it.  Comparing the
        # stamp's own mtime would read backwards -- the daemon rewrites
        # decrypt before the stamp lands, so stamp-mtime > decrypt-mtime is
        # the healthy case, not the suspicious one.
        if [ -z "$ST_TBL_OK" ] || [ $((STREAK % 5)) -eq 0 ]; then
            ST_TBL_OK=0
            if [ -f "$PM_DIR/.thermal_mode" ] && [ -s "$T_ROOT/decrypt.txt" ] && [ -f "$PM_DIR/.thermal_ts" ]; then
                TS_M=$(_pm_mtime "$PM_DIR/.thermal_ts")
                DT_M=$(_pm_mtime "$T_ROOT/decrypt.txt")
                [ -n "$TS_M" ] && [ -n "$DT_M" ] && [ "$DT_M" -ge "$TS_M" ] && ST_TBL_OK=1
            fi
        fi
        [ "$ST_TBL_OK" = "1" ] && TABLE_IN_CHARGE=1
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
                pm_logd "repin: ceiling re-applied target=$a/$b was=$c0/$c6 fixups=$SAVED_FAILS"
            fi
        fi
        # Keep the GPU latch open.  msm-adreno-tz re-arms it after any thermal
        # event, and a single re-latch costs 270 MHz until the next reboot.
        # Same cooling-device cache as apply.sh: one type-read per latch
        # instead of 40 per tick.
        g=""; IFS= read -r g < "$GPU/thermal_pwrlevel" 2>/dev/null
        if [ "$g" != "0" ]; then
            CDEV=$(cat "$PM_DIR/.gpu_cdev" 2>/dev/null)
            ct=""
            [ -n "$CDEV" ] && IFS= read -r ct < "$CDEV/type" 2>/dev/null
            if [ -n "$CDEV" ] && [ "$ct" = "gpu" ]; then
                echo 0 > "$CDEV/cur_state" 2>/dev/null
            else
                for c in /sys/class/thermal/cooling_device*; do
                    t=""; IFS= read -r t < "$c/type" 2>/dev/null
                    [ "$t" = "gpu" ] || continue
                    echo "$c" > "$PM_DIR/.gpu_cdev" 2>/dev/null
                    echo 0 > "$c/cur_state" 2>/dev/null
                done
            fi
            echo 1100000000 > "$GPU/devfreq/max_freq" 2>/dev/null
            echo 0 > "$GPU/thermal_pwrlevel" 2>/dev/null
            g2=""; IFS= read -r g2 < "$GPU/thermal_pwrlevel" 2>/dev/null
            if [ "$g2" = "0" ]; then
                # Re-assert the ceiling the user or the preset chose, not the
                # full ladder: pin_gpu() writes pm_gpu_level for the same
                # reason, and a hardcoded 0 would quietly undo a lower preset's
                # GPU cap on the first thermal re-latch.
                pm_wr "$GPU/max_pwrlevel" "$(pm_gpu_level)"
                pm_logd "gpu_latch: released (was pwrlevel $g)"
            else
                # Release failed and the ceiling is still clamped.  This used
                # to be silent: under sustained heat the daemon re-latches
                # every tick, max_pwrlevel stays at the clamp, and nothing in
                # the log ever says why the GPU looks slow.  Same throttling
                # shape as SAVED_FAILS: first three verbatim, then 1/60.
                GPULOST=$((GPULOST + 1))
                if [ "$GPULOST" -le 3 ] || [ $((GPULOST % 60)) -eq 0 ]; then
                    pm_logw "gpu_latch: STUCK at pwrlevel $g2 lost=$GPULOST (thermald keeps re-clamping)"
                fi
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
        # Walk /proc directly instead of pgrep: pgrep -f costs two forks
        # per round and matches any cmdline *containing* the package name
        # (an editor with the file open, a grep on a log).  The case below
        # only matches an argv head or a path component that IS the
        # package -- same guardrail; two forks per process, not one pgrep.
        for p in /proc/[0-9]*; do
            [ -r "$p/cmdline" ] || continue
            # cmdline is NUL-terminated with NO trailing newline: a line read
            # always hits EOF, so `read ... || continue` skipped EVERY process
            # (852 iterations, 0 matches, 2026-10-22 measured).  Read the raw
            # bytes and strip NULs instead -- tr is two forks only on match
            # candidates that reach the case, none otherwise.
            # A dying process can wedge a plain read on /proc/<pid>/cmdline forever
            # (procfs race, hit live 2026-10-23: guard stuck 8 min in pipe_read).
            # timeout 1 caps the worst case; a live process reads in microseconds.
            c=$(timeout 1 tr '\000' ' ' < "$p/cmdline" 2>/dev/null) || continue
            case "$c" in
                com.miui.home*|com.android.systemui*|*/com.miui.home*|*/com.android.systemui*) ;;
                *) continue ;;
            esac
            adj=""; IFS= read -r adj < "$p/oom_score_adj" 2>/dev/null
            # The scan and its readout stay; the write is off by default.
            #
            # The value cannot be chosen by the module at all: AOSP ProcessList
            # defines -1000 as NATIVE_ADJ, "special code for native processes
            # that are not being managed by the system (so don't have an oom adj
            # assigned by the system)", with SYSTEM_ADJ at -900.  A launcher is
            # a managed app, so no fixed value exists that is correct for it --
            # AMS recomputes the adj from the app's foreground/visible state
            # (FOREGROUND_APP_ADJ is 0) and simply writes its own value back,
            # so a pin here is a write war at 5 s per side, not a protection.
            #
            # What was actually observed on this device: the 2026-10-23 launcher
            # restart loop.  What was NOT observed: any logcat evidence tying it
            # to this write.  The old comment asserted a mechanism that no
            # capture supports; this one states the constant and leaves the
            # diagnosis to the device (see CHANGELOG beta.4/beta.5).
            #
            # PM_LAUNCHER_PIN is declared empty at the top of this file, so the
            # branch below is dead by construction.  It stays because removing
            # the scan would also remove the only readout of what AMS assigned.
            if [ -n "$adj" ] && [ "$adj" != "-1000" ] && [ -n "$PM_LAUNCHER_PIN" ]; then
                echo "$PM_LAUNCHER_PIN" > "$p/oom_score_adj" 2>/dev/null
                pm_logd "launcher_pin: ${p##*/} adj=$adj target=$PM_LAUNCHER_PIN"
            fi
        done
    fi

    # ---- snapshot for the UI ---------------------------------------------
    # Single line, pipe separated, no spaces: the WebUI splits it and never
    # runs a second command to learn the same thing.
    # state|p0|p6|gpu|ddr|llcc|tempC|gov
    p0=""; IFS= read -r p0 < "$CFG/policy0/scaling_cur_freq" 2>/dev/null
    p6=""; IFS= read -r p6 < "$CFG/policy6/scaling_cur_freq" 2>/dev/null
    gclk=""; IFS= read -r gclk < "$GPU/clock_mhz" 2>/dev/null
    ddr=""; IFS= read -r ddr < "$BUS/DDR/cur_freq" 2>/dev/null
    llc=""; IFS= read -r llc < "$BUS/LLCC/cur_freq" 2>/dev/null
    gov=""; IFS= read -r gov < "$CFG/policy0/scaling_governor" 2>/dev/null
    if [ "$HELD" = "1" ]; then
        if [ "$STAGE" -gt "0" ]; then st="backoff $STAGE"; else st=on; fi
    elif [ "$TC" -ge "$TRIPC" ] || [ "$TS" -ge "$TRIPS" ]; then st="tripped silicon"
    else st="tripped waiting"
    fi
    echo "$st|$p0|$p6|$gclk|$ddr|$llc|$((TS / 1000))|$((TC / 1000))|$gov" > "$PM_STATE.tmp" 2>/dev/null
    mv "$PM_STATE.tmp" "$PM_STATE" 2>/dev/null

    if [ $((STREAK % 30)) -eq 0 ]; then
        mem=""; while IFS= read -r _mi_; do
            # toybox prints "MemAvailable:    2903864 kB": unquoted expansion
            # splits on whitespace, so $2 is the bare number (unit dropped).
            case "$_mi_" in MemAvailable:*) set -- $_mi_; mem=$2 ;; esac
        done < /proc/meminfo 2>/dev/null
        pm_logd "alive held=$HELD stage=$STAGE tc=${TC:-?} ts=${TS:-?} gov=${gov:-?} c0_max=${c0:-?} c6_max=${c6:-?} c0_cur=${p0:-?} c6_cur=${p6:-?} gpu=${gclk:-?} ddr=${ddr:-?} llcc=${llc:-?} mem_kb=${mem:-?} real=${PM_REAL:-99} spoof=$SPOOF_MODE ov=${OV##*IsStatusOverride:}"
    fi

    # ---- spoof freshness ------------------------------------------------
    # Neither layer decays on its own; both are cleared by someone writing.
    # ThermalManagerService has exactly two writers of mIsStatusOverride --
    # runReset() and runOverrideStatus() -- and nothing in the temperature
    # callback clears it, so the override only drops when a reset command runs.
    # The emul layer likewise has no kernel-side timeout: emul_temp_store() is
    # a single assignment and thermal_helpers only substitutes on read.
    #
    # The re-asserts below are therefore insurance against *our own* reset
    # paths (tier switches, restore, preset changes) rather than against an
    # unknown decay.  They cost ~50 ms per call and keep the windows shorter
    # than any 1 s status poller, which is cheap enough to keep.
    # Any tier other than off wants the framework lock, including "lock" which
    # exists for exactly that and nothing else.
    case "$SPOOF_MODE" in
        lock|normal|max|on) SPOOF_ACTIVE=yes ;;
        *)                  SPOOF_ACTIVE=no ;;
    esac
    if [ "$SPOOF_ACTIVE" = "yes" ] && [ $((STREAK % 5)) -eq 0 ]; then
        if cmd thermalservice override-status 0 >/dev/null 2>&1; then
            : # lock re-asserted
        else
            pm_logw "spoof: override-status write rc=1 (framework unreachable?)"
        fi
    fi
    # Publish the override flag for the WebUI snapshot path: the guard has to
    # ask the framework anyway every fifth tick, and letting the page read
    # this file instead of forking a dumpsys every three seconds removes the
    # most expensive call in the refresh loop.  Seeded at startup (STREAK 0
    # counts) so the page has an answer from its very first refresh rather
    # than after fifteen ticks.
    # Sampled on the same cadence as the re-assert it is reporting on: a
    # slower sample would publish a flag the framework has already moved.
    if [ $((STREAK % 5)) -eq 0 ]; then
        OV=$(dumpsys thermalservice 2>/dev/null | grep -m1 IsStatusOverride | tr -d ' ')
        if [ -n "$OV" ]; then
            echo "$OV" > "$PM_DIR/.override.tmp" 2>/dev/null
            mv "$PM_DIR/.override.tmp" "$PM_DIR/.override" 2>/dev/null
        fi
        # Hold-loss counter.  Without this the only evidence that the spoof is
        # still alive lived in a state file nobody reads unless the UI is open,
        # so "the lock stopped working an hour ago" had no symptom at all.
        # One log line per loss, and one recovery line, is the cheapest signal
        # that can be checked after the fact.
        case "$OV" in
            *Override:false*|*Override:false)
                OV_LOSS=$((OV_LOSS + 1))
                if [ "$OV_LOSS" -eq 1 ]; then
                    pm_logw "spoof: framework override LOST, re-asserting (1st of this outage)"
                elif [ $((OV_LOSS % 60)) -eq 0 ]; then
                    pm_logw "spoof: framework override still lost lost_samples=$OV_LOSS approx_s=$((OV_LOSS * 5))"
                fi ;;
            *Override:true*)
                if [ "$OV_LOSS" -gt 0 ]; then
                    pm_logn "spoof: framework override recovered lost_samples=$OV_LOSS"
                fi
                OV_LOSS=0 ;;
        esac
    fi
    # emul refresh stays on the 30 s cadence: best-effort visual layer.  The
    # lock tier has no emul zones, so re-running the whole pass there would
    # cost ~400 ms of a 1 s tick to re-derive something that cannot decay.
    case "$SPOOF_MODE" in
        normal|max|on)
            [ $((STREAK % 30)) -eq 0 ] && apply_temp_spoof ;;
    esac
    # Full silicon sweep every 30 ticks purely to refresh PM_REAL.  The result
    # is discarded except for that count: the peak already comes from the
    # rotating window, and re-deriving it here would let a one-tick dip pull
    # PEAK_C down for no reason.  Cost is one sweep per 30 s, the same order as
    # the emul refresh already running on that cadence.
    if [ $((STREAK % 30)) -eq 0 ]; then
        pm_temp_compute
    fi
    if [ $((STREAK % 60)) -eq 0 ]; then
        # 32 KB threshold: a live tick is ~200 B/30 s, so the cap only bites
        # after hours of steady state -- but trip storms can write KBs per
        # second, and waiting ten minutes (the old cadence) let the file hit
        # 129 KB in the field. Check every minute; wc -c on a 32 KB file
        # costs one fork and is nothing next to the storm it bounds.
        pm_log_trim
    fi

    # One sleep, not two halves.  Measured on this box: 0.5 + 0.5 costs the
    # same wall clock as a single 1 s wait plus an extra fork (6 ms), so
    # splitting it buys nothing but a slower tick.
    sleep 1
done