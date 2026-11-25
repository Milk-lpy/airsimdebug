package com.airsim.phonecontrol;

import org.json.JSONObject;
import java.util.ArrayList;
import java.util.List;

/** External HTTP boundary only; the call-event manager under test is production code. */
final class StandaloneRelayClient {
    JSONObject postJSON(JSONObject registration, String path, JSONObject payload, int timeout,
                        RelayEgressGate.Generation generation) throws Exception {
        if (!generation.isCurrent()) throw new java.io.IOException("stale generation");
        return postJSON(registration, path, payload, timeout);
    }

    final List<JSONObject> states = new ArrayList<>();
    JSONObject postJSON(JSONObject registration, String path, JSONObject payload, int timeout) throws Exception {
        if (path.equals("/v2/events/call-state")) states.add(new JSONObject(payload.toString()));
        return new JSONObject();
    }
}
