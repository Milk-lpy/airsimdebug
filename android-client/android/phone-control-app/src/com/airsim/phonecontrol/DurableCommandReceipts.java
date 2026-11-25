package com.airsim.phonecontrol;

import android.content.SharedPreferences;
import org.json.JSONObject;

import java.io.IOException;
import java.util.Iterator;

/** Write-ahead receipts for commands with billable side effects. Stores no message or phone number. */
final class DurableCommandReceipts {
    private final SharedPreferences preferences;
    private static final String ENTRIES = "receipts";
    private static final int LIMIT = 512;

    DurableCommandReceipts(SharedPreferences preferences) {
        this.preferences = preferences;
    }

    // Callers serialize each read-modify-write against other users of the same preference file.
    JSONObject reserve(String id, String action, long expiresAt, long now) throws Exception {
        JSONObject entries = load();
        Iterator<String> ids = entries.keys();
        while (ids.hasNext()) {
            if (entries.getJSONObject(ids.next()).getLong("expires") < now) ids.remove();
        }
        JSONObject existing = entries.optJSONObject(id);
        if (existing != null) {
            if (!action.equals(existing.getString("action"))) return failure(id, "command_identity_mismatch");
            JSONObject result = existing.optJSONObject("result");
            return result != null ? result : failure(id, "command_result_unknown");
        }
        if (entries.length() >= LIMIT) return failure(id, "command_receipt_capacity");
        entries.put(id, new JSONObject().put("action", action).put("expires", expiresAt));
        write(entries);
        return null;
    }

    void complete(String id, JSONObject result) throws Exception {
        JSONObject entries = load();
        JSONObject receipt = entries.getJSONObject(id);
        JSONObject safe = new JSONObject().put("command_id", result.getString("command_id"))
                .put("status", result.getString("status"));
        if (result.has("result")) safe.put("result", result.getJSONObject("result"));
        if (result.has("error")) safe.put("error", DebugRedactor.sanitize(result.optString("error")));
        receipt.put("result", safe);
        write(entries);
    }

    private JSONObject load() throws Exception {
        return new JSONObject(preferences.getString(ENTRIES, "{}"));
    }

    private void write(JSONObject entries) throws IOException {
        if (!preferences.edit().putString(ENTRIES, entries.toString()).commit())
            throw new IOException("command receipt storage unavailable");
    }

    private static JSONObject failure(String id, String reason) throws Exception {
        return new JSONObject().put("command_id", id).put("status", "failed").put("error", reason);
    }
}
