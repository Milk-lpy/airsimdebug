package com.airsim.phonecontrol;

import android.content.Context;
import android.telephony.ServiceState;
import android.telephony.TelephonyManager;
import org.json.JSONArray;
import org.json.JSONObject;

final class CellularHeartbeat {
    private CellularHeartbeat() {}

    static void put(Context context, JSONArray slots, JSONObject heartbeat) throws org.json.JSONException {
        TelephonyManager manager = context.getSystemService(TelephonyManager.class);
        boolean observed = false;
        boolean registered = false;
        for (int i = 0; manager != null && i < slots.length(); i++) {
            JSONObject slot = slots.optJSONObject(i);
            int id = slot == null ? -1 : slot.optInt("sub_id", -1);
            if (id < 0) continue;
            try {
                ServiceState state = manager.createForSubscriptionId(id).getServiceState();
                if (state == null) continue;
                observed = true;
                if (state.getState() == ServiceState.STATE_IN_SERVICE) {
                    registered = true;
                    break;
                }
            } catch (RuntimeException ignored) { /* Optional per-subscription read can be denied. */ }
        }
        // The Relay protocol has no unknown enum. Distinguish unavailable samples in the detail.
        heartbeat.put("at_ok", observed).put("cellular_state", registered ? "registered" : "unregistered")
                .put("cellular_registration", observed ? "Android ServiceState" : "unavailable")
                .put("cellular_recovery", registered ? "not_required" : "unknown");
    }
}
