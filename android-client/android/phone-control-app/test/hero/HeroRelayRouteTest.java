package com.airsim.phonecontrol;

import java.net.URI;

final class HeroRelayRouteTest {
    static void check(boolean condition, String name) {
        if (!condition) throw new AssertionError(name);
    }
    public static void main(String[] args) {
        var home = URI.create("http://192.0.2.12:18787");
        check(HomeRelayRoute.allowsBase(home), "home allowed");
        for (String ip : new String[]{"192.0.2.12", "198.51.100.2"}) {
            String oldOrigin = "http://" + ip + ":18787", secure = "https://" + ip + ":18788";
            check(HomeRelayRoute.endpointBase(URI.create(oldOrigin + "/")).equals(secure), "old origin uses TLS");
            check(HomeRelayRoute.websocketBase(URI.create(oldOrigin)).equals("wss://" + ip + ":18788"), "old origin uses WSS");
            check(HomeRelayRoute.endpointBase(URI.create(secure)).equals(secure), "new origin stable");
            check(HomeRelayRoute.samePrivateRelay(home.toString(), secure), "preserve same pairing");
            for (String other : new String[]{secure + "/api", secure + "?id=x", secure + "#frag",
                    secure.replace("https://", "https://other@"), "https://" + ip + ":443", "https://different.example"}) {
                check(!HomeRelayRoute.samePrivateRelay(home.toString(), other), "distinct origin " + other);
            }
        }
        check(HomeRelayRoute.endpointBase(URI.create(home + "/v1")).equals(home + "/v1"), "legacy application path");
        check(HomeRelayRoute.websocketBase(URI.create("https://approved.example/relay/"))
                .equals("wss://approved.example/relay"), "TLS prefix preserved");
        check(HomeRelayRoute.allowsSocket(URI.create("ws://192.0.2.12:18787/v2/test?id=aaa")), "home WS path and query");
        check(!HomeRelayRoute.allowsSocket(URI.create("ws://other.example:18787/v2/test")), "other WS blocked");
        check(HomeRelayRoute.allowsSocket(URI.create("wss://approved.example/media?token=x")), "WSS retained");
        for (var s : new String[]{"http://192.0.2.12:80","http://192.0.2.120:18787",
                "http://user@192.0.2.12:18787","http://192.0.2.12:18787?other=x",
                "https://approved.example/#fragment", "http://evil.example:18787"}) {
            check(!HomeRelayRoute.allowsBase(URI.create(s)), s);
        }
        verifyManualAddresses();
        System.out.println("HomeRelayRoute smoke passed");
    }

    private static void verifyManualAddresses() {
        String[][] accepted = {
                {" 10.8.0.2 ", "https://10.8.0.2:18788"},
                {"10.8.0.2:443", "https://10.8.0.2:443"},
                {"https://10.8.0.2:443/", "https://10.8.0.2:443"},
                {"https://10.8.0.2", "https://10.8.0.2"},
                {"2001:db8::42", "https://[2001:db8::42]:18788"},
                {"[2001:db8::42]:8443", "https://[2001:db8::42]:8443"},
                {"relay.example", "https://relay.example"},
                {"https://relay.example:8443/relay/", "https://relay.example:8443/relay"},
                {"http://192.0.2.12:18787", "https://192.0.2.12:18788"}
        };
        for (String[] example : accepted) {
            String normalized = HomeRelayRoute.normalizeManualAddress(example[0]);
            check(normalized.equals(example[1]), "manual address " + example[0] + " gave " + normalized);
            check(normalized.equals(HomeRelayRoute.normalizeManualAddress(normalized)), "idempotent address");
        }
        for (String invalid : new String[]{"", "10.8.0.999", "01.2.3.4", "https://relay.example:",
                "10.8.0.2:65536", "10.8.0.2:0", "https://", "broken host", "http://relay.example",
                "wss://relay.example", "https://user@relay.example", "https://relay.example?token=x",
                "https://relay.example#section", "https://relay.example/path/../other"}) {
            try {
                HomeRelayRoute.normalizeManualAddress(invalid);
                throw new AssertionError("invalid manual Relay accepted: " + invalid);
            } catch (IllegalArgumentException expected) {}
        }
    }
}
