package com.airsim.phonecontrol;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.util.HashSet;
import java.util.Set;

/** Durable incoming-SMS delivery queue. Acknowledging locally never discards an unsent cloud event. */
final class StandaloneSMSStore {
    private static final String FILE = "standalone_sms";
    private static final String RECORDS = "records";
    private static final String REVISION = "revision";
    private static final String RECENT_IDS = "recent_delivery_ids";
    private static final String OWNER = "cloud_owner";
    private static final Object LOCK = new Object();
    private final SharedPreferences preferences;

    StandaloneSMSStore(Context context) {
        preferences = context.getApplicationContext().getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    boolean add(JSONObject event, boolean cloudEnabled) throws Exception {
        return add(event, cloudEnabled, "avf", event.getString("delivery_id"));
    }

    static String recipient(JSONObject registration) {
        if (registration == null || registration.optBoolean("local_mode")
                || !registration.optBoolean("cloud_enabled", true)) return "";
        String device = registration.optString("device_id", "").trim();
        String relay = E2EKeyStore.pairingRelayAddress(registration).trim().replaceFirst("/+$", "");
        if (device.isEmpty() || relay.isEmpty()) return "";
        return new JSONArray().put(device).put(relay).toString();
    }

    boolean addForRegistration(JSONObject event, JSONObject registration, String legacyID) throws Exception {
        String owner = recipient(registration);
        return add(event, !owner.isEmpty(), owner, legacyID);
    }

    private boolean add(JSONObject event, boolean cloudEnabled, String owner, String legacyID) throws Exception {
        synchronized (LOCK) {
            String id = event.getString("delivery_id");
            String slot = event.optString("sim_slot", "");
            SMSRecentDeliveryIDs recent = recentIDs();
            if (recent.contains(id) || recent.contains(legacyID)) return false;
            JSONArray records = records();
            for (int i = 0; i < records.length(); i++) {
                JSONObject existing = records.getJSONObject(i);
                String existingID = existing.optString("delivery_id");
                if (id.equals(existingID)) return false;
                String existingSlot = existing.optString("sim_slot", "");
                if (legacyID.equals(existing.optString("legacy_delivery_id", existingID))
                        && (slot.isEmpty() || existingSlot.isEmpty() || slot.equals(existingSlot))) return false;
            }
            JSONObject record = new JSONObject(event.toString()).put(OWNER, owner)
                    .put("local_ack", false).put("cloud_sent", recordHasNoCloudDelivery(event, cloudEnabled));
            if (!legacyID.equals(id)) record.put("legacy_delivery_id", legacyID);
            records.put(record);
            // mutate() retires acknowledged records. Pending delivery must survive a long outage.
            persist(records, recent, true);
            return true;
        }
    }

    private static boolean recordHasNoCloudDelivery(JSONObject event, boolean cloudEnabled) {
        return event.optBoolean("android_filtered", false) || !cloudEnabled || RelayEgressGate.shared.isBlocked();
    }

    JSONArray localMessages() throws Exception {
        synchronized (LOCK) {
            JSONArray visible = new JSONArray();
            JSONArray records = records();
            for (int i = 0; i < records.length(); i++) {
                JSONObject record = records.getJSONObject(i);
                if (!record.optBoolean("local_ack")) visible.put(publicMessage(record));
            }
            return visible;
        }
    }

    JSONArray cloudPending() throws Exception {
        return cloudPending("avf", true);
    }

    JSONArray cloudPending(JSONObject registration) throws Exception {
        return cloudPending(recipient(registration), false);
    }

    private JSONArray cloudPending(String owner, boolean avf) throws Exception {
        synchronized (LOCK) {
            JSONArray pending = new JSONArray();
            if (owner.isEmpty() || RelayEgressGate.shared.isBlocked()) return pending;
            JSONArray records = records();
            Set<String> unassigned = new HashSet<>();
            for (int i = 0; i < records.length(); i++) {
                JSONObject record = records.getJSONObject(i);
                if (record.optBoolean("cloud_sent") || record.optBoolean("cloud_rejected")) continue;
                if (!record.has(OWNER) && !avf) {
                    // Older standalone builds persisted no recipient. Preserve local access only.
                    unassigned.add(record.getString("delivery_id"));
                } else if (owner.equals(record.optString(OWNER, "avf"))) {
                    pending.put(publicMessage(record));
                }
            }
            if (!unassigned.isEmpty()) mutate(unassigned, "cloud_rejected");
            return pending;
        }
    }

    void acknowledge(JSONArray ids) throws Exception {
        synchronized (LOCK) {
            Set<String> accepted = new HashSet<>();
            for (int i = 0; i < ids.length(); i++) accepted.add(ids.optString(i));
            mutate(accepted, "local_ack");
        }
    }

    void markCloudSent(String id) throws Exception {
        synchronized (LOCK) {
            mutate(Set.of(id), "cloud_sent");
        }
    }

    /** Remove only the cloud delivery obligation; keep unread local messages and dedup IDs. */
    void discardCloudBacklog() throws Exception {
        synchronized (LOCK) {
            Set<String> all = new HashSet<>();
            JSONArray records = records();
            for (int index = 0; index < records.length(); index++) {
                all.add(records.getJSONObject(index).optString("delivery_id"));
            }
            mutate(all, "cloud_sent");
        }
    }

    void markCloudRejected(String id) throws Exception {
        synchronized (LOCK) { mutate(Set.of(id), "cloud_rejected"); }
    }

    int pendingCount() throws Exception { return localMessages().length(); }
    long revision() { synchronized (LOCK) { return preferences.getLong(REVISION, 0); } }

    private void mutate(Set<String> ids, String flag) throws Exception {
        JSONArray source = records();
        JSONArray updated = new JSONArray();
        SMSRecentDeliveryIDs recent = recentIDs();
        boolean changed = false;
        for (int i = 0; i < source.length(); i++) {
            JSONObject record = source.getJSONObject(i);
            if (ids.contains(record.optString("delivery_id")) && !record.optBoolean(flag)) {
                record.put(flag, true);
                changed = true;
            }
            if (!record.optBoolean("local_ack")
                    || (!record.optBoolean("cloud_sent") && !record.optBoolean("cloud_rejected"))) updated.put(record);
            else recent.remember(record.optString("delivery_id"));
        }
        if (changed) persist(updated, recent, "local_ack".equals(flag));
    }

    private JSONArray records() throws Exception {
        return new JSONArray(preferences.getString(RECORDS, "[]"));
    }

    private SMSRecentDeliveryIDs recentIDs() throws Exception {
        JSONArray encoded = new JSONArray(preferences.getString(RECENT_IDS, "[]"));
        java.util.ArrayList<String> values = new java.util.ArrayList<>();
        for (int index = 0; index < encoded.length(); index++) values.add(encoded.optString(index));
        return new SMSRecentDeliveryIDs(values);
    }

    private JSONObject publicMessage(JSONObject record) throws Exception {
        return new JSONObject().put("delivery_id", record.getString("delivery_id"))
                .put("sender", record.optString("sender"))
                .put("content", record.optString("content"))
                .put("android_filtered", record.optBoolean("android_filtered", false))
                .put("sim_slot", record.optString("sim_slot"))
                .put("timestamp", record.optString("timestamp"));
    }

    private void persist(JSONArray records, SMSRecentDeliveryIDs recent, boolean advanceRevision) {
        JSONArray tombstones = new JSONArray();
        for (String id : recent.snapshot()) tombstones.put(id);
        SharedPreferences.Editor editor = preferences.edit().putString(RECORDS, records.toString())
                .putString(RECENT_IDS, tombstones.toString());
        if (advanceRevision) editor.putLong(REVISION, revision() + 1);
        if (!editor.commit()) throw new IllegalStateException("无法保存接收短信");
    }
}
