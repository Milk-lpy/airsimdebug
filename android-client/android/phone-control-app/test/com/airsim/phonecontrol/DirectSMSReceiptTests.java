package com.airsim.phonecontrol;

import android.content.Context;
import org.json.JSONObject;

public final class DirectSMSReceiptTests {
    public static void main(String[] args) throws Exception {
        Context context = new Context();
        byte[] first = new byte[32], second = new byte[32];
        second[0] = 1;
        int[] submitted = {0};
        DirectSMSReceipts.Sender sms = body -> {
            if (new JSONObject(body).has("operation_id")) throw new AssertionError("local extension reached backend");
            submitted[0]++;
            return new AgentClient.ForwardResponse(200, "{\"sent\":true,\"segments\":2}");
        };
        JSONObject msg = new JSONObject().put("phone", "5550100").put("message", "message A").put("sim_account", "one");
        msg.put("operation_id", "A");
        send(context, first, msg, sms, 200);
        send(context.reopen(), first, msg, sms, 200);
        count(submitted, 1);
        for (String field : new String[] {"phone", "message", "sim_account"}) {
            JSONObject changed = new JSONObject(msg.toString()).put(field, "different");
            if (!"operation_payload_mismatch".equals(send(context, first, changed, sms, 409).optString("error")))
                throw new AssertionError("different " + field + " silently reused ID");
        }
        send(context, second, msg, sms, 200);
        send(context, first, msg.put("operation_id", "B"), sms, 200);
        count(submitted, 3);

        msg.put("operation_id", "uncertain");
        try {
            send(context, first, msg, body -> {
                submitted[0]++;
                throw new java.io.IOException("lost transport result");
            }, 200);
            throw new AssertionError("missing failure");
        } catch (java.io.IOException expected) {}
        send(context.reopen(), first, msg, sms, 409);
        count(submitted, 4);
        msg.remove("operation_id");
        send(context, first, msg, sms, 200);
        send(context, first, msg, sms, 200);
        count(submitted, 6);
        System.out.println("DirectSMSReceiptTests passed");
    }

    private static JSONObject send(Context context, byte[] secret, JSONObject body, DirectSMSReceipts.Sender sms, int status)
            throws Exception {
        AgentClient.ForwardResponse reply = DirectSMSReceipts.forward(context, secret, body.toString(), sms);
        if (reply.status() != status) throw new AssertionError(reply);
        JSONObject result = new JSONObject(reply.payload());
        if (status == 200 && (!result.getBoolean("sent") || result.getInt("segments") != 2)) throw new AssertionError(reply);
        return result;
    }

    private static void count(int[] submitted, int expected) {
        if (submitted[0] != expected) throw new AssertionError("unexpected SMS submissions: " + submitted[0]);
    }
}
