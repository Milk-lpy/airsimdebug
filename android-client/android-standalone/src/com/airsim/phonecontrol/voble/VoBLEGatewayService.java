package com.airsim.phonecontrol.voble;

import android.content.Context;
import org.json.JSONObject;

/** Shared UI and event hooks for the standalone variant, which ships no BLE transport. */
public final class VoBLEGatewayService {
    public static final boolean AVAILABLE = false;
    private VoBLEGatewayService() {}
    public static void start(Context context) {}
    public static void publishSMS(Context context, JSONObject event) {}
    public static void publishCallState(Context context, String id, String direction, String state, String number) {}
    public static boolean hasStoredCredential(Context context) { return false; }
    public static boolean isAuthenticated() { return false; }
    public static String pendingPairingCode() { return ""; }
    public static String diagnosticsSummary() { return ""; }
    public static void clearStoredCredential(Context context) {}
}
