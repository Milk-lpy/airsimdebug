#!/bin/sh
set -eu

fail() {
    printf '%s\n' "$*" >&2
    exit 1
}

[ "$#" -eq 1 ] || fail "Usage: $0 signed.ipa|signed.app|signed.xcarchive"
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
key=com.apple.developer.calling-app

read_plist() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null
}

/usr/bin/codesign -d --entitlements - "$app" > "$signed" 2>/dev/null ||
    fail "No readable code signature. Use the final package after signing."
/usr/bin/plutil -lint -s "$signed" ||
    fail "The signature has no readable entitlement plist."

signed_calling=$(read_plist "$signed" "$key" || true)
printf 'Signed Default Calling entitlement: %s\n' "${signed_calling:-missing}"
if read_plist "$info" UIBackgroundModes | /usr/bin/grep -qx ' *voip'; then
    voip=yes
else
    voip=no
fi
printf 'Voice over IP background mode: %s\n' "$voip"
printf 'Signed APNs environment: %s\n' "$(read_plist "$signed" aps-environment || printf missing)"

profile_calling=
if [ -f "$app/embedded.mobileprovision" ]; then
    /usr/bin/security cms -D -i "$app/embedded.mobileprovision" > "$profile" ||
        fail "Cannot decode the embedded provisioning profile."
    profile_calling=$(read_plist "$profile" "Entitlements:$key" || true)
    printf 'Embedded profile Default Calling authorization: %s\n' "${profile_calling:-missing}"
else
    printf '%s\n' 'Embedded profile: absent. Provisioning cannot be confirmed for a sideloaded app.'
fi

[ "$signed_calling" = true ] || fail "The final app signature lacks Default Calling."
[ "$voip" = yes ] || fail "The final app Info.plist lacks the voip background mode."
[ "$profile_calling" = true ] || fail "Verify with the profile that authorizes this signed sideload build."
printf '%s\n' 'Default Calling signing and background-mode checks passed.'
