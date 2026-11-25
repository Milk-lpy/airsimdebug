package com.airsim.phonecontrol;

import android.content.Context;
import android.content.SharedPreferences;

import org.json.JSONArray;
import org.json.JSONObject;

import java.net.URI;
import java.util.Locale;

/** Private persistent state for the Agent embedded in the standalone APK. */
final class StandaloneAgentStore {
    static final String FILE = "standalone_agent";
    static final String REGISTRATION = "registration";
    static final String RELAY_ADDRESS_OVERRIDE = "relay_address_override";
    private static final String LAST_ERROR = "last_error";
    private static final String LAST_HEARTBEAT = "last_heartbeat";
    private static final String LAST_SEEN = "last_seen";

    // The service, API and UI open separate store instances for the same preferences.
    private static final Object REGISTRATION_LOCK = new Object();

    static final class PairingRequired extends Exception {
        PairingRequired(String message) { super(message); }
    }

    private final Context context;
    private final SharedPreferences preferences;

    StandaloneAgentStore(Context context) {
        this.context = context;
        preferences = context.getSharedPreferences(FILE, Context.MODE_PRIVATE);
    }

    String relayAddressOverride() { return preferences.getString(RELAY_ADDRESS_OVERRIDE, ""); }

    String pairedRelayAddress() {
        JSONObject paired = storedRegistration();
        if (paired == null || paired.optBoolean("local_mode")) return "";
        try { return HomeRelayRoute.endpointBase(URI.create(paired.optString("relay_url"))); }
        catch (IllegalArgumentException invalidLegacyAddress) { return ""; }
    }

    String effectiveRelayAddress() {
        synchronized (REGISTRATION_LOCK) {
            String manual = relayAddressOverride();
            return manual.isEmpty() ? pairedRelayAddress() : manual;
        }
    }

    void setRelayAddressOverride(String input) {
        String address = input.isEmpty() ? "" : HomeRelayRoute.normalizeManualAddress(input);
        synchronized (REGISTRATION_LOCK) {
            if (address.equals(relayAddressOverride())) return;
            SharedPreferences.Editor edit = preferences.edit();
            if (address.isEmpty()) edit.remove(RELAY_ADDRESS_OVERRIDE);
            else edit.putString(RELAY_ADDRESS_OVERRIDE, address);
            String next = address.isEmpty() ? pairedRelayAddress() : address;
            if (!effectiveRelayAddress().equals(next)) edit.remove(LAST_ERROR).remove(LAST_HEARTBEAT).remove(LAST_SEEN);
            if (!edit.commit()) throw new IllegalStateException("无法保存 Relay 地址");
        }
    }

    JSONObject registration() {
        synchronized (REGISTRATION_LOCK) {
            JSONObject value = storedRegistration();
            String manual = relayAddressOverride();
            if (value != null && !value.optBoolean("local_mode") && !manual.isEmpty()) {
                try {
                    value.put(E2EKeyStore.PAIRING_RELAY, E2EKeyStore.pairingRelayAddress(value));
                    value.put("relay_url", manual);
                } catch (org.json.JSONException error) { throw new IllegalStateException(error); }
            }
            return value;
        }
    }

    JSONObject storedRegistration() {
        String encoded = preferences.getString(REGISTRATION, "");
        if (encoded == null || encoded.isBlank()) return null;
        try {
            JSONObject value = new JSONObject(encoded);
            // Reads use one preference snapshot. Never write a legacy snapshot back over a new pairing.
            normalizeIdentity(value);
            return value;
        } catch (Exception error) {
            BridgeLog.error("standalone_registration_corrupt", error);
            return null;
        }
    }

    /** Older/direct pairing records omitted the local identity; never let that
     * make every cloud cycle fail in StandaloneCloudMediaManager.identity(). */
    private void normalizeIdentity(JSONObject value) throws Exception {
        if (value.optString("android_agent_id", "").isBlank()) {
            value.put("android_agent_id", AndroidAgentIdentity.agentID(context));
        }
        if (value.optString("android_device_name", "").isBlank()) {
            value.put("android_device_name", AndroidAgentIdentity.deviceName());
        }
        if (value.optString("android_agent_kind", "").isBlank()) {
            value.put("android_agent_kind", RuntimeMode.isStandalone(context) ? "standalone" : "avf");
        }
        if (value.optString("android_phone_number", "").isBlank()) {
            value.put("android_phone_number", AndroidAgentIdentity.phoneNumber(context));
        }
    }

    JSONObject savePairing(String encoded) throws Exception {
        synchronized (REGISTRATION_LOCK) { return saveRegistration(encoded, true); }
    }

    JSONObject refreshRegistration(String encoded) throws Exception {
        synchronized (REGISTRATION_LOCK) { return saveRegistration(encoded, false); }
    }

    private JSONObject saveRegistration(String encoded, boolean userPaired) throws Exception {
        JSONObject value = new JSONObject(encoded);
        value.remove(E2EKeyStore.PAIRING_RELAY); // Only this store can set a local SMS key scope.
        validateRegistration(value);
        normalizeIdentity(value);
        boolean localMode = value.optBoolean("local_mode", false);
        if (localMode) value.put("cloud_enabled", false);
        if (value.has("device_id")) value.put("device_id", value.optString("device_id", "").trim());
        value.put("relay_url", trimTrailingSlash(value.optString("relay_url", "").trim()));
        for (String key : new String[]{"voip_token", "alert_token", "watch_voip_token",
                "live_activity_push_to_start_token"}) {
            if (value.has(key)) value.put(key, value.optString(key, "").toLowerCase(Locale.ROOT));
        }
        JSONObject previous = storedRegistration();
        if (!userPaired) {
            if (!localMode && RelayEgressGate.shared.isBlocked())
                throw new PairingRequired("纯本地模式已开启，云端注册暂停");
            if (previous != null) {
                if (localMode || previous.optBoolean("local_mode") ||
                        !value.optString("device_id").equals(previous.optString("device_id").trim()) ||
                        !value.optString("device_secret").equals(previous.optString("device_secret"))) {
                    throw new PairingRequired("请在安卓端打开重新配对并使用六位码确认云端设备变更");
                }
                String savedRelay = previous.optString("relay_url");
                String peerRelay = value.getString("relay_url");
                boolean manual = !relayAddressOverride().isEmpty();
                if (!manual && !previous.has(E2EKeyStore.PAIRING_RELAY) && HomeRelayRoute.samePrivateRelay(savedRelay, peerRelay)) {
                    value.put("relay_url", savedRelay);
                } else if (manual || savedRelay.equals(peerRelay) || HomeRelayRoute.samePrivateRelay(savedRelay, peerRelay)) {
                    String pairingRelay = E2EKeyStore.pairingRelayAddress(previous);
                    if (!pairingRelay.equals(peerRelay)) value.put(E2EKeyStore.PAIRING_RELAY, pairingRelay);
                }
            } else if (!preferences.getString(REGISTRATION, "").isBlank()) {
                throw new PairingRequired("请在安卓端打开重新配对并使用六位码确认云端设备变更"); // Only a new code can replace an unreadable identity.
            }
        }
        ForwardingConfigStore.retainForSameDevice(previous, value);
        if (!preferences.edit().putString(REGISTRATION, value.toString()).remove(LAST_ERROR).commit())
            throw new IllegalStateException("registration_write_failed");
        return registration();
    }

    void restoreSnapshot(String encoded) throws Exception {
        synchronized (REGISTRATION_LOCK) {
            if (encoded == null || encoded.isBlank()) {
                if (!preferences.edit().remove(REGISTRATION).commit()) throw new IllegalStateException("registration_restore_failed");
                return;
            }
            JSONObject value = new JSONObject(encoded);
            validateRegistration(value);
            if (!preferences.edit().putString(REGISTRATION, value.toString()).commit()) {
                throw new IllegalStateException("registration_restore_failed");
            }
        }
    }

    boolean configured() {
        JSONObject value = registration();
        if (value != null && value.optBoolean("local_mode", false)) return true;
        return value != null && !value.optString("device_id", "").isBlank()
                && !value.optString("device_secret", "").isBlank()
                && !value.optString("relay_url", "").isBlank();
    }

    boolean cloudEnabled() {
        if (RelayEgressGate.shared.isBlocked()) return false;
        JSONObject value = registration();
        return value != null && !value.optBoolean("local_mode", false)
                && value.optBoolean("cloud_enabled", true);
    }

    JSONObject setCloudEnabled(boolean enabled) throws Exception {
        synchronized (REGISTRATION_LOCK) {
            if (enabled && RelayEgressGate.shared.isBlocked()) throw new IllegalStateException("纯本地模式禁止云端连接");
            JSONObject value = storedRegistration();
            if (value == null) throw new IllegalStateException("尚未完成配对");
            if (enabled && value.optBoolean("local_mode", false)) {
                throw new IllegalArgumentException("本地模式不能启用云端模式");
            }
            value.put("cloud_enabled", enabled);
            if (!preferences.edit().putString(REGISTRATION, value.toString()).remove(LAST_ERROR).commit())
                throw new IllegalStateException("registration_write_failed");
            return registration();
        }
    }

    void recordSuccess() {
        preferences.edit().putLong(LAST_SEEN, System.currentTimeMillis()).remove(LAST_ERROR).apply();
    }

    void recordHeartbeat() {
        preferences.edit().putLong(LAST_HEARTBEAT, System.currentTimeMillis())
                .putLong(LAST_SEEN, System.currentTimeMillis()).remove(LAST_ERROR).apply();
    }

    void recordError(String error) {
        preferences.edit().putString(LAST_ERROR, DebugRedactor.sanitize(error)).apply();
    }

    String lastError() { return preferences.getString(LAST_ERROR, ""); }
    long lastSeen() { return preferences.getLong(LAST_SEEN, 0L); }
    long lastHeartbeat() { return preferences.getLong(LAST_HEARTBEAT, 0L); }

    JSONObject pushStatus() throws Exception {
        JSONObject registration = registration();
        boolean configured = registration != null;
        boolean localMode = configured && registration.optBoolean("local_mode", false);
        JSONObject result = new JSONObject()
                .put("local_mode", localMode)
                .put("cloud_enabled", !RelayEgressGate.shared.isBlocked() && configured && !localMode
                        && registration.optBoolean("cloud_enabled", true))
                .put("configured", configured)
                .put("call_push_ready", configured && (!registration.optString("voip_token", "").isEmpty()
                        || !registration.optString("watch_voip_token", "").isEmpty()))
                .put("message_push_ready", configured && !registration.optString("alert_token", "").isEmpty())
                .put("last_error", lastError())
                .put("wan_interface", "android-default");
        if (configured) {
            result.put("device_id", registration.optString("device_id", ""));
            result.put("environment", registration.optString("environment", ""));
            result.put("relay_url", registration.optString("relay_url", ""));
        }
        return result;
    }

    /** The current cloud registration's E2E SMS key, or null (AVF, local mode, or no key yet). */
    static byte[] currentE2EKey(Context context) {
        try {
            return E2EKeyStore.forRegistration(context, new StandaloneAgentStore(context).registration());
        } catch (RuntimeException unreadable) {
            return null;
        }
    }

    static void validateRegistration(JSONObject value) throws Exception {
        // The E2E SMS key arrives only in the sealed pairing claim, never in a stored registration.
        value.remove("e2e_key");
        if (value.optBoolean("local_mode", false)) {
            if (value.optBoolean("cloud_enabled", false)) {
                throw new IllegalArgumentException("本地模式不能启用云端模式");
            }
            return;
        }
        String deviceID = value.optString("device_id", "").trim();
        String secret = value.optString("device_secret", "");
        String bundleID = value.optString("bundle_id", "").trim();
        String environment = value.optString("environment", "");
        String relayURL = value.optString("relay_url", "").trim();
        if (deviceID.isEmpty() || deviceID.length() > 128) throw new IllegalArgumentException("device_id 无效");
        if (secret.length() < 16 || secret.length() > 512) throw new IllegalArgumentException("device_secret 无效");
        if (bundleID.isEmpty() || bundleID.length() > 255) throw new IllegalArgumentException("bundle_id 无效");
        if (!"sandbox".equals(environment) && !"production".equals(environment)) {
            throw new IllegalArgumentException("environment 必须是 sandbox 或 production");
        }
        URI relay = URI.create(relayURL);
        if (!HomeRelayRoute.allowsBase(relay)) {
            throw new IllegalArgumentException("relay_url 必须是 HTTPS 或指定的家庭 HTTP 地址");
        }
        boolean hasToken = false;
        for (String key : new String[]{"voip_token", "alert_token", "watch_voip_token",
                "live_activity_push_to_start_token"}) {
            String token = value.optString(key, "");
            if (!token.isEmpty()) {
                hasToken = true;
                if ((token.length() & 1) != 0 || !token.matches("[0-9a-fA-F]{16,512}")) {
                    throw new IllegalArgumentException(key + " 无效");
                }
            }
        }
        if (!hasToken) throw new IllegalArgumentException("至少需要一个 APNs token");
        String watchToken = value.optString("watch_voip_token", "");
        if (!watchToken.isEmpty() && !(bundleID + ".watchkitapp").equals(value.optString("watch_bundle_id", ""))) {
            throw new IllegalArgumentException("watch_bundle_id 与主应用不匹配");
        }
        JSONArray capabilities = value.optJSONArray("agent_media_capabilities");
        if (capabilities == null) {
            value.put("agent_media_capabilities", new JSONArray().put("legacy_pcm"));
        }
    }

    private static String trimTrailingSlash(String value) {
        while (value.endsWith("/")) value = value.substring(0, value.length() - 1);
        return value;
    }
}
