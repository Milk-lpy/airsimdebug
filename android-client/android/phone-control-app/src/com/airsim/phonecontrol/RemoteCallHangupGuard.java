package com.airsim.phonecontrol;

/** Loss of an audio transport does not authorize ending a Telecom call. */
final class RemoteCallHangupGuard {
    private RemoteCallHangupGuard() {}

    static void ownerBound(String callID) {
        // Ownership and routing are handled by RemoteCallAudioScope.
    }

    static void ownerLost(String callID) {
        if (callID != null && !callID.isEmpty()) {
            BridgeLog.info("remote_audio_owner_lost_keep_call");
        }
    }
}
