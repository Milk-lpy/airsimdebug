package com.airsim.phonecontrol;

import android.content.Context;
import android.os.Build;
import android.os.SystemClock;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.util.Map;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.TimeUnit;
import org.json.JSONObject;

final class RealmeDisplayedSignal {
    private record Sample(Map<Integer,Integer> levels, long monotonicTime, long wallTime) {}
    private static volatile Sample sample;
    private static ScheduledExecutorService worker;

    static boolean applies() {
        return "RMX2072".equalsIgnoreCase(Build.MODEL) || "RMX2072".equalsIgnoreCase(Build.PRODUCT);
    }

    static synchronized void start(Context context) {
        if (!applies() || worker != null) return;
        Context app = context.getApplicationContext();
        worker = Executors.newSingleThreadScheduledExecutor(r -> {
            Thread t = new Thread(r, "airsim-realme-signal"); t.setDaemon(true); return t;
        });
        worker.scheduleWithFixedDelay(() -> refresh(app), 0, 25, TimeUnit.SECONDS);
    }

    static synchronized void stop() {
        if (worker != null) worker.shutdownNow();
        worker = null; sample = null;
    }

    private static void refresh(Context context) {
        if (!"Root".equals(ShizukuBridgeManager.get(context).activePrivilegeLabel())) {
            sample = null; return;
        }
        Process process = null;
        try {
            // Reuse the already-selected Root channel. Fixed, read-only OEM diagnostic command.
            process = new ProcessBuilder("su", "-c",
                    "/system/bin/timeout 4 /system/bin/dumpsys -t 2 activity service com.android.systemui/.SystemUIService")
                    .redirectErrorStream(true).start();
            Map<Integer,Integer> levels;
            try (var reader = new InputStreamReader(process.getInputStream(), StandardCharsets.UTF_8)) {
                levels = RealmeSignalPolicy.read(reader);
            }
            if (process.waitFor(1, TimeUnit.SECONDS) && process.exitValue() == 0
                    && !Thread.currentThread().isInterrupted()) {
                sample = new Sample(levels, SystemClock.elapsedRealtime(), System.currentTimeMillis());
            }
        } catch (InterruptedException stop) { Thread.currentThread().interrupt(); }
        catch (Exception unavailable) { /* Reporting remains unknown when no fresh sample is available. */ }
        finally { if (process != null) process.destroy(); }
    }

    static JSONObject signal(int subscription) throws org.json.JSONException {
        Sample value = sample;
        if (value == null || SystemClock.elapsedRealtime() - value.monotonicTime() > 65_000) return null;
        Integer level = value.levels().get(subscription);
        return level == null ? null : new JSONObject().put("level", level).put("observed_at_ms", value.wallTime());
    }
}
