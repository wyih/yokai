package yokai;

import okhttp3.*;
import org.json.*;
import java.util.*;

/** Cookie persistence uses the iOS Keychain, including sessions from the in-app WebView. */
public final class Cookies implements CookieJar {
    public static final Cookies INSTANCE = new Cookies();
    private final Map<String,Cookie> values = new HashMap<>();
    private Cookies() {
        try {
            JSONArray entries = new JSONObject(NativeServices.readPreferences("_http_cookies")).optJSONArray("cookies");
            if(entries!=null)for(int i=0;i<entries.length();i++){
                JSONObject item=entries.getJSONObject(i);Cookie c=Cookie.parse(HttpUrl.get(item.getString("url")),item.getString("header"));if(c!=null)values.put(key(c),c);
            }
        }catch(JSONException e){throw new IllegalStateException("Cookie data could not be read",e);}
    }
    private static String key(Cookie c){return c.domain()+"\n"+c.path()+"\n"+c.name();}
    public synchronized List<Cookie> loadForRequest(HttpUrl url){List<Cookie> result=new ArrayList<>();for(Cookie c:values.values())if(c.expiresAt()>System.currentTimeMillis()&&c.matches(url))result.add(c);return result;}
    public synchronized void saveFromResponse(HttpUrl url,List<Cookie> cookies){for(Cookie c:cookies)values.put(key(c),c);save();}
    private static boolean inScope(Cookie c,String host){return host.equals(c.domain())||host.endsWith("."+c.domain());}
    public synchronized JSONArray exportWebView(String host)throws JSONException {
        JSONArray result=new JSONArray();
        for(Cookie c:values.values())if(inScope(c,host)&&c.expiresAt()>System.currentTimeMillis()){
            JSONObject value=new JSONObject().put("name",c.name()).put("value",c.value()).put("domain",(c.hostOnly()?"":".")+c.domain()).put("path",c.path()).put("secure",c.secure()).put("httpOnly",c.httpOnly());
            if(c.persistent())value.put("expires",c.expiresAt());result.put(value);
        }
        return result;
    }
    public synchronized void importWebView(JSONArray items,JSONArray hosts)throws JSONException {
        Set<String> scope=new HashSet<>();for(int i=0;i<hosts.length();i++)scope.add(hosts.getString(i));
        values.values().removeIf(c->scope.stream().anyMatch(h->inScope(c,h)));
        for(int i=0;i<items.length();i++){
            JSONObject item=items.getJSONObject(i);String domain=item.getString("domain");
            Cookie.Builder b=new Cookie.Builder().name(item.getString("name")).value(item.getString("value")).path(item.optString("path","/"));
            if(domain.startsWith("."))b.domain(domain.substring(1));else b.hostOnlyDomain(domain);
            if(item.optBoolean("secure"))b.secure();if(item.optBoolean("httpOnly"))b.httpOnly();
            if(item.has("expires"))b.expiresAt(item.getLong("expires"));Cookie c=b.build();
            if(scope.stream().anyMatch(h->inScope(c,h)))values.put(key(c),c);
        }
        save();
    }
    private void save(){
        JSONArray entries=new JSONArray();
        try{for(Cookie c:values.values())if(c.expiresAt()>System.currentTimeMillis())entries.put(new JSONObject().put("url",(c.secure()?"https://":"http://")+c.domain()+c.path()).put("header",c.toString()));NativeServices.writePreferences("_http_cookies",new JSONObject().put("cookies",entries).toString());}
        catch(JSONException e){throw new IllegalStateException(e);}
    }
}
