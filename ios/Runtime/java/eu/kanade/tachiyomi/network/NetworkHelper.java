package eu.kanade.tachiyomi.network;
import okhttp3.OkHttpClient;
public final class NetworkHelper {
 private final OkHttpClient client = new OkHttpClient.Builder()
     .addInterceptor(new eu.kanade.tachiyomi.network.interceptor.UncaughtExceptionInterceptor())
     .addInterceptor(new eu.kanade.tachiyomi.network.interceptor.UserAgentInterceptor(()->System.getProperty("http.agent")))
     .addInterceptor(new eu.kanade.tachiyomi.network.interceptor.CloudflareInterceptor(ua->{System.setProperty("http.agent",ua);return kotlin.Unit.INSTANCE;}))
     .cookieJar(yokai.Cookies.INSTANCE).callTimeout(40, java.util.concurrent.TimeUnit.SECONDS).build();
 public OkHttpClient getClient(){return client;}
 public OkHttpClient getCloudflareClient(){return client;}
 public String defaultUserAgentProvider(){return System.getProperty("http.agent");}
}
