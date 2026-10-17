package yokai;

import android.app.Application;
import android.content.*;
import androidx.preference.*;
import eu.kanade.tachiyomi.network.NetworkHelper;
import eu.kanade.tachiyomi.source.*;
import eu.kanade.tachiyomi.source.model.*;
import eu.kanade.tachiyomi.source.online.HttpSource;
import kotlinx.serialization.json.Json;
import kotlinx.serialization.json.JsonObject;
import kotlinx.coroutines.BuildersKt;
import kotlin.coroutines.EmptyCoroutineContext;
import org.json.*;
import java.io.*;
import java.net.*;
import java.lang.reflect.*;
import java.util.*;
import java.util.concurrent.locks.ReentrantReadWriteLock;

/** Original extension API hosted entirely in this iOS process. */
public final class Engine {
    // Original Android downloads run two image requests at once. Reloading an
    // extension must still wait until requests using its class loader finish.
    private static final ReentrantReadWriteLock executionLock=new ReentrantReadWriteLock(true);
    private static final Map<String,Source> sources=new LinkedHashMap<>();
    private static final List<Loader> loaders=new ArrayList<>();
    private static final Map<String,PreferenceScreen> screens=new HashMap<>();
    private static final Json json=kotlinx.serialization.json.JsonKt.Json(Json.Default,b->{b.setIgnoreUnknownKeys(true);b.setExplicitNulls(false);return kotlin.Unit.INSTANCE;});
    private static Context context;

    static final class Loader extends URLClassLoader {
        Loader(File file)throws MalformedURLException{super(new URL[]{file.toURI().toURL()},Engine.class.getClassLoader());}
        protected Class<?> loadClass(String n,boolean resolve)throws ClassNotFoundException {
            boolean shared=n.startsWith("java.")||n.startsWith("javax.")||n.startsWith("kotlin.")||n.startsWith("kotlinx.")||n.startsWith("android.")||n.startsWith("androidx.")||n.startsWith("okhttp3.")||n.startsWith("okio.")||n.startsWith("rx.")||n.startsWith("uy.")||n.startsWith("eu.kanade.tachiyomi.source.")||n.startsWith("eu.kanade.tachiyomi.network.");
            if(shared)return super.loadClass(n,resolve);
            synchronized(getClassLoadingLock(n)){Class<?> c=findLoadedClass(n);if(c==null){try{c=findClass(n);}catch(ClassNotFoundException e){c=super.loadClass(n,false);}}if(resolve)resolveClass(c);return c;}
        }
    }

    private static void initialize(final String dataPath) {
        if(context!=null)return;
        System.setProperty("http.agent","Mozilla/5.0 (iPhone; CPU iPhone OS 27_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148");
        context=new ContextWrapper(null){
            private final Map<String,SharedPreferences> prefs=new HashMap<>();
            public Context getApplicationContext(){return this;}
            public String getPackageName(){return "com.wyih.yokai";}
            public File getFilesDir(){return new File(dataPath);}
            public File getCacheDir(){File f=new File(dataPath,"Cache");f.mkdirs();return f;}
            public synchronized SharedPreferences getSharedPreferences(String n,int m){return prefs.computeIfAbsent(n,k->{try{return new Preferences(k).get();}catch(JSONException e){throw new IllegalStateException(e);}});}
            public void startActivity(Intent intent){NativeServices.openWebView(intent.getStringExtra("url_key"),Long.toString(intent.getLongExtra("source_key",0)));}
        };
        Application application=new Application(){
            { attachBaseContext(context); }
            public Context getApplicationContext(){return context;}
            public SharedPreferences getSharedPreferences(String n,int m){return context.getSharedPreferences(n,m);}
            public String getPackageName(){return context.getPackageName();}
        };
        Map<String,Object> services=new HashMap<>();
        services.put(Application.class.getName(),application);services.put(Context.class.getName(),context);
        services.put(NetworkHelper.class.getName(),new NetworkHelper());services.put(Json.class.getName(),json);
        uy.kohesive.injekt.api.InjektRegistrar registrar=(uy.kohesive.injekt.api.InjektRegistrar)java.lang.reflect.Proxy.newProxyInstance(Engine.class.getClassLoader(),new Class[]{uy.kohesive.injekt.api.InjektRegistrar.class},(p,m,args)->{
            if(m.getName().equals("toString"))return "iOS extension services";
            Type type=(Type)args[0];Object instance=services.get(type.getTypeName());
            if(m.getName().equals("hasFactory"))return instance!=null;
            if(instance!=null)return instance;
            if(m.getName().endsWith("OrNull"))return null;
            if(m.getName().endsWith("OrElse")){Object fallback=args[args.length-1];return fallback instanceof kotlin.jvm.functions.Function0?((kotlin.jvm.functions.Function0<?>)fallback).invoke():fallback;}
            throw new IllegalArgumentException("Unsupported extension service: "+type.getTypeName());
        });
        uy.kohesive.injekt.InjektKt.setInjekt(new uy.kohesive.injekt.api.InjektScope(registrar));
    }

    public static String execute(String request) {
        java.util.concurrent.locks.Lock lock=null;
        try {
            JSONObject q=new JSONObject(request);String action=q.getString("action");
            boolean reading=Arrays.asList("image","cover","popular","latest","search","details","pages","filters","webViewInfo","imageRequest").contains(action);
            lock=reading?executionLock.readLock():executionLock.writeLock();lock.lock();
            return new JSONObject().put("value",dispatch(q)).toString();
        }
        catch(Throwable e){while(e instanceof InvocationTargetException&&e.getCause()!=null)e=e.getCause();return new JSONObject(Collections.singletonMap("error",e.getMessage()==null?e.toString():e.getMessage())).toString();}
        finally {if(lock!=null)lock.unlock();}
    }

    private static Object dispatch(JSONObject q)throws Exception {
        String action=q.getString("action");
        if(action.equals("readAndroidBackup"))return AndroidBackup.read(q.getString("path"));
        if(action.equals("readRepositoryIndex"))return RepositoryIndex.read(q.getString("path"));
        if(action.equals("writeAndroidBackup"))return AndroidBackup.write(q);
        if(action.equals("storeAndroidBackupExtras")){NativeServices.writePreferences("android_backup_extras",new JSONObject().put("extraFields",q.getString("extraFields")).toString());return true;}
        if(action.equals("androidBackupExtras"))return new JSONObject(NativeServices.readPreferences("android_backup_extras")).optString("extraFields","");
        if(action.equals("exportSourcePreferences")) {
            JSONArray result=new JSONArray();
            for(String id:sources.keySet()) {
                String name="source_"+id;JSONArray preferences=new JSONArray();
                for(var entry:context.getSharedPreferences(name,0).getAll().entrySet()) {
                    Object value=entry.getValue();String type=value instanceof Set?"set":value instanceof Long?"long":value instanceof Integer?"int":value instanceof Float?"float":value instanceof Boolean?"boolean":"string";
                    preferences.put(new JSONObject().put("key",entry.getKey()).put("type",type).put("value",value instanceof Set?new JSONArray((Set<?>)value):value));
                }
                result.put(new JSONObject().put("name",name).put("preferences",preferences));
            }return result;
        }
        if(action.equals("restoreSourcePreferences")) {
            JSONArray records=q.getJSONArray("preferences");
            for(int i=0;i<records.length();i++) {
                JSONObject row=records.getJSONObject(i);String name=row.getString("name");
                if(!name.startsWith("source_"))continue;
                SharedPreferences.Editor editor=context.getSharedPreferences(name,0).edit();JSONArray entries=row.getJSONArray("preferences");
                for(int j=0;j<entries.length();j++) {
                    JSONObject item=entries.getJSONObject(j);String key=item.getString("key");
                    switch(item.getString("type")) {
                        case "long": editor.putLong(key,item.getLong("value"));break;
                        case "int": editor.putInt(key,item.getInt("value"));break;
                        case "float": editor.putFloat(key,(float)item.getDouble("value"));break;
                        case "boolean": editor.putBoolean(key,item.getBoolean("value"));break;
                        case "set": Set<String> values=new HashSet<>();JSONArray array=item.getJSONArray("value");for(int k=0;k<array.length();k++)values.add(array.getString(k));editor.putStringSet(key,values);break;
                        default: editor.putString(key,item.getString("value"));break;
                    }
                }editor.commit();
            }screens.clear();return true;
        }
        if(action.equals("inspect"))return Artifact.inspect(q.getString("input"),q.getString("output"));
        if(action.equals("validateArtifact")) {
            initialize(q.getString("dataPath"));
            try(Loader loader=new Loader(new File(q.getString("path")))) {
                Object factory=Class.forName(q.getString("className"),true,loader).getDeclaredConstructor().newInstance();
                List<Source> created=factory instanceof SourceFactory?((SourceFactory)factory).createSources():Collections.singletonList((Source)factory);
                if(created.isEmpty())throw new IOException("插件没有提供漫画源。");
                for(Source s:created){s.getId();s.getName();s.getLang();}
                return true;
            }
        }
        if(action.equals("exportCookies"))return Cookies.INSTANCE.exportWebView(q.getString("host"));
        if(action.equals("cookies")){Cookies.INSTANCE.importWebView(q.getJSONArray("cookies"),q.getJSONArray("hosts"));return true;}
        if(action.equals("load")) {
            initialize(q.getString("dataPath"));
            sources.clear();screens.clear();for(Loader old:loaders)old.close();loaders.clear();
            JSONArray result=new JSONArray(),extensions=q.getJSONArray("extensions");
            for(int i=0;i<extensions.length();i++) {
                JSONObject item=extensions.getJSONObject(i);
                try {
                    Loader loader=new Loader(new File(item.getString("path")));loaders.add(loader);
                    Object factory=Class.forName(item.getString("className"),true,loader).getDeclaredConstructor().newInstance();
                    List<Source> created=factory instanceof SourceFactory?((SourceFactory)factory).createSources():Collections.singletonList((Source)factory);
                    for(Source source:created){String id=Long.toString(source.getId());sources.put(id,source);result.put(new JSONObject().put("id",id).put("name",source.getName()).put("lang",source.getLang()).put("latest",source.getSupportsLatest()).put("baseURL",source instanceof HttpSource?((HttpSource)source).getBaseUrl():"").put("package",item.getString("package")));}
                }catch(Throwable e){while((e instanceof InvocationTargetException||e instanceof ExceptionInInitializerError||e instanceof UndeclaredThrowableException)&&e.getCause()!=null)e=e.getCause();result.put(new JSONObject().put("package",item.getString("package")).put("error",e.toString()));}
            }
            return result;
        }
        Source source=sources.get(q.getString("source"));if(source==null)throw new IOException("请先安装此漫画源插件。");
        if(action.equals("webViewInfo")) {
            if(!(source instanceof HttpSource))throw new IOException("此源没有提供网页地址。");
            HttpSource http=(HttpSource)source;
            JSONObject headers=new JSONObject();
            for(String name:http.getHeaders().names())headers.put(name,http.getHeaders().get(name));
            JSONObject item=q.optJSONObject("manga");
            String address=item==null?http.getBaseUrl():http.getMangaUrl(manga(item));
            return new JSONObject().put("url",address).put("headers",headers);
        }
        if(action.equals("imageRequest")) {
            if(!(source instanceof HttpSource))throw new IOException("此源未提供 HTTP 图片下载。");
            HttpSource http=(HttpSource)source;
            okhttp3.HttpUrl url=okhttp3.HttpUrl.get(q.getString("url"));
            JSONObject headers=new JSONObject();
            for(String name:http.getHeaders().names())headers.put(name,http.getHeaders().get(name));
            List<okhttp3.Cookie> cookies=http.getClient().cookieJar().loadForRequest(url);
            if(!cookies.isEmpty()) {
                List<String> pairs=new ArrayList<>();for(okhttp3.Cookie c:cookies)pairs.add(c.name()+"="+c.value());
                headers.put("Cookie",String.join("; ",pairs));
            }
            return headers;
        }
        if(action.equals("cover")) {
            if(!(source instanceof HttpSource))throw new IOException("此源未提供 HTTP 图片下载。");
            HttpSource http=(HttpSource)source;
            okhttp3.Request.Builder builder=new okhttp3.Request.Builder().url(q.getString("url")).headers(http.getHeaders());
            if(q.optBoolean("refresh"))builder.cacheControl(okhttp3.CacheControl.FORCE_NETWORK);
            okhttp3.Request request=builder.build();
            try(okhttp3.Response response=http.getClient().newCall(request).execute()) {
                if(!response.isSuccessful())throw new IOException("封面加载失败（HTTP "+response.code()+"）");
                try(OutputStream out=new FileOutputStream(q.getString("path"))){byte[] buffer=new byte[64*1024];InputStream in=response.body().byteStream();int count;while((count=in.read(buffer))!=-1)out.write(buffer,0,count);}
            }
            return true;
        }
        if(action.equals("popular")||action.equals("latest")||action.equals("search")) {
            int page=q.optInt("page",1);
            FilterList filters=action.equals("search")?source.getFilterList():new FilterList();
            if(action.equals("search")&&q.has("filters"))applyFilters(filters,q.getJSONArray("filters"));
            MangasPage result=BuildersKt.<MangasPage>runBlocking(EmptyCoroutineContext.INSTANCE,(scope,c)->action.equals("search")?source.getSearchManga(page,q.optString("query"),filters,c):action.equals("latest")?source.getLatestUpdates(page,c):source.getPopularManga(page,c));
            JSONArray manga=new JSONArray();for(SManga m:result.getMangas())manga.put(manga(m));
            return new JSONObject().put("manga",manga).put("hasNext",result.getHasNextPage());
        }
        if(action.equals("filters"))return filters(source.getFilterList());
        if(action.equals("details")) {
            SManga manga=manga(q.getJSONObject("manga"));
            SMangaUpdate update=BuildersKt.<SMangaUpdate>runBlocking(EmptyCoroutineContext.INSTANCE,(scope,c)->source.getMangaUpdate(manga,Collections.emptyList(),true,true,c));
            JSONArray chapters=new JSONArray();for(SChapter c:update.getChapters())chapters.put(chapter(c));
            return new JSONObject().put("manga",manga(update.getManga())).put("chapters",chapters);
        }
        if(action.equals("pages")) {
            SChapter chapter=chapter(q.getJSONObject("chapter"));
            List<? extends Page> result=BuildersKt.<List<? extends Page>>runBlocking(EmptyCoroutineContext.INSTANCE,(scope,c)->source.getPageList(chapter,c));
            JSONArray pages=new JSONArray();for(Page p:result)pages.put(new JSONObject().put("index",p.getIndex()).put("url",p.getUrl()).put("imageURL",p.getImageUrl()));return pages;
        }
        if(action.equals("image")) {
            if(!(source instanceof HttpSource))throw new IOException("此源未提供 HTTP 图片下载。");
            JSONObject data=q.getJSONObject("page");Page page=new Page(data.getInt("index"),data.optString("url",""),data.optString("imageURL",null),null);
            okhttp3.Response response=BuildersKt.<okhttp3.Response>runBlocking(EmptyCoroutineContext.INSTANCE,(scope,c)->((HttpSource)source).getImage(page,c));
            try(response){if(!response.isSuccessful())throw new IOException("图片下载失败（HTTP "+response.code()+"）");try(OutputStream out=new FileOutputStream(q.getString("path"))){byte[] buffer=new byte[64*1024];InputStream in=response.body().byteStream();int count;while((count=in.read(buffer))!=-1)out.write(buffer,0,count);}}
            return true;
        }
        if(action.equals("preferences")) {
            // Sources can refresh mirror/image-host choices after a request.
            screens.remove(Long.toString(source.getId()));
            PreferenceScreen screen=screen(source);JSONArray preferences=new JSONArray();
            for(int i=0;i<screen.getPreferences().size();i++) {
                Preference p=screen.getPreferences().get(i);
                if(!p.getVisible())continue;
                JSONObject item=new JSONObject().put("index",i).put("key",p.getKey()).put("title",p.getTitle()).put("summary",p.getSummary()).put("enabled",p.isEnabled()).put("kind",p.getClass().getSimpleName());
                item.put("clickable",p.hasClickListener()).put("category",p.getClass().getSimpleName().equals("PreferenceCategory"));
                if(p.getKey()!=null){Object value=p.getCurrentValue();item.put("value",value instanceof Set?new JSONArray((Set<?>)value):value);}
                if(p instanceof ListPreference){ListPreference list=(ListPreference)p;item.put("entries",new JSONArray(Arrays.asList(list.getEntries()))).put("values",new JSONArray(Arrays.asList(list.getEntryValues())));}
                if(p instanceof MultiSelectListPreference){MultiSelectListPreference list=(MultiSelectListPreference)p;item.put("entries",new JSONArray(Arrays.asList(list.getEntries()))).put("values",new JSONArray(Arrays.asList(list.getEntryValues())));}
                Object value=p.getCurrentValue();if(value!=null)item.put("valueType",value instanceof Set?"set":value instanceof Boolean?"boolean":value instanceof Number?"number":"string");
                preferences.put(item);
            }
            return preferences;
        }
        if(action.equals("setPreference")) {
            for(Preference p:screen(source).getPreferences())if(q.getString("key").equals(p.getKey())){
                Object value=q.get("value");
                if(p instanceof MultiSelectListPreference){JSONArray entries=(JSONArray)value;Set<String> set=new LinkedHashSet<>();for(int i=0;i<entries.length();i++)set.add(entries.getString(i));value=set;}
                Object old=p.getCurrentValue();
                if(value instanceof Number){if(old instanceof Float)value=((Number)value).floatValue();else if(old instanceof Long)value=((Number)value).longValue();else if(old instanceof Integer)value=((Number)value).intValue();}
                if(!p.callChangeListener(value))throw new IOException("图源未接受此设置，请检查输入内容。");
                p.saveNewValue(value);return true;
            }throw new IOException("设置项不存在。");
        }
        if(action.equals("clickPreference")) {
            Preference p=screen(source).getPreferences().get(q.getInt("index"));return p.callClickListener();
        }
        throw new IOException("Unsupported operation: "+action);
    }

    private static PreferenceScreen screen(Source source) {
        return screens.computeIfAbsent(Long.toString(source.getId()),key->{PreferenceScreen screen=new PreferenceScreen(context);screen.setSharedPreferences(context.getSharedPreferences("source_"+key,0));if(source instanceof ConfigurableSource)((ConfigurableSource)source).setupPreferenceScreen(screen);return screen;});
    }
    private static JSONArray filters(List<?> list)throws Exception {
        JSONArray result=new JSONArray();
        for(int i=0;i<list.size();i++) {
            Filter<?> filter=(Filter<?>)list.get(i);JSONObject item=new JSONObject().put("index",i).put("name",filter.getName());Object state=filter.getState();
            String kind=filter instanceof Filter.Group?"group":filter instanceof Filter.Select?"select":filter instanceof Filter.Sort?"sort":filter instanceof Filter.TriState?"triState":filter instanceof Filter.CheckBox?"checkbox":filter instanceof Filter.Text?"text":filter instanceof Filter.Separator?"separator":"header";
            item.put("kind",kind);
            if(kind.equals("group"))item.put("children",filters((List<?>)state));
            else if(kind.equals("sort")){Filter.Sort sort=(Filter.Sort)filter;Filter.Sort.Selection selection=sort.getState();item.put("values",new JSONArray(Arrays.asList(sort.getValues()))).put("selection",selection==null?-1:selection.getIndex()).put("ascending",selection!=null&&selection.getAscending());}
            else {item.put("value",state);if(kind.equals("select"))item.put("values",new JSONArray(((Filter.Select<?>)filter).getDisplayValues()));}
            result.put(item);
        }return result;
    }
    @SuppressWarnings({"rawtypes","unchecked"})
    private static void applyFilters(List<?> list,JSONArray values)throws Exception {
        for(int i=0;i<values.length();i++) {
            JSONObject item=values.getJSONObject(i);int index=item.getInt("index");
            if(index<0||index>=list.size())throw new IOException("图源筛选项已经更新，请重新设置筛选。");
            Filter filter=(Filter)list.get(index);
            // A plugin update can change the filter list. Match names and types before applying saved state.
            if(!filter.getName().equals(item.optString("name")))throw new IOException("图源筛选项已经更新，请重新设置筛选。");
            if(filter instanceof Filter.Group)applyFilters((List<?>)filter.getState(),item.getJSONArray("children"));
            else if(filter instanceof Filter.Sort){int selection=item.optInt("selection",-1);if(selection>=((Filter.Sort)filter).getValues().length)throw new IOException("排序项已改变。");filter.setState(selection<0?null:new Filter.Sort.Selection(selection,item.optBoolean("ascending",false)));}
            else if(filter instanceof Filter.Select){int selection=item.getInt("value");if(selection<0||selection>=((Filter.Select<?>)filter).getValues().length)throw new IOException("筛选选项已改变。");filter.setState(selection);}
            else if(filter instanceof Filter.TriState){int state=item.getInt("value");if(state<0||state>2)throw new IOException("筛选状态无效。");filter.setState(state);}
            else if(filter instanceof Filter.CheckBox)filter.setState(item.getBoolean("value"));
            else if(filter instanceof Filter.Text)filter.setState(item.getString("value"));
        }
    }
    private static JSONObject manga(SManga m)throws JSONException{return new JSONObject().put("url",m.getUrl()).put("title",m.getTitle()).put("thumbnail",m.getThumbnail_url()).put("author",m.getAuthor()).put("artist",m.getArtist()).put("description",m.getDescription()).put("genre",m.getGenre()).put("status",m.getStatus()).put("memo",m.getMemo()==null?"{}":m.getMemo().toString());}
    private static SManga manga(JSONObject data)throws JSONException{SManga m=SManga.Companion.create();m.setUrl(data.getString("url"));m.setTitle(data.optString("title",""));m.setThumbnail_url(data.optString("thumbnail",null));m.setMemo((JsonObject)json.parseToJsonElement(data.optString("memo","{}")));return m;}
    private static JSONObject chapter(SChapter c)throws JSONException{return new JSONObject().put("url",c.getUrl()).put("name",c.getName()).put("number",Float.isFinite(c.getChapter_number())?c.getChapter_number():-1).put("uploaded",c.getDate_upload()).put("scanlator",c.getScanlator()).put("memo",c.getMemo()==null?"{}":c.getMemo().toString());}
    private static SChapter chapter(JSONObject data)throws JSONException{SChapter c=SChapter.Companion.create();c.setUrl(data.getString("url"));c.setName(data.optString("name",""));c.setChapter_number((float)data.optDouble("number",-1));c.setScanlator(data.isNull("scanlator")?null:data.optString("scanlator",null));c.setMemo((JsonObject)json.parseToJsonElement(data.optString("memo","{}")));return c;}
}
