# Encrypted thermal table variant for the performance preset.
#
# PRODUCTION step (device required): dump the vendor tables from
# /data/vendor/thermal/config, decrypt with the community-aes established table key,
# relax only the cpu0/cpu6/cpu7 device ceilings to the preset values while
# keeping charging, backlight, modem and temp_state segments byte-identical,
# re-encrypt, and drop the .conf files here.  build.mjs packages whatever
# lands in this directory; profile.sh installs it on preset switch.
#
# EMPTY = the preset runs without a table swap and the guard keeps its
# re-pin loop.  Both states are supported; nothing here is silently assumed.
