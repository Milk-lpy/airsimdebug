#!/system/bin/sh
# Magisk late_start. No screen unlock, no force-stop, no system-wide override.
set -u
PATH=/system/bin:/system/xbin:/sbin
export PATH
pkg=com.airsim.phonecontrol.standalone
pkgbase=com.airsim.phonecontrol
log=/data/adb/airsim-startup.log
umask 077
exec >"$log" 2>&1
printf 'AirSIM startup %s\n' "$(date -Iseconds)"
# Wait outside Magisk's late_start sequence. Android keeps user data locked until first unlock.
(
until [ "$(getprop sys.boot_completed)" = 1 ] && dumpsys user | grep -Fq '0=RUNNING_UNLOCKED'; do
    sleep 10
done
if ! pm path --user 0 "$pkg" | grep -q '^package:'; then echo 'Skip: AirSIM is not installed.'; exit 0; fi
for name in StandaloneAgentService VoWLANGatewayService; do
    component="$pkg/$pkgbase.$name"
    if dumpsys activity services "$pkg" | grep -Fq "$component}"; then
        echo "$name already up."
    else
        am start-foreground-service --user 0 -n "$component" || exit 1
    fi
done
echo 'AirSIM startup check finished.'
) &
