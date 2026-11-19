# Encrypted thermal table variant for the extreme preset.
#
# Provenance: dumped from the vendor tree on OS3.0.309.0.WPYCNXM, decrypted
# with the table key (AES-128-CBC, key = IV = "thermalopenssl.h"), relaxed on
# the cpu0/cpu6 device ceilings and the gpu monitor thresholds; charging,
# backlight, modem and temp_state segments are byte-identical to the vendor
# table -- re-encrypted and verified against a live daemon reload (decrypt.txt
# mtime moved; see lib/thermal.sh pm_thermal_verify).  Shipped in this
# directory; profile.sh installs it on preset switch, piano_diag.sh
# cross-checks the deployed bytes.
#
# Exactly what differs.  Of the 23 sections only three change; the other 20
# are byte-identical to the performance table shipped next door.  [SS-CPU0]
# and [SS-CPU6] keep their trip points and move only the target ladder.
# [MONITOR-GPU] is the one section where a threshold triplet itself is removed:
#   [SS-CPU0]  ladder raised: 3532800 through 44 C, then 3321600 at 45 C,
#              3072000 at 46 C, 2745600 at 48 C
#   [SS-CPU6]  ladder raised: 4320000 through 39 C, then 4089600 at 39.5 C,
#              3801600 at 40 C, 3072000 at 44 C
#   [MONITOR-GPU]  the first trip point is REMOVED.  The performance table
#              gates the GPU twice -- trig 25000 / clr 23000 / target 1 (the
#              660 MHz level) and trig 45000 / clr 42000 / target 5 (832 MHz).
#              This table keeps only the second pair, so 25000 and target 1
#              never appear: the GPU is never clamped to the low level by this
#              table, and the first GPU limit arrives at 45 C.
# Nothing else is edited.
#
# EMPTY would mean the preset runs without a table swap and the guard keeps
# its re-pin loop.  That state is still supported by the code paths, but this
# directory is not empty and is not expected to be.
