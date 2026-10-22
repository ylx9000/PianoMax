# Encrypted thermal table variant for the extreme preset.
#
# Provenance: dumped from the vendor tree on OS3.0.309.0.WPYCNXM, decrypted
# with the table key (AES-128-CBC, key = IV = "thermalopenssl.h"), relaxed on
# the cpu0/cpu6/cpu7 device ceilings only -- charging, backlight, modem and
# temp_state segments are byte-identical to the vendor table -- re-encrypted
# and verified against a live daemon reload (decrypt.txt mtime moved; see
# lib/thermal.sh pm_thermal_verify).  Shipped in this directory; profile.sh
# installs it on preset switch, piano_diag.sh cross-checks the deployed bytes.
#
# EMPTY would mean the preset runs without a table swap and the guard keeps
# its re-pin loop.  That state is still supported by the code paths, but this
# directory is not empty and is not expected to be.
