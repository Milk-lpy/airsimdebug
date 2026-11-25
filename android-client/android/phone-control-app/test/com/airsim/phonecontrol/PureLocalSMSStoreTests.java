package com.airsim.phonecontrol;

import android.content.Context;
import org.json.JSONObject;

public final class PureLocalSMSStoreTests {
    public static void main(String[] args) throws Exception {
        var context = new Context();
        var registration = new JSONObject().put("cloud_enabled", true).put("local_mode", false)
                .put("android_agent_id", "fixture-agent").put("android_device_name", "fixture")
                .put("android_agent_kind", "standalone").put("android_phone_number", "fixture")
                .put("device_id", "fixture").put("device_secret", "fixture-secret-12345")
                .put("relay_url", "https://fixture.invalid").put("bundle_id", "test.fixture")
                .put("environment", "sandbox");
        context.getSharedPreferences("standalone_agent", 0).edit().putString("registration", registration.toString()).commit();
        var agent = new StandaloneAgentStore(context);
        assert !agent.cloudEnabled() : "old registration bypassed persisted restriction";
        assert !agent.pushStatus().getBoolean("cloud_enabled");
        try { agent.setCloudEnabled(true); throw new AssertionError("old UI unblocked cloud"); }
        catch (IllegalStateException expected) {}
        var sms = new StandaloneSMSStore(context);
        sms.add(new JSONObject().put("delivery_id", "local-1").put("content", "fixture").put("sim_slot", "SIM 1"), true);
        assert sms.localMessages().length() == 1;
        assert "SIM 1".equals(sms.localMessages().getJSONObject(0).optString("sim_slot"));
        RelayEgressGate.shared.enableAfterRestore();
        assert agent.cloudEnabled() : "raw cloud preference was destroyed";
        assert sms.cloudPending().length() == 0 : "local-period SMS was queued for later cloud upload";
        sms.add(new JSONObject().put("delivery_id", "before-2").put("content", "fixture").put("sim_slot", "SIM 2"), true);
        assert sms.cloudPending().length() == 1;
        assert "SIM 2".equals(sms.cloudPending().getJSONObject(0).optString("sim_slot"));
        RelayEgressGate.shared.disableAndDrain(1000);
        sms.discardCloudBacklog();
        RelayEgressGate.shared.enableAfterRestore();
        var restarted = new StandaloneSMSStore(context.reopen());
        assert restarted.cloudPending().length() == 0;
        assert restarted.localMessages().length() == 2 : "cloud discard deleted local SMS";
        assert "SIM 1".equals(restarted.localMessages().getJSONObject(0).optString("sim_slot"));
        assert "SIM 2".equals(restarted.localMessages().getJSONObject(1).optString("sim_slot"));
        verifyRegistrationIsolation();
        var w = new Context();
        var owner = new JSONObject().put("device_id","fixture-ios").put("relay_url","http://192.0.2.12:18787");
        var a = new StandaloneSMSStore(w);
        var blocked = new JSONObject().put("delivery_id","blocked-synthetic").put("sender","10000")
                .put("content","synthetic test").put("sim_slot","SIM 2").put("android_filtered",true);
        assert a.addForRegistration(blocked, owner, "blocked-synthetic");
        assert a.cloudPending(owner).length() == 0;
        var reopened = new StandaloneSMSStore(w.reopen());
        assert reopened.cloudPending(owner).length() == 0;
        assert reopened.localMessages().length() == 1;
        assert reopened.localMessages().getJSONObject(0).getBoolean("android_filtered");
        assert reopened.localMessages().getJSONObject(0).getString("sim_slot").equals("SIM 2");
        assert !reopened.addForRegistration(blocked, owner, "blocked-synthetic");
        assert reopened.addForRegistration(new JSONObject().put("delivery_id","normal-synthetic"), owner,"normal-synthetic");
        assert reopened.cloudPending(owner).length() == 1;
        reopened.acknowledge(new org.json.JSONArray().put("blocked-synthetic"));
        assert reopened.localMessages().length() == 1;
        assert !reopened.addForRegistration(blocked, owner, "blocked-synthetic");
        System.out.println("PureLocalSMSStoreTests passed");
    }

    private static void verifyRegistrationIsolation() throws Exception {
        var context = new Context();
        var storage = context.getSharedPreferences("standalone_sms", 0);
        var legacy = new JSONObject().put("delivery_id", "unassigned-before-upgrade").put("cloud_sent", false);
        storage.edit().putString("records", new org.json.JSONArray().put(legacy).toString()).commit();
        var sms = new StandaloneSMSStore(context);
        var original = new JSONObject().put("device_id", "iPhone A").put("relay_url", "https://test.invalid");
        var next = new JSONObject(original.toString()).put("device_id", "iPhone B");
        assert sms.cloudPending(original).length() == 0 : "legacy row has no provable owner";
        assert sms.localMessages().length() == 1;
        String baseID = "android-sms-fixture";
        String first = SMSDeliveryIdentity.forSlot(baseID, "SIM 1");
        String second = SMSDeliveryIdentity.forSlot(baseID, "SIM 2");
        assert !first.equals(second);
        var event = new JSONObject().put("delivery_id", first).put("sim_slot", "SIM 1");
        assert sms.addForRegistration(event, original, baseID);
        assert !sms.addForRegistration(event, original, baseID);
        assert sms.addForRegistration(event.put("delivery_id", second).put("sim_slot", "SIM 2"), original, baseID);
        var source = new JSONObject(original.toString())
                .put("notification_forwarding", new JSONObject().put("enabled", true));
        var sameDevice = new JSONObject(original.toString());
        ForwardingConfigStore.retainForSameDevice(source, sameDevice);
        assert sameDevice.getJSONObject("notification_forwarding").getBoolean("enabled");
        ForwardingConfigStore.retainForSameDevice(source, next);
        assert !next.has("notification_forwarding") : "new pairing inherited an old webhook";
        assert sms.cloudPending(next).length() == 0;
        var otherRelay = new JSONObject(original.toString()).put("relay_url", "https://other.invalid");
        assert sms.cloudPending(otherRelay).length() == 0;
        assert sms.cloudPending(original).length() == 2;

        for (int i = 0; i < 513; i++) {
            String id = "queued-" + i;
            assert sms.addForRegistration(new JSONObject().put("delivery_id", id), next, id);
        }
        var reopened = new StandaloneSMSStore(context.reopen());
        assert reopened.cloudPending(original).length() == 2;
        assert reopened.cloudPending(next).length() == 513;
        reopened.acknowledge(new org.json.JSONArray().put(first));
        assert reopened.cloudPending(original).length() == 2;
        reopened.markCloudSent(first);
        assert reopened.cloudPending(original).length() == 1;
        assert !reopened.addForRegistration(event.put("delivery_id", first).put("sim_slot", "SIM 1"), original, baseID);
    }
}
