package com.airsim.phonecontrol;

import java.util.concurrent.CountDownLatch;
import java.util.concurrent.Executor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicReference;

final class TelecomInvocation {
    static final String OUTCOME_UNCONFIRMED = "Telecom action already dispatched; outcome unconfirmed";

    private TelecomInvocation() {}

    static String run(Executor executor, Runnable action, long timeoutMillis) {
        CountDownLatch finished = new CountDownLatch(1);
        AtomicBoolean pending = new AtomicBoolean(true);
        AtomicReference<Throwable> failure = new AtomicReference<>();
        try {
            executor.execute(() -> {
                if (!pending.compareAndSet(true, false)) return;
                try { action.run(); }
                catch (Throwable error) { failure.set(error); }
                finally { finished.countDown(); }
            });
        } catch (Throwable error) {
            return describe(error);
        }
        try {
            if (!finished.await(timeoutMillis, TimeUnit.MILLISECONDS)) {
                return pending.compareAndSet(true, false) ? "Telecom invocation timeout before dispatch"
                        : OUTCOME_UNCONFIRMED;
            }
        } catch (InterruptedException error) {
            boolean cancelled = pending.compareAndSet(true, false);
            Thread.currentThread().interrupt();
            return cancelled ? describe(error) : OUTCOME_UNCONFIRMED;
        }
        Throwable error = failure.get();
        return error == null ? "" : describe(error);
    }

    private static String describe(Throwable error) {
        String message = error.getMessage();
        return error.getClass().getSimpleName()
                + (message == null || message.isBlank() ? "" : ": " + message);
    }
}
