package eu.kanade.tachiyomi.network.interceptor;

import java.io.IOException;
import java.util.Locale;
import kotlin.Unit;
import kotlin.jvm.functions.Function1;
import okhttp3.Interceptor;
import okhttp3.Response;
import okhttp3.ResponseBody;
import okio.GzipSource;
import okio.Okio;

/** Keep the extension client contract; website verification runs in the user's WKWebView. */
public final class CloudflareInterceptor implements Interceptor {
    public CloudflareInterceptor(Function1<? super String, Unit> setUserAgent) {}
    @Override public Response intercept(Chain chain) throws IOException {
        // The Android extension client advertises zstd, whose decoder requires a desktop JNI library.
        // Negotiate the standard gzip decoder available in the embedded Java runtime instead.
        Response response = chain.proceed(chain.request().newBuilder().header("Accept-Encoding", "gzip").build());
        String server = response.header("Server", "").toLowerCase(Locale.ROOT);
        boolean challenge = "challenge".equalsIgnoreCase(response.header("cf-mitigated"))
            || ((response.code() == 403 || response.code() == 503) && server.contains("cloudflare"));
        if (challenge) {
            response.close();
            throw new IOException("请在 WebView 中完成网站验证，点完成后重试。");
        }
        if ("gzip".equalsIgnoreCase(response.header("Content-Encoding")) && response.body() != null) {
            ResponseBody body = response.body();
            return response.newBuilder().removeHeader("Content-Encoding").removeHeader("Content-Length")
                .body(ResponseBody.create(body.contentType(), -1, Okio.buffer(new GzipSource(body.source())))).build();
        }
        return response;
    }
}
