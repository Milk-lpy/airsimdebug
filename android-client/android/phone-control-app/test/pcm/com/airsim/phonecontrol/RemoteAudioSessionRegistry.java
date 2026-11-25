package com.airsim.phonecontrol;
public final class RemoteAudioSessionRegistry {
    public static volatile boolean active;
    private static volatile int rate;
    public static int vowlanSampleRate() { return rate; }
    public static void setVoWLAN(boolean value) { setVoWLAN(value, 0); }
    static void setVoWLAN(boolean value, int sampleRate) { rate = value ? sampleRate : 0; active = value; }
}
