package android.telecom;

public final class DisconnectCause {
    public static final int MISSED = 5;
    private final int code;
    public DisconnectCause(int code) { this.code = code; }
    public int getCode() { return code; }
}
