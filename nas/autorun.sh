#!/bin/sh
# QTS autorun hook for the QNAP TS-433 NAS - lives on the NAS flash config
# partition and runs at boot when Control Panel -> Hardware -> "Run user
# defined processes during startup" is enabled.
# The flash partition is unmounted after boot, so copy the watchdog to tmpfs
# and run it detached from there.

cp /tmp/config/nic-watchdog.sh /tmp/nic-watchdog.sh
chmod 755 /tmp/nic-watchdog.sh
setsid /tmp/nic-watchdog.sh >/dev/null 2>&1 < /dev/null &
