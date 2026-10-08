package com.squareup.zstd.okio;

import io.airlift.compress.zstd.ZstdInputStream;
import io.airlift.compress.zstd.ZstdOutputStream;
import java.io.IOException;
import okio.Okio;
import okio.Sink;
import okio.Source;

/** Keep the plugin API while using a JVM implementation on iOS, without JNI .so files. */
public final class OkioZstd {
    public static Source zstdDecompress(Source source) {
        return Okio.source(new ZstdInputStream(Okio.buffer(source).inputStream()));
    }
    public static Sink zstdCompress(Sink sink) throws IOException {
        return Okio.sink(new ZstdOutputStream(Okio.buffer(sink).outputStream()));
    }
    public static byte[] getEmptyByteArray() { return new byte[0]; }
}
