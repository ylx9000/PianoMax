#!/system/bin/sh
# PianoMax - install hook
# Copyright (C) 2026 ylx9000
# Licensed under the PolyForm Noncommercial License 1.0.0.

umask 022
chmod 755 "$MODPATH"/*.sh 2>/dev/null
chmod 755 "$MODPATH"/lib/*.sh 2>/dev/null
chmod -R 755 "$MODPATH/webroot" 2>/dev/null

ui_print "- PianoMax for Xiaomi Pad 8 Pro (piano / SM8750P)"
ui_print "- CPU 3532800 / 4320000, GPU up to 1100, DDR 4761000, LLCC 1211000"
ui_print "- temperature readings stay unmodified; hardware protection stays armed"
ui_print "- open the WebUI from the KernelSU module card to configure"

# Which manager is installing us decides what to promise.  The shared helper
# is copied next to this script during staging, so source it from MODPATH.
if [ -f "$MODPATH/lib/common.sh" ]; then
    . "$MODPATH/lib/common.sh"
    PM_ENV=$(pm_detect_root)
    PM_MGR=${PM_ENV%%|*}
    case "$PM_MGR" in
        ksu)        ui_print "- manager: KernelSU ($PM_ENV)" ;;
        apatch)     ui_print "- manager: APatch ($PM_ENV)" ;;
        magisk)     ui_print "- manager: Magisk ($PM_ENV)" ;;
        rootonly)   ui_print "- manager: none, bare root; supervisor features will be limited" ;;
        *)          ui_print "- manager: unrecognized ($PM_ENV); continuing with standard paths" ;;
    esac
fi
