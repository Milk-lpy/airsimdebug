package com.airsim.phonecontrol;

import android.content.Context;

import org.json.JSONObject;

/** The paired registration owns its third-party forwarding destinations. */
final class ForwardingConfigStore {
    private static final String CONFIG = "notification_forwarding";

    private ForwardingConfigStore() {}

    static void retainForSameDevice(JSONObject previous, JSONObject incoming) throws Exception {
        if (incoming.has(CONFIG) || previous == null || !previous.has(CONFIG)) return;
        String owner = StandaloneSMSStore.recipient(incoming);
        if (!owner.isEmpty() && owner.equals(StandaloneSMSStore.recipient(previous))) {
            incoming.put(CONFIG, previous.optJSONObject(CONFIG));
        }
    }

    static JSONObject config(Context context) {
        JSONObject registration = new StandaloneAgentStore(context).registration();
        JSONObject config = registration == null ? null : registration.optJSONObject(CONFIG);
        return config == null ? new JSONObject() : config;
    }
}
