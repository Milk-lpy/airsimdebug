package com.airsim.phonecontrol;

import org.json.JSONObject;

/** The E2E SMS key only arrives in the sealed pairing claim; a stored registration never keeps it. */
public final class RegistrationE2EKeyTests {
    public static void main(String[] args) throws Exception {
        String key = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8";
        JSONObject local = new JSONObject().put("local_mode", true).put("e2e_key", key);
        StandaloneAgentStore.validateRegistration(local);
        if (local.has("e2e_key")) throw new AssertionError("local registration from /api/push/register keeps e2e_key");
        JSONObject cloud = new JSONObject().put("device_id", "iphone-air").put("device_secret", "s".repeat(32))
                .put("bundle_id", "com.example.airsim").put("environment", "production")
                .put("relay_url", "https://relay.example").put("alert_token", "ab".repeat(32))
                .put("e2e_key", key);
        StandaloneAgentStore.validateRegistration(cloud);
        if (cloud.has("e2e_key")) throw new AssertionError("cloud registration from /api/push/register keeps e2e_key");
        verifyRefreshCannotReplacePairing(cloud);
        verifyPrivateRelayRefresh(cloud);
        verifyManualRelayRetainsPairing(cloud);
        verifyOfflineRelayPreset(cloud);
        System.out.println("RegistrationE2EKeyTests passed");
    }

    private static void check(boolean value, String failure) {
        if (!value) throw new AssertionError(failure);
    }

    private static void verifyManualRelayRetainsPairing(JSONObject cloud) throws Exception {
        RelayEgressGate.shared.enableAfterRestore();
        var context = new android.content.Context();
        var store = new StandaloneAgentStore(context);
        String pairedOrigin = "https://paired.example";
        String peerOrigin = "https://refreshed.example";
        String manualOrigin = "https://10.8.0.2:18788";
        String scopeField = "_pairing_relay_url";
        JSONObject paired = new JSONObject(cloud.toString()).put("relay_url", pairedOrigin)
                .put(scopeField, "https://untrusted.example");
        JSONObject original = store.savePairing(paired.toString());
        check(!original.has(scopeField), "pairing accepted a remote SMS scope");
        String device = paired.getString("device_id");
        byte[] key = new byte[32];
        java.util.Arrays.fill(key, (byte) 3);
        E2EKeyStore.save(context, device, pairedOrigin, key);
        var sms = new StandaloneSMSStore(context);
        String firstID = "fixture-before-edit";
        sms.addForRegistration(new JSONObject().put("delivery_id", firstID), original, firstID);

        store.setRelayAddressOverride("10.8.0.2");
        check(manualOrigin.equals(store.relayAddressOverride()), "override was not normalized");
        try {
            store.setRelayAddressOverride("https://wrong.example/?key=ignored");
            throw new AssertionError("invalid edit was saved");
        } catch (IllegalArgumentException expected) {}
        JSONObject renewed = new JSONObject(paired.toString()).put("relay_url", peerOrigin)
                .put("alert_token", "ef".repeat(32));
        reject(store, new JSONObject(renewed.toString()).put("device_secret", "x".repeat(32)));
        store.refreshRegistration(renewed.toString());
        var reopened = new StandaloneAgentStore(context.reopen());
        JSONObject active = reopened.registration();
        check(manualOrigin.equals(active.getString("relay_url")), "iPhone refresh replaced manual Relay");
        check(manualOrigin.equals(reopened.effectiveRelayAddress()), "displayed address differs after reopen");
        check(renewed.getString("alert_token").equals(active.getString("alert_token")), "lost new alert token");
        check(pairedOrigin.equals(active.getString(scopeField)), "refresh injected SMS scope");

        // This is the persisted registration selected by the pure-local gateway snapshot.
        check(java.util.Arrays.equals(key, E2EKeyStore.forRegistration(context, active)), "manual address lost SMS key");
        check(sms.cloudPending(active).length() == 1, "manual address changed the pending SMS recipient");
        String snapshot = reopened.storedRegistration().toString();
        check(peerOrigin.equals(new JSONObject(snapshot).getString("relay_url")), "snapshot stored transport override");
        reopened.setRelayAddressOverride("");
        reopened.savePairing(new JSONObject().put("local_mode", true).toString());
        reopened.restoreSnapshot(snapshot);
        reopened = new StandaloneAgentStore(context.reopen());
        active = reopened.registration();
        check(reopened.relayAddressOverride().isEmpty() && peerOrigin.equals(active.getString("relay_url")),
                "switching back did not select the latest iPhone address");
        check(java.util.Arrays.equals(key, E2EKeyStore.forRegistration(context, active)), "lost the paired SMS key");
        check(StandaloneSMSStore.recipient(original).equals(StandaloneSMSStore.recipient(active)), "changed queue owner");
        var pending = new StandaloneSMSStore(context.reopen()).cloudPending(active);
        check(pending.length() == 1 && firstID.equals(pending.getJSONObject(0).getString("delivery_id")),
                "queued SMS disappeared when Relay address changed");

        JSONObject different = new JSONObject(cloud.toString()).put("device_id", "new-fixture-iphone")
                .put("device_secret", "y".repeat(32)).put("relay_url", peerOrigin).put(scopeField, pairedOrigin);
        JSONObject replacement = reopened.savePairing(different.toString());
        check(!replacement.has(scopeField) && E2EKeyStore.forRegistration(context, replacement) == null,
                "new pairing reused the old SMS key");
        check(sms.cloudPending(replacement).length() == 0, "new pairing inherited the previous recipient's queue");
    }

    private static void verifyOfflineRelayPreset(JSONObject cloud) throws Exception {
        var context = new android.content.Context();
        var store = new StandaloneAgentStore(context);
        RelayEgressGate.shared.disableAndDrain(1000);
        try {
            store.setRelayAddressOverride("10.8.0.3");
            check(!store.configured() && !store.cloudEnabled(), "preset before pairing enabled the gateway");
            store.savePairing(new JSONObject().put("local_mode", true).toString());
            check(store.configured() && !store.cloudEnabled(), "editing enabled cloud while in pure local mode");
            check(store.registration().optString("relay_url").isEmpty(), "preset polluted local-mode registration");
            reject(store, cloud);
        } finally {
            RelayEgressGate.shared.enableAfterRestore();
        }
        var reopened = new StandaloneAgentStore(context.reopen());
        check("https://10.8.0.3:18788".equals(reopened.effectiveRelayAddress()), "offline preset lost after restart");
        check(!reopened.cloudEnabled(), "restarting a local pairing enabled the cloud");
        reopened.savePairing(cloud.toString());
        check(reopened.cloudEnabled() && "https://10.8.0.3:18788".equals(reopened.registration().optString("relay_url")),
                "new cloud pairing ignored the pending address");
    }

    private static void verifyPrivateRelayRefresh(JSONObject cloud) throws Exception {
        RelayEgressGate.shared.enableAfterRestore();
        var context = new android.content.Context();
        var store = new StandaloneAgentStore(context);
        String old = "http://192.0.2.12:18787";
        JSONObject paired = new JSONObject(cloud.toString()).put("relay_url", old);
        String device = paired.getString("device_id");
        store.savePairing(paired.toString());
        byte[] key = new byte[32];
        java.util.Arrays.fill(key, (byte) 7);
        E2EKeyStore.save(context, device, old, key);
        for (String ip : new String[]{"192.0.2.12", "198.51.100.2"}) {
            JSONObject refreshed = new JSONObject(paired.toString()).put("relay_url", "https://" + ip + ":18788")
                    .put("alert_token", "bc".repeat(32));
            reject(store, new JSONObject(refreshed.toString()).put("device_secret", "x".repeat(32)));
            JSONObject updated = store.refreshRegistration(refreshed.toString());
            if (!old.equals(updated.getString("relay_url")) || !updated.getString("alert_token").equals("bc".repeat(32))) {
                throw new AssertionError("lost local SMS scope or token renewal");
            }
            if (!java.util.Arrays.equals(key, E2EKeyStore.forRegistration(context, updated))) {
                throw new AssertionError("SMS encryption key lost after HTTPS refresh");
            }
        }
        JSONObject other = store.refreshRegistration(new JSONObject(paired.toString())
                .put("relay_url", "https://another.example").toString());
        if (!"https://another.example".equals(other.getString("relay_url")) || E2EKeyStore.forRegistration(context, other) != null)
            throw new AssertionError("different Relay received private pairing scope");
    }

    private static void verifyRefreshCannotReplacePairing(JSONObject cloud) throws Exception {
        RelayEgressGate.shared.enableAfterRestore();
        var context = new android.content.Context();
        var firstProcess = new StandaloneAgentStore(context);
        var updater = new StandaloneAgentStore(context.reopen());
        cloud.put("android_agent_id", "android-fixture").put("android_agent_kind", "standalone")
                .put("android_device_name", "fixture").put("android_phone_number", "fixture");
        JSONObject other = new JSONObject(cloud.toString()).put("device_id", "iphone-b").put("device_secret", "b".repeat(32));
        JSONObject local = new JSONObject(cloud.toString()).put("local_mode", true).put("cloud_enabled", false);

        firstProcess.refreshRegistration(cloud.toString()); // Legacy first registration, before a cloud owner exists.
        reject(updater, other);
        reject(updater, new JSONObject(cloud.toString()).put("device_secret", other.getString("device_secret")));
        reject(updater, local);
        JSONObject refreshed = new JSONObject(cloud.toString()).put("alert_token", "cd".repeat(32))
                .put("relay_url", "https://new-fixture.invalid").put("environment", "sandbox");
        updater.refreshRegistration(refreshed.toString());
        if (!firstProcess.registration().getString("alert_token").equals(refreshed.getString("alert_token")))
            throw new AssertionError("same phone could not register its rotated token");

        // A slow refresh races a new six-digit pairing: the deliberate handoff must always win.
        var start = new java.util.concurrent.CountDownLatch(1);
        var pool = java.util.concurrent.Executors.newFixedThreadPool(2);
        try {
            var old = pool.submit(() -> {
                start.await();
                try { updater.refreshRegistration(cloud.toString()); }
                catch (StandaloneAgentStore.PairingRequired expected) {}
                return null;
            });
            var fresh = pool.submit(() -> { start.await(); firstProcess.savePairing(other.toString()); return null; });
            start.countDown();
            old.get(2, java.util.concurrent.TimeUnit.SECONDS);
            fresh.get(2, java.util.concurrent.TimeUnit.SECONDS);
        } finally { pool.shutdownNow(); }
        reject(updater, cloud);
        if (!other.getString("device_id").equals(firstProcess.registration().getString("device_id")))
            throw new AssertionError("previous handset recovered ownership");
        updater.refreshRegistration(other.toString());
        firstProcess.savePairing(local.toString());
        reject(updater, other);
        if (firstProcess.cloudEnabled()) throw new AssertionError("cloud enabled after local pairing");

        firstProcess.savePairing(cloud.toString());
        RelayEgressGate.shared.disableAndDrain(1000);
        reject(updater, refreshed);
        if (firstProcess.cloudEnabled()) throw new AssertionError("registration bypassed pure-local mode");
    }

    private static void reject(StandaloneAgentStore store, JSONObject refresh) throws Exception {
        try {
            store.refreshRegistration(refresh.toString());
            throw new AssertionError("unauthorized cloud registration was accepted");
        } catch (StandaloneAgentStore.PairingRequired expected) {}
    }
}
