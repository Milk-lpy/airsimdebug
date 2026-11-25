package com.airsim.phonecontrol;

/** These socket tests start their own backend listener before negotiating PCM. */
final class ShizukuBridgeManager {
    static ShizukuBridgeManager get(android.content.Context ignored) { return new ShizukuBridgeManager(); }
    boolean bridgeRunning() { return true; }
    void ensureStarted() { throw new AssertionError("test PCM backend is already running"); }
}
