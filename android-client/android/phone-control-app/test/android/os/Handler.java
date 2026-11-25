package android.os;

public final class Handler {
    public static java.util.function.Consumer<Runnable> delayedForTest = Runnable::run;
    public Handler(Looper looper) {}
    // This synchronous test looper has no pending callbacks after post/postDelayed returns.
    public void removeCallbacks(Runnable action) {}

    public boolean post(Runnable action) {
        action.run();
        return true;
    }

    public boolean postDelayed(Runnable action, long delayMillis) {
        delayedForTest.accept(action);
        return true;
    }
}
