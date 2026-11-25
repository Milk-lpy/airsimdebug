package com.airsim.phonecontrol;

import android.content.Context;
import org.json.JSONArray;
import org.json.JSONObject;

/** A signed LAN request may carry an operation ID stable across network retries. */
final class DirectSMSReceipts {
    interface Sender { AgentClient.ForwardResponse send(String body) throws Exception; }

    private static final Object JOURNAL_LOCK = new Object();
    private static final long RETENTION_MILLIS = 24L * 60 * 60 * 1000;

    static AgentClient.ForwardResponse forward(Context context, byte[] pairingSecret, String body, Sender sender)
            throws Exception {
        JSONObject request = new JSONObject(body);
        if (!request.has("operation_id")) return sender.send(body);
        Object rawID = request.get("operation_id");
        if (!(rawID instanceof String id) || id.isBlank() || id.length() > 128)
            return error(400, "invalid_operation_id");

        // Each authenticated pairing has a different signing key, even if the two phones use the same operation ID.
        String key = VoWLANAuth.sign(pairingSecret, "sms-id\n" + id);
        JSONArray arguments = new JSONArray().put(request.optString("phone")).put(request.optString("message"))
                .put(request.optString("sim_account"));
        String fingerprint = VoWLANAuth.sign(pairingSecret, "sms-arguments\n" + arguments);
        long now = System.currentTimeMillis();
        DurableCommandReceipts receipts = new DurableCommandReceipts(
                context.getSharedPreferences("vowlan_sms_receipts", Context.MODE_PRIVATE));
        synchronized (JOURNAL_LOCK) {
            JSONObject saved = receipts.reserve(key, fingerprint, now + RETENTION_MILLIS, now);
            if (saved != null) {
                JSONObject result = saved.optJSONObject("result");
                if (result != null) return new AgentClient.ForwardResponse(result.getInt("http"), result.getString("body"));
                String reason = saved.getString("error");
                return switch (reason) {
                    case "command_identity_mismatch" -> error(409, "operation_payload_mismatch");
                    case "command_receipt_capacity" -> error(503, "sms_receipt_capacity");
                    default -> error(409, "sms_result_unknown");
                };
            }
        }

        request.remove("operation_id");
        AgentClient.ForwardResponse response = sender.send(request.toString());
        // Persist only the protocol fields. A carrier error can contain a destination or SMS text.
        JSONObject reply = new JSONObject();
        if (response.status() >= 200 && response.status() < 300) {
            JSONObject result = new JSONObject(response.payload());
            reply.put("sent", result.getBoolean("sent")).put("segments", result.getInt("segments"));
        } else {
            reply.put("error", "sms_send_failed");
        }
        JSONObject recorded = new JSONObject().put("http", response.status()).put("body", reply.toString());
        synchronized (JOURNAL_LOCK) {
            receipts.complete(key, new JSONObject().put("command_id", key).put("status", "finished").put("result", recorded));
        }
        return response;
    }

    private static AgentClient.ForwardResponse error(int status, String reason) throws Exception {
        return new AgentClient.ForwardResponse(status, new JSONObject().put("error", reason).toString());
    }
}
