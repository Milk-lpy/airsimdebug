package com.airsim.phonecontrol;

import android.os.SystemClock;

import java.util.HashMap;
import java.util.Map;
import java.util.regex.Pattern;

/** One explicitly identified system confirmation for the sole pending AirSIM SMS request. */
final class SmsSendConfirmationGate {
    private record Request(String destination, long expiresAt) {}
    private static final Map<Thread, Request> pending = new HashMap<>();

    private SmsSendConfirmationGate() {}

    static synchronized void arm(String destination, long durationMillis) {
        removeExpired();
        pending.put(Thread.currentThread(), new Request(destination,
                SystemClock.elapsedRealtime() + Math.max(1_000L, durationMillis)));
    }

    static synchronized void disarm() {
        pending.remove(Thread.currentThread());
    }

    static synchronized boolean isArmed() {
        removeExpired();
        return pending.size() == 1;
    }

    static synchronized boolean claim(String appLabel, String dialog) {
        if (!isArmed()) return false;
        var entry = pending.entrySet().iterator().next();
        if (!matches(appLabel, entry.getValue().destination(), dialog)) return false;
        pending.remove(entry.getKey());
        return true;
    }

    static boolean matches(String appLabel, String destination, String dialog) {
        if (appLabel == null || appLabel.isBlank() || destination == null
                || !destination.matches("\\+?[0-9]{3,20}")) return false;
        if (!dialog.contains(appLabel)) return false;
        return Pattern.compile("(?<![+0-9])" + Pattern.quote(destination) + "(?![0-9])")
                .matcher(dialog).find();
    }

    private static void removeExpired() {
        long now = SystemClock.elapsedRealtime();
        pending.values().removeIf(request -> request.expiresAt() < now);
    }
}
