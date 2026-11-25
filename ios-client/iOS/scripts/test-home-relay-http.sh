#!/bin/sh
set -eu
ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT HUP INT TERM
python3 - "$ROOT" "$OUT" <<'PY'
from pathlib import Path
import sys
r,o=map(Path,sys.argv[1:])
p=(r/'AirSIM/VoIPPushController.swift').read_text()
media=(r/'AirSIM/IPhoneCloudCallSession.swift').read_text()
s=lambda v,a,b:v[v.index(a):v.index(b)]
(o/'Phone.swift').write_text('import Foundation\n'+s(media,'enum CloudMediaTransport:','enum CloudMediaTransportNegotiator')+s(p,'enum VoIPPushPayloadError:','enum CallTransport:')+s(p,'enum RelayEndpoint {','enum VoIPPushToken {')+s(p,'enum RelayConfiguration {','enum RelayHealthValidation {'))
PY
cat > "$OUT/main.swift" <<'SWIFT'
import Foundation
let home = "relay-fixture.invalid:18787"
let uuid = UUID(uuidString:"00000000-0000-4000-8000-000000000001")!
let route = "/v1/calls/\(uuid.uuidString.lowercased())/connect"
let secret = String(repeating: "z", count: 32)
var failures = 0
func check(_ name: String, _ yes: Bool) {
    print(yes ? "PASS \(name)" : "FAIL \(name)")
    if !yes { failures += 1 }
}
func incoming(_ raw: String, _ token: String = secret) -> [AnyHashable: Any] {
    ["event":"incoming_call", "call_id":"test-only", "call_uuid":uuid.uuidString, "media_url":raw, "call_secret":token]
}
func phone(_ raw: String, _ token: String = secret) -> URL? {
    (try? IncomingVoIPCall(userInfo: incoming(raw, token)))?.authenticatedMediaURL
}
func watch(_ raw: String) -> URL? {
    guard let p = try? WatchVoIPCall(userInfo: incoming(raw)), case let .cloud(u) = p.media else { return nil }
    return u
}
func role(_ u: URL?) -> String? { u.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems?.first(where: {$0.name=="role"})?.value } }
check("HTTP health", RelayEndpoint.url(base:"http://"+home,path:"healthz")?.absoluteString=="http://"+home+"/healthz")
check("HTTP device register", RelayEndpoint.url(base:"http://"+home,path:"v1/devices/register")?.scheme=="http")
check("HTTP command result", RelayEndpoint.url(base:"http://"+home,path:"v2/commands/result")?.scheme=="http")
check("saved home HTTPS corrects to HTTP", RelayConfiguration.effectiveURL(stored:"https://"+home,buildSetting:"http://"+home,bundleID:"com.heroxhs.airsim")=="http://"+home)
check("public HTTPS intact", RelayEndpoint.url(base:"https://relay.example.invalid",path:"healthz")?.scheme=="https")
check("public HTTP blocked", RelayEndpoint.url(base:"http://relay.example.invalid:18787",path:"healthz")==nil)
check("other private host blocked", RelayEndpoint.url(base:"http://192.168.1.13:18787",path:"healthz")==nil)
check("different port blocked", RelayEndpoint.url(base:"http://relay-fixture.invalid:18788",path:"healthz")==nil)
check("HTTP URL credentials blocked", RelayEndpoint.url(base:"http://user:pass@"+home,path:"healthz")==nil)
check("iPhone incoming WS", role(phone("ws://"+home+route)) == "iphone")
check("Watch incoming WS", role(watch("ws://"+home+route)) == "watch")
check("iPhone outgoing WS", (try? IncomingVoIPCall(outgoingCallID:"out", uuid:uuid, number:"0", secret:secret, mediaURL:URL(string:"ws://"+home+route)!))?.authenticatedMediaURL?.scheme=="ws")
check("wrong media path blocked", phone("ws://"+home+"/v1/other")==nil)
check("mismatched call UUID blocked", phone("ws://"+home+route.replacingOccurrences(of:"000000000001",with:"000000000002"))==nil)
check("public WS blocked", phone("ws://relay.example.invalid"+route)==nil && watch("ws://relay.example.invalid"+route)==nil)
check("user info media blocked", phone("ws://user@"+home+route)==nil)
check("short token blocked", phone("ws://"+home+route,"short")==nil)
check("public WSS unchanged", role(phone("wss://relay.example.invalid"+route))=="iphone" && role(watch("wss://relay.example.invalid"+route))=="watch")
if failures > 0 { exit(1) }
SWIFT
xcrun swiftc -D AIRSIM_HOME_RELAY_TEST "$OUT/Phone.swift" "$ROOT/Shared/WatchCallPayload.swift" "$OUT/main.swift" -o "$OUT/run"
"$OUT/run"
