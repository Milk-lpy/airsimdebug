package com.airsim.phonecontrol;

import android.telecom.Call;

public final class CloudOutgoingObservationTests {
    public static void main(String[] args) throws Exception {
        if (args.length == 1) checkNumberFixtures(java.nio.file.Path.of(args[0]));
        imsDisplayKeepsCallIdentity();
        existingCallsExcludedAndRemovedCallsRetained();
        ambiguousCallsStayAmbiguousAfterRemoval();
        closedAndExpiredObservationCannotAcquireFutureCalls();
        overflowFailsClosed();
        System.out.println("CloudOutgoingObservationTests passed");
    }
    private static void checkNumberFixtures(java.nio.file.Path path) throws Exception {
        var cases = new org.json.JSONArray(java.nio.file.Files.readString(path));
        for (int index = 0; index < cases.length(); index++) {
            var pair = cases.getJSONArray(index);
            String displayed = CallerNumber.display(pair.getString(0));
            check(displayed.equals(pair.getString(1)), "unexpected display for case " + index);
            check(CallerNumber.display(displayed).equals(displayed), "unstable display for case " + index);
        }
        System.out.println("Caller number fixtures passed: " + cases.length());
    }

    private static void imsDisplayKeepsCallIdentity() {
        var call = new Call(Call.STATE_RINGING, 0, "sip:%2B8613800138000@ims.example;user=phone");
        String id = CallRepository.add(call);
        try {
            check(CallRepository.number(id).equals("+8613800138000"), "raw IMS domain leaked");
            call.setNumberForTest("tel:+8613800138000");
            check(CallRepository.id(call).equals(id), "display update changed call identity");
            check(CallRepository.number(id).equals("+8613800138000"), "plain handle changed");
            call.setNumberForTest("");
            check(CallRepository.number(id).isEmpty(), "withheld number became a nonempty URL");
        } finally { CallRepository.remove(call); }
    }
    private static Call outgoing() { return new Call(1, 1, "5550100"); }
    private static void check(boolean ok, String message) { if (!ok) throw new AssertionError(message); }

    private static void existingCallsExcludedAndRemovedCallsRetained() {
        var old = outgoing(); CallRepository.add(old);
        var fresh = outgoing();
        try (var observation = CallRepository.observeOutgoing("5550100")) {
            check(observation.matchingCallID().isEmpty(), "pre-existing call cannot bind");
            String id = CallRepository.add(fresh);
            CallRepository.remove(fresh);
            check(id.equals(observation.matchingCallID()), "creation identity must survive removal");
        } finally { CallRepository.remove(old); CallRepository.remove(fresh); }
    }

    private static void ambiguousCallsStayAmbiguousAfterRemoval() {
        var a = outgoing(); var b = outgoing();
        try (var observation = CallRepository.observeOutgoing("5550100")) {
            CallRepository.add(a); CallRepository.add(b);
            check(observation.matchingCallID().isEmpty(), "two same-number new calls must not be guessed");
            CallRepository.remove(a);
            check(observation.matchingCallID().isEmpty(), "removal cannot resolve which dial was ours");
        } finally { CallRepository.remove(a); CallRepository.remove(b); }
    }

    private static void closedAndExpiredObservationCannotAcquireFutureCalls() throws Exception {
        var call = outgoing();
        try (var observation = CallRepository.observeOutgoing("5550100")) {
            observation.close(); CallRepository.add(call);
            check(observation.matchingCallID().isEmpty(), "closed observation cannot capture");
        } finally { CallRepository.remove(call); }
        var late = outgoing();
        try (var observation = CallRepository.observeOutgoing("5550100")) {
            var deadline = observation.getClass().getDeclaredField("deadline"); deadline.setAccessible(true);
            deadline.setLong(observation, 0); // Expire without sleeping; only time is controlled.
            CallRepository.add(late);
            check(observation.matchingCallID().isEmpty(), "expired observation cannot capture a later unrelated dial");
        } finally { CallRepository.remove(late); }
    }

    private static void overflowFailsClosed() {
        var calls = new java.util.ArrayList<Call>();
        try (var observation = CallRepository.observeOutgoing("5550100")) {
            var owner = outgoing(); calls.add(owner); CallRepository.add(owner);
            for (int i = 0; i < 64; i++) {
                var call = new Call(2, 0, "5550199"); calls.add(call); CallRepository.add(call);
            }
            check(observation.matchingCallID().isEmpty(), "overflow cannot silently discard ambiguous candidates");
        } finally { calls.forEach(CallRepository::remove); }
    }
}
