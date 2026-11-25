package com.airsim.phonecontrol;

import java.net.SocketException;
import java.util.Locale;

final class VoWLANPollReply {
    static boolean isPeerDisconnect(String method, String path, Throwable error) {
        if (!"GET".equals(method) || !(error instanceof SocketException)) return false;
        String endpoint = path.split("\\?",2)[0];
        if (!"/api/events".equals(endpoint) && !"/api/calls/events".equals(endpoint)) return false;
        String text = String.valueOf(error.getMessage()).toLowerCase(Locale.ROOT);
        return text.contains("broken pipe") || text.contains("connection reset");
    }
}
