package yokai;

/** iOS implementations are registered with JNI before extensions are initialized. */
public final class NativeServices {
    public static native String readPreferences(String name);
    public static native void writePreferences(String name, String json);
    public static native void openWebView(String url, String source);
}
