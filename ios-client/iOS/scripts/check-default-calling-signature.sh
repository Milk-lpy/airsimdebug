#!/bin/sh
set -eu

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

scope=auto
if [ "${1:-}" = --full ]; then
    scope=full
    shift
fi
[ "$#" -eq 1 ] || fail "Usage: $0 [--full] signed.ipa|signed.app|signed.xcarchive"
[ "$(uname -s)" = Darwin ] || fail "Run this check on the Mac used to sign AirSIM."

umask 077
work=$(mktemp -d "${TMPDIR:-/tmp}/airsim-call-signature.XXXXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM

case "$1" in
    *.ipa)
        /usr/bin/ditto -x -k "$1" "$work"
        set -- "$work"/Payload/*.app
        ;;
    *.xcarchive)
        set -- "$1"/Products/Applications/*.app
        ;;
    *.app) ;;
    *) fail "Supply the final signed IPA, app bundle or Xcode archive." ;;
esac
[ "$#" -eq 1 ] && [ -d "$1" ] || fail "Expected one main app bundle."
app=$1
info="$app/Info.plist"
signed="$work/signed.plist"
profile="$work/profile.plist"
/usr/bin/codesign -d --entitlements - --xml "$app" > "$signed" 2>/dev/null ||
    fail "No readable code signature. Use the final package after signing."
[ -f "$app/embedded.mobileprovision" ] ||
    fail "The sideloaded app has no embedded provisioning profile."
/usr/bin/security cms -D -i "$app/embedded.mobileprovision" > "$profile" ||
    fail "Cannot decode the embedded provisioning profile."

/usr/bin/python3 - "$signed" "$profile" "$info" "$scope" <<'PYTHON'
import plistlib
import sys

def read(path):
    with open(path, "rb") as stream:
        return plistlib.load(stream)

signature = read(sys.argv[1])
authorization = read(sys.argv[2]).get("Entitlements", {})
info = read(sys.argv[3])
build = str(info.get("CFBundleVersion", "")).split(".")[0]
full = sys.argv[4] == "full" or (build.isdigit() and int(build) >= 195)
keys = ["calling-app"]
if full:
    keys += ["dialing-app", "messaging-app", "carrier-messaging-app"]

issues = []
for suffix in keys:
    key = "com.apple.developer." + suffix
    for name, entitlements in (("signature", signature), ("embedded profile", authorization)):
        if entitlements.get(key) is True:
            print(f"{name}: {key} = true")
        else:
            issues.append(f"{name}: {key} must be boolean true")
if "voip" not in info.get("UIBackgroundModes", []):
    issues.append("Info.plist lacks the voip background mode")
print("Signed APNs environment:", signature.get("aps-environment", "missing"))
if issues:
    sys.exit("\n".join(issues))
print("Default communication entitlements and VoIP background mode verified.")
PYTHON
