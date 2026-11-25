package com.airsim.phonecontrol;

import java.io.BufferedReader;
import java.io.IOException;
import java.io.Reader;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Pattern;

/** Read only current displayed bars, not raw radio levels or earlier UI states. */
final class RealmeSignalPolicy {
    private static final Pattern CONTROLLER = Pattern.compile("^\\s*- NetworkController\\.MobileSignalController\\((\\d{1,10})\\) -+\\s*$");
    private static final Pattern STATE = Pattern.compile("^\\s*Current State: connected=true,enabled=true,level=([0-4])(?:,|$).*");
    static Map<Integer, Integer> read(Reader reader) throws IOException {
        var result = new HashMap<Integer,Integer>();
        var in = new BufferedReader(reader);
        Integer subscription = null;
        String line;
        for (int count = 0; count < 40_000 && (line = in.readLine()) != null; count++) {
            var header = CONTROLLER.matcher(line);
            if (header.matches()) {
                try { subscription = Integer.valueOf(header.group(1)); }
                catch (NumberFormatException overflow) { subscription = null; }
            } else if (subscription != null) {
                // Only the first line immediately below a controller header counts.
                var state = STATE.matcher(line);
                if (state.matches()) result.put(subscription, Integer.valueOf(state.group(1)));
                subscription = null;
            }
        }
        return Map.copyOf(result);
    }
}
