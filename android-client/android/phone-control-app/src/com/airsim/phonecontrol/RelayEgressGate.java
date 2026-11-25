package com.airsim.phonecontrol;

import java.io.Closeable;
import java.io.IOException;
import java.util.ArrayList;
import java.util.HashSet;
import java.util.Set;
import java.util.concurrent.TimeUnit;

/** Process-wide fail-closed admission and lifetime tracking for Relay I/O. */
public final class RelayEgressGate {
    public static final RelayEgressGate shared = new RelayEgressGate(true);
    private static final java.util.concurrent.ExecutorService CANCELLATIONS =
            java.util.concurrent.Executors.newFixedThreadPool(2, runnable -> {
                Thread thread = new Thread(runnable, "AirSIMRelayCancel");
                thread.setDaemon(true);
                return thread;
            });
    private final Set<Lease> active = new HashSet<>();
    private boolean blocked;
    private long epoch, destinationEpoch;
    private int pendingCancellations;

    public RelayEgressGate(boolean blocked) { this.blocked = blocked; }
    public synchronized boolean isBlocked() { return blocked; }
    public synchronized Generation generation() { return new Generation(epoch, destinationEpoch, true); }
    /** Forwarding webhooks and feedback have their own destinations, but still obey pure-local mode. */
    synchronized Generation independentDestination() { return new Generation(epoch, destinationEpoch, false); }
    /** A queued callback may outlive its socket; it must still belong to this allowed generation. */
    public final class Generation {
        private final RelayEgressGate owner = RelayEgressGate.this;
        private final long value;
        private final long destination;
        private final boolean followsRelay;
        private final boolean admitted;
        private Generation(long value, long destination, boolean followsRelay) {
            this.value = value;
            this.destination = destination;
            this.followsRelay = followsRelay;
            this.admitted = !blocked;
        }
        public boolean isCurrent() {
            synchronized (RelayEgressGate.this) { return admitted && !blocked && value == epoch && (!followsRelay || destination == destinationEpoch); }
        }
    }
    public synchronized Lease acquire(Closeable cancellation) throws IOException {
        if (blocked) throw new IOException("pure_local_relay_disabled");
        return acquire(generation(), cancellation);
    }
    public synchronized Lease acquire(Generation generation, Closeable cancellation) throws IOException {
        if (generation == null || generation.owner != this || !generation.isCurrent()) {
            throw new IOException("stale_relay_operation");
        }
        if (cancellation == null) throw new IllegalArgumentException("cancellation required");
        Lease lease = new Lease(generation, cancellation);
        active.add(lease);
        return lease;
    }

    /** Retire the old Relay destination without enabling a disabled pure-local gate. */
    void destinationChanged() {
        ArrayList<Lease> old;
        synchronized (this) {
            destinationEpoch++;
            old = new ArrayList<>();
            for (Lease lease : active) if (lease.generation.followsRelay) old.add(lease);
        }
        for (Lease lease : old) lease.cancelOnce();
    }

    public boolean disableAndDrain(long timeoutMillis) throws InterruptedException {
        long deadline = System.nanoTime() + TimeUnit.MILLISECONDS.toNanos(Math.max(0, timeoutMillis));
        ArrayList<Lease> cancelling;
        synchronized (this) {
            if (!blocked) { blocked = true; epoch++; }
            cancelling = new ArrayList<>(active);
        }
        for (Lease lease : cancelling) lease.cancelOnce();
        synchronized (this) {
            while (!active.isEmpty() || pendingCancellations != 0) {
                long remaining = deadline - System.nanoTime();
                if (remaining <= 0) return false;
                TimeUnit.NANOSECONDS.timedWait(this, remaining);
            }
            return true;
        }
    }

    public synchronized void enableAfterRestore() {
        if (!active.isEmpty() || pendingCancellations != 0) throw new IllegalStateException("relay_still_draining");
        if (blocked) { epoch++; blocked = false; }
    }

    public final class Lease implements Closeable {
        private final Generation generation;
        private final Closeable cancellation;
        private boolean closed, cancelled;
        private Lease(Generation generation, Closeable cancellation) { this.generation = generation; this.cancellation = cancellation; }
        public boolean isCurrent() {
            synchronized (RelayEgressGate.this) { return !closed && generation.isCurrent(); }
        }
        public void checkCurrent() throws IOException { if (!isCurrent()) throw new IOException("stale_relay_operation"); }
        private void cancelOnce() {
            synchronized (RelayEgressGate.this) {
                if (cancelled || closed) return;
                cancelled = true;
                pendingCancellations++;
            }
            CANCELLATIONS.execute(() -> {
                try { cancellation.close(); }
                catch (Exception ignored) { /* Still wait for actual operation completion. */ }
                finally {
                    synchronized (RelayEgressGate.this) {
                        pendingCancellations--;
                        RelayEgressGate.this.notifyAll();
                    }
                }
            });
        }
        @Override public void close() {
            synchronized (RelayEgressGate.this) {
                closed = true;
                active.remove(this);
                RelayEgressGate.this.notifyAll();
            }
        }
    }
}
