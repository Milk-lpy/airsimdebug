package com.airsim.phonecontrol;

import java.util.HashMap;
import java.util.Map;
import java.util.function.BooleanSupplier;

/** A missed alert can be retried after closing media without blocking a subsequent call or ringing again. */
final class MissedOwnerRetry {
    interface Scheduler { void after(long delayMillis, Runnable job); }
    interface Delivery { void send() throws Exception; }
    private static final long[] DELAYS = {2_000, 6_000, 18_000};
    private final Scheduler scheduler;
    private final Map<String, Object> pending = new HashMap<>();

    MissedOwnerRetry(Scheduler scheduler) { this.scheduler = scheduler; }

    synchronized void enqueue(String id, BooleanSupplier current, Delivery delivery) {
        if (pending.containsKey(id) || !current.getAsBoolean()) return;
        Object attempt = new Object();
        pending.put(id, attempt);
        schedule(id, attempt, 0, current, delivery);
    }

    private void schedule(String id, Object attempt, int step, BooleanSupplier current, Delivery delivery) {
        scheduler.after(DELAYS[step], () -> {
            synchronized (this) {
                if (pending.get(id) != attempt) return;
            }
            try {
                if (current.getAsBoolean()) delivery.send();
            } catch (Exception error) {
                int next = step + 1;
                if (next < DELAYS.length && current.getAsBoolean() && !CloudCallRetryPolicy.eventRejected(error)) {
                    schedule(id, attempt, next, current, delivery);
                    return;
                }
                BridgeLog.info("standalone_missed_owner_retry_failed " + CloudCallRetryPolicy.describe(error));
            }
            synchronized (this) { pending.remove(id, attempt); }
        });
    }

    synchronized void clear() { pending.clear(); }
}
