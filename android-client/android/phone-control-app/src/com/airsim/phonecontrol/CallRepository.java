package com.airsim.phonecontrol;

import android.content.Context;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.telecom.Call;
import android.telecom.TelecomManager;
import android.telecom.VideoProfile;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.TimeUnit;

public final class CallRepository {
    private static final Map<String, Call> CALLS = new ConcurrentHashMap<>();
    private static final Map<Call, Object> DTMF_TONES = new ConcurrentHashMap<>();
    private static final Map<Call, String> IDS = new ConcurrentHashMap<>();
    static final String DIAL_COMMAND_EXTRA = "com.airsim.phonecontrol.DIAL_COMMAND_ID";
    private static final Map<String, Long> abandonedDials = new java.util.HashMap<>();
    private static final Object OUTGOING_LOCK = new Object();
    private static final java.util.Set<OutgoingCallObservation> OUTGOING =
            java.util.Collections.newSetFromMap(new java.util.WeakHashMap<>());

    static final EarlyMediaLeases EARLY_MEDIA = new EarlyMediaLeases(() -> System.nanoTime()/1_000_000L, CallRepository::earlyMediaEligible);
    static void revokeEarlyMedia(String id) { EARLY_MEDIA.revokeAndroid(id); }
    static void earlyMediaCallStateChanged(String id, int state) {
        // A dial receipt can precede repeated CONNECTING/details callbacks.
        // Keep its identity through setup; only DIALING may actually open PCM.
        if (!earlyMediaSetupState(state)) revokeEarlyMedia(id);
    }
    private static boolean earlyMediaSetupState(int state) {
        return state == Call.STATE_DIALING || state == Call.STATE_CONNECTING
            || state == Call.STATE_SELECT_PHONE_ACCOUNT;
    }
    private CallRepository() {}

    public static String add(Call call) {
        String id = UUID.randomUUID().toString();
        synchronized (OUTGOING_LOCK) {
            IDS.put(call, id);
            CALLS.put(id, call);
            var iterator = OUTGOING.iterator();
            while (iterator.hasNext()) {
                OutgoingCallObservation observation = iterator.next();
                if (System.nanoTime() >= observation.deadline || observation.created.size() >= 64) {
                    if (observation.created.size() >= 64) observation.overflow = true;
                    iterator.remove();
                } else observation.created.put(id, call);
            }
        }
        reconcileAbandonedDial(call);
        return id;
    }

    // A late Telecom callback may arrive after the HTTP receipt deadline. Only a
    // command ID recorded by our own placeCall can authorize asynchronous cleanup.
    static void abandonDial(String commandID) {
        if (commandID.isEmpty()) return;
        synchronized (abandonedDials) {
            long now = System.nanoTime();
            abandonedDials.values().removeIf(deadline -> deadline <= now);
            abandonedDials.put(commandID, now + TimeUnit.MINUTES.toNanos(2));
        }
        for (Call call : CALLS.values()) reconcileAbandonedDial(call);
    }

    static void reconcileAbandonedDial(Call call) {
        synchronized (abandonedDials) {
            if (abandonedDials.isEmpty()) return;
            String commandID = dialCommandID(call);
            Long deadline = abandonedDials.remove(commandID);
            if (deadline == null || System.nanoTime() > deadline) return;
        }
        disconnect(id(call));
    }

    private static String dialCommandID(Call call) {
        Call.Details details = call.getDetails();
        if (details == null || details.getCallDirection() != Call.Details.DIRECTION_OUTGOING) return "";
        android.os.Bundle extras = details.getIntentExtras();
        if (extras == null) return "";
        String id = extras.getString(DIAL_COMMAND_EXTRA, "");
        if (!id.isEmpty()) return id;
        android.os.Bundle nested = extras.getBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS);
        return nested == null ? "" : nested.getString(DIAL_COMMAND_EXTRA, "");
    }

    static String callForDialCommand(String commandID) {
        if (commandID.isEmpty()) return "";
        for (Map.Entry<String, Call> entry : CALLS.entrySet()) {
            if (commandID.equals(dialCommandID(entry.getValue()))) return entry.getKey();
        }
        return "";
    }

    /** Capture creation identity before placeCall, independently of delayed network events. */
    static OutgoingCallObservation observeOutgoing(String number) {
        synchronized (OUTGOING_LOCK) {
            var observation = new OutgoingCallObservation(number);
            OUTGOING.add(observation);
            return observation;
        }
    }

    static final class OutgoingCallObservation implements AutoCloseable {
        private final String number;
        private final long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(15);
        private final Map<String, Call> created = new java.util.LinkedHashMap<>();
        private boolean closed;
        private boolean overflow;

        private OutgoingCallObservation(String number) { this.number = number == null ? "" : number; }

        String matchingCallID() {
            synchronized (OUTGOING_LOCK) {
                if (System.nanoTime() >= deadline) OUTGOING.remove(this);
                if (closed || overflow || number.isBlank()) return "";
                String candidate = "";
                for (Map.Entry<String, Call> entry : created.entrySet()) {
                    Call.Details details = entry.getValue().getDetails();
                    if (details == null || details.getCallDirection() != Call.Details.DIRECTION_OUTGOING
                            || details.getHandle() == null || !android.telephony.PhoneNumberUtils.compare(
                            details.getHandle().getSchemeSpecificPart(), number)) continue;
                    if (!candidate.isEmpty()) return "";
                    candidate = entry.getKey();
                }
                return candidate;
            }
        }

        @Override public void close() {
            synchronized (OUTGOING_LOCK) {
                closed = true;
                OUTGOING.remove(this);
                created.clear();
            }
        }
    }

    public static String id(Call call) {
        return IDS.getOrDefault(call, "");
    }

    public static void remove(Call call) {
        DTMF_TONES.remove(call);
        String id = IDS.remove(call);
        if (id != null) CALLS.remove(id);
    }

    public static String firstId() {
        return idForAction("end");
    }

    public static java.util.Set<String> callIDs() { return new java.util.HashSet<>(CALLS.keySet()); }

    public static String newOutgoingCallSince(java.util.Set<String> before, String number) {
        if (number == null || number.trim().isEmpty()) return "";
        String candidate = "";
        for (Map.Entry<String, Call> entry : CALLS.entrySet()) {
            int state = entry.getValue().getState();
            if (before.contains(entry.getKey()) || state == Call.STATE_DISCONNECTED || state == Call.STATE_DISCONNECTING) continue;
            Call.Details details = entry.getValue().getDetails();
            if (details == null || details.getCallDirection() != Call.Details.DIRECTION_OUTGOING
                    || details.getHandle() == null || !android.telephony.PhoneNumberUtils.compare(
                            details.getHandle().getSchemeSpecificPart(), number)) continue;
            if (!candidate.isEmpty()) return "";
            candidate = entry.getKey();
        }
        return candidate;
    }

    public static void disconnect(String callID) {
        Call owned = CALLS.get(callID);
        if (owned == null) return;
        new Handler(Looper.getMainLooper()).post(() -> {
            if (CALLS.get(callID) != owned || owned.getState() == Call.STATE_DISCONNECTED
                    || owned.getState() == Call.STATE_DISCONNECTING) return;
            try { owned.disconnect(); } catch (RuntimeException ignored) {}
        });
    }

    /** Only the one still-unconnected outgoing carrier call may expose early downlink. */
    public static boolean earlyMediaEligible(String callId) {
        Call call = CALLS.get(callId);
        if (call == null || CALLS.size() != 1) return false;
        int state = call.getState();
        if (!earlyMediaSetupState(state)) return false;
        Call.Details details = call.getDetails();
        return details != null && details.getCallDirection() == Call.Details.DIRECTION_OUTGOING
            && details.getConnectTimeMillis() == 0;
    }

    public static int state(String callId) {
        Call call = CALLS.get(callId);
        return call == null ? -1 : call.getState();
    }

    /** Privacy-safe Telecom state for feedback diagnostics; never includes numbers or IDs. */
    public static String diagnosticState() {
        for (Call call : CALLS.values()) {
            if (call.getState() == Call.STATE_ACTIVE) return "active";
            if (call.getState() == Call.STATE_RINGING) return "ringing";
            if (call.getState() == Call.STATE_DIALING) return "dialing";
            if (call.getState() == Call.STATE_HOLDING) return "holding";
        }
        return CALLS.isEmpty() ? "idle" : "disconnecting";
    }

    public static String number(String callId) {
        Call call = CALLS.get(callId);
        if (call == null || call.getDetails() == null || call.getDetails().getHandle() == null) return "";
        return CallerNumber.display(call.getDetails().getHandle().toString());
    }

    public static String idForAction(String action) {
        int preferred = ("answer".equals(action) || "reject".equals(action))
                ? Call.STATE_RINGING : Call.STATE_ACTIVE;
        for (Map.Entry<String, Call> entry : CALLS.entrySet()) {
            if (entry.getValue().getState() == preferred) return entry.getKey();
        }
        if ("answer".equals(action) || "reject".equals(action)) return "";
        for (Map.Entry<String, Call> entry : CALLS.entrySet()) {
            int state = entry.getValue().getState();
            if (state != Call.STATE_DISCONNECTED && state != Call.STATE_DISCONNECTING) return entry.getKey();
        }
        return "";
    }

    static String idForPublishedAction(String action, String requestedID,
                                       String publishedID, String androidID) {
        if (requestedID == null || requestedID.isBlank()) return idForAction(action);
        if (!requestedID.equals(publishedID)) return "";
        Call call = CALLS.get(androidID);
        if (call == null) return "";
        int state = call.getState();
        if (state == Call.STATE_DISCONNECTED || state == Call.STATE_DISCONNECTING
                || ("reject".equals(action) && state != Call.STATE_RINGING)
                || ("answer".equals(action) && state != Call.STATE_RINGING
                    && state != Call.STATE_ACTIVE && state != Call.STATE_HOLDING)) return "";
        return androidID;
    }

    public static void disconnectAll() {
        new Handler(Looper.getMainLooper()).post(() -> {
            for (Call call : CALLS.values()) {
                try { call.disconnect(); }
                catch (RuntimeException ignored) {}
            }
        });
    }

    /** A Watch may claim only a still-ringing exact native instance, not take over an active call. */
    static ActionResult answerForWatch(String callID) {
        Call expected = CALLS.get(callID);
        if (expected == null) return ActionResult.failure("stale watch call");
        String error = TelecomInvocation.run(task -> new Handler(Looper.getMainLooper()).post(task), () -> {
            if (CALLS.get(callID) != expected || expected.getState() != Call.STATE_RINGING)
                throw new IllegalStateException("call answered elsewhere");
            expected.answer(VideoProfile.STATE_AUDIO_ONLY);
        }, 2_000L);
        return error.isEmpty() ? ActionResult.success() : ActionResult.failure(error);
    }

    public static ActionResult execute(Context context, AgentCommand command) {
        if (!command.isSupported()) return ActionResult.failure("unsupported action");
        if ("dial".equals(command.action)) {
            if (command.number.isEmpty()) return ActionResult.failure("number missing");
            String error = TelecomInvocation.run(
                    task -> new Handler(Looper.getMainLooper()).post(task),
                    () -> {
                        android.os.Bundle options = DefaultCallAccount.dialExtras(context, command.simAccount);
                        android.os.Bundle outgoing = new android.os.Bundle();
                        outgoing.putString(DIAL_COMMAND_EXTRA, command.id);
                        options.putBundle(TelecomManager.EXTRA_OUTGOING_CALL_EXTRAS, outgoing);
                        context.getSystemService(TelecomManager.class).placeCall(Uri.parse("tel:" + command.number), options);
                    },
                    2_000L);
            if (TelecomInvocation.OUTCOME_UNCONFIRMED.equals(error)) abandonDial(command.id);
            return error.isEmpty() ? ActionResult.success() : ActionResult.failure(error);
        }
        Call call = CALLS.get(command.callId);
        if (call == null) return ActionResult.failure("active call id mismatch");
        String failure = TelecomInvocation.run(task -> new Handler(Looper.getMainLooper()).post(task), () -> {
            if (CALLS.get(command.callId) != call) throw new IllegalStateException("stale call");
            switch (command.action) {
                case "answer" -> {
                    // A retry for this exact Telecom call must not re-answer or
                    // disturb the established audio route.
                    int state = call.getState();
                    if (state == Call.STATE_RINGING) call.answer(VideoProfile.STATE_AUDIO_ONLY);
                    else if (state != Call.STATE_ACTIVE && state != Call.STATE_HOLDING)
                        throw new IllegalStateException("call is not answerable");
                }
                case "reject" -> {
                    if (call.getState() == Call.STATE_RINGING) call.reject(false, null);
                    else throw new IllegalStateException("call is no longer ringing");
                }
                case "end" -> call.disconnect();
                case "dtmf" -> {
                    if (command.number.length() != 1) throw new IllegalArgumentException("DTMF digit missing");
                    char digit = command.number.charAt(0);
                    if ("0123456789*#ABCD".indexOf(digit) < 0) throw new IllegalArgumentException("invalid DTMF digit");
                    Object tone = new Object();
                    if (DTMF_TONES.containsKey(call)) call.stopDtmfTone();
                    call.playDtmfTone(digit);
                    DTMF_TONES.put(call, tone);
                    // Some ColorOS/Telecom stacks cancel a DTMF tone when
                    // stopDtmfTone() is called in the same main-thread turn.
                    // Let the tone reach the network before stopping it.
                    new Handler(Looper.getMainLooper()).postDelayed(() -> {
                        if (!DTMF_TONES.remove(call, tone)) return;
                        try { call.stopDtmfTone(); } catch (RuntimeException ignored) {}
                    }, 180);
                }
                default -> throw new IllegalArgumentException("unsupported action");
            }
        }, 2_000L);
        if (!failure.isEmpty()) return ActionResult.failure(failure);
        try {
            if ("dtmf".equals(command.action)) return ActionResult.success();
            int expected = "answer".equals(command.action) ? Call.STATE_ACTIVE : Call.STATE_DISCONNECTED;
            long deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(5);
            while (System.nanoTime() < deadline) {
                if (call.getState() == expected
                        || (expected == Call.STATE_ACTIVE && call.getState() == Call.STATE_HOLDING)
                        || (expected == Call.STATE_DISCONNECTED && !IDS.containsKey(call))) {
                    return ActionResult.success();
                }
                Thread.sleep(50);
            }
            // Never end an unidentified foreground call when this exact call is slow to acknowledge.
            if ("end".equals(command.action) && !IDS.containsKey(call)) return ActionResult.success();
            return ActionResult.failure("Telecom state confirmation timeout");
        } catch (Exception error) {
            return ActionResult.failure(error.getClass().getSimpleName() + ": " + error.getMessage());
        }
    }

    public static ActionResult executeRemote(
            Context context, String requestId, String action, String callId, String number) {
        return executeRemote(context, requestId, action, callId, number, "");
    }

    public static ActionResult executeRemote(
            Context context, String requestId, String action, String callId, String number,
            String simAccount) {
        return execute(context, new AgentCommand(requestId, action, callId, number, "", simAccount));
    }

    public static final class ActionResult {
        public final boolean success;
        public final String error;

        ActionResult(boolean success, String error) {
            this.success = success;
            this.error = error;
        }

        static ActionResult success() { return new ActionResult(true, ""); }
        static ActionResult failure(String error) { return new ActionResult(false, error == null ? "unknown" : error); }
    }
}
