#!/usr/bin/env python3
"""Check plugin filter state restoration, then read all eight bundled source filters."""
from pathlib import Path
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]
BUILD = ROOT / "ios/build/filter-check"
BUILD.mkdir(parents=True, exist_ok=True)
RUNTIME = ROOT / "ios/build/runtime"
JAVA = RUNTIME / "jdk-27.jdk/Contents/Home/bin/java"
CP = os.pathsep.join(map(str, [BUILD, RUNTIME / "Engine.jar", RUNTIME / "compat.jar"]))
(BUILD / "NativeServices.java").write_text('''package yokai;
public class NativeServices {
 private static final java.util.Map<String,String> prefs=new java.util.HashMap<>();
 public static String readPreferences(String name){return prefs.getOrDefault(name,"{}");}
 public static void writePreferences(String name,String json){prefs.put(name,json);}
 public static void openWebView(String url,String source){}
}''')
(BUILD / "FilterCheck.java").write_text('''
import java.lang.reflect.*;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import com.sun.net.httpserver.HttpServer;
import eu.kanade.tachiyomi.source.model.Filter;
import org.json.*;
import yokai.Engine;
import com.squareup.zstd.okio.OkioZstd;
import okio.Buffer;
public class FilterCheck {
 static List<?> list(boolean changed){return Arrays.asList(
  new Filter.Text("作者",changed?"测试作者":""){},
  new Filter.CheckBox("完结",changed){},
  new Filter.TriState("冒险",changed?2:0){},
  new Filter.Select<String>("地区",new String[]{"全部","日本","中国"},changed?2:0){},
  new Filter.Sort("排序",new String[]{"日期","热度"},new Filter.Sort.Selection(changed?1:0,changed)){},
  new Filter.Group<Filter<?>>("类型",Arrays.asList(new Filter.CheckBox("奇幻",changed){}))
 );}
 static Object call(JSONObject q){JSONObject r=new JSONObject(Engine.execute(q.toString()));if(r.has("error"))throw new AssertionError(r.getString("error"));return r.get("value");}
 public static void main(String[] args)throws Exception {
  String text="图源响应内容 ".repeat(1000);Buffer compressed=new Buffer();
  okio.BufferedSink sink=okio.Okio.buffer(OkioZstd.zstdCompress(compressed));sink.writeUtf8(text);sink.close();
  String decoded=okio.Okio.buffer(OkioZstd.zstdDecompress(compressed)).readUtf8();
  if(!text.equals(decoded))throw new AssertionError("Pure JVM Zstd response changed");
  System.out.println("Zstd response decoded without native JNI libraries.");
  Method encode=Engine.class.getDeclaredMethod("filters",List.class);encode.setAccessible(true);
  Method apply=Engine.class.getDeclaredMethod("applyFilters",List.class,JSONArray.class);apply.setAccessible(true);
  JSONArray values=(JSONArray)encode.invoke(null,list(true));List<?> restored=list(false);
  apply.invoke(null,restored,values);
  if(!values.toString().equals(encode.invoke(null,restored).toString()))throw new AssertionError("Filter state round trip changed");
  values.getJSONObject(3).put("value",10);
  try{apply.invoke(null,list(false),values);throw new AssertionError("Outdated saved select accepted");}catch(InvocationTargetException expected){if(!(expected.getCause() instanceof java.io.IOException))throw expected;}
  System.out.println("Nested text/check/tri-state/select/sort filters restored; invalid saved selections rejected.");
  Path root=Path.of(args[0]);JSONArray bundled=new JSONArray(Files.readString(root.resolve("ios/Yokai/BundledExtensions.json"))), extensions=new JSONArray();
  for(int i=0;i<bundled.length();i++){JSONObject row=bundled.getJSONObject(i);extensions.put(new JSONObject().put("path",root.resolve("ios/build/runtime/Extensions/"+row.getString("file")).toString()).put("package",row.getString("package")).put("className",row.getString("className")));}
  JSONArray sources=(JSONArray)call(new JSONObject().put("action","load").put("extensions",extensions).put("dataPath",Path.of(args[1]).resolve("preferences").toString()));
  for(int i=0;i<sources.length();i++){
   JSONObject source=sources.getJSONObject(i);if(source.has("error"))throw new AssertionError(source.getString("error"));
   JSONArray filters=(JSONArray)call(new JSONObject().put("action","filters").put("source",source.getString("id")));
   JSONArray preferences=(JSONArray)call(new JSONObject().put("action","preferences").put("source",source.getString("id")));
   System.out.println(source.getString("name")+": "+filters.length()+" filters, "+preferences.length()+" preferences decoded");
  }
  // Loopback transfers must overlap; a factory reload must wait for both users
  // of the old class loader. No site account or external image URL is used.
  String sourceId=null;
  for(int i=0;i<sources.length();i++)if(sources.getJSONObject(i).getString("name").contains("热辣"))sourceId=sources.getJSONObject(i).getString("id");
  if(sourceId==null)throw new AssertionError("Missing concurrency-check source");
  HttpServer server=HttpServer.create(new java.net.InetSocketAddress("127.0.0.1",0),0);
  ExecutorService requests=Executors.newFixedThreadPool(3), replies=Executors.newFixedThreadPool(2);
  CountDownLatch arrived=new CountDownLatch(2), release=new CountDownLatch(1);
  List<String> cacheDirectives=Collections.synchronizedList(new ArrayList<>());
  server.setExecutor(replies);
  server.createContext("/image",exchange->{
   cacheDirectives.add(exchange.getRequestHeaders().getFirst("Cache-Control"));
   arrived.countDown();
   try{if(!release.await(10,TimeUnit.SECONDS))throw new java.io.IOException("Release timed out");}catch(InterruptedException e){throw new java.io.IOException(e);}
   byte[] image=Base64.getDecoder().decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+a3ioAAAAASUVORK5CYII=");
   exchange.sendResponseHeaders(200,image.length);exchange.getResponseBody().write(image);exchange.close();
  });
  server.start();
  try {
   String imageUrl="http://127.0.0.1:"+server.getAddress().getPort()+"/image", selected=sourceId;
   List<Future<?>> transfers=new ArrayList<>();
   for(int i=0;i<2;i++){final int index=i;transfers.add(requests.submit(()->call(new JSONObject().put("action","cover").put("source",selected).put("url",imageUrl).put("refresh",index==1).put("path",Path.of(args[1]).resolve("parallel-"+index+".png").toString()))));}
   if(!arrived.await(10,TimeUnit.SECONDS))throw new AssertionError("Runtime image requests were serialized");
   CountDownLatch reloading=new CountDownLatch(1);
   Future<?> reload=requests.submit(()->{reloading.countDown();return call(new JSONObject().put("action","load").put("extensions",extensions).put("dataPath",Path.of(args[1]).resolve("preferences").toString()));});
   if(!reloading.await(1,TimeUnit.SECONDS))throw new AssertionError("Reload did not start");
   try{reload.get(150,TimeUnit.MILLISECONDS);throw new AssertionError("Class loader changed during active requests");}catch(TimeoutException expected){}
   release.countDown();for(Future<?> transfer:transfers)transfer.get(10,TimeUnit.SECONDS);reload.get(10,TimeUnit.SECONDS);
   for(int i=0;i<2;i++)if(Files.size(Path.of(args[1]).resolve("parallel-"+i+".png"))<32)throw new AssertionError("Concurrent image was not saved");
   if(!cacheDirectives.contains("no-cache"))throw new AssertionError("Explicit cover refresh reused the HTTP cache");
   System.out.println("Two original-source image transfers overlapped; extension reload waited for both.");
  } finally {release.countDown();server.stop(0);requests.shutdownNow();replies.shutdownNow();}
  System.exit(0);
 }
}''')
sources = [str(path) for path in sorted((ROOT / "ios/Runtime/java").rglob("*.java")) if path.name != "NativeServices.java"]
subprocess.run([str(JAVA.with_name("javac")), "--release", "17", "-cp", CP, "-d", str(BUILD),
                str(BUILD / "NativeServices.java"), str(BUILD / "FilterCheck.java"), *sources], check=True)
subprocess.run([str(JAVA), "-cp", CP, "FilterCheck", str(ROOT), str(BUILD)], check=True)
