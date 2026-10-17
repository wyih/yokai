package yokai;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.zip.GZIPInputStream;
import java.util.zip.GZIPOutputStream;
import org.json.*;

/** Field numbers come from the original data/backup/models Kotlin schema. */
public final class AndroidBackup {
    private static final int LIMIT = 64 * 1024 * 1024;
    private record Field(int number, int wire, long integer, byte[] bytes, byte[] raw) {}
    static final class Message {
        final List<Field> fields = new ArrayList<>();
        Message(byte[] data) throws IOException {
            ByteArrayInputStream in = new ByteArrayInputStream(data);
            while (in.available() > 0) {
                int start = data.length-in.available();
                long tag = varint(in); int wire = (int)(tag & 7), number = (int)(tag >>> 3);
                long integer=0; byte[] bytes=null;
                if (wire == 0) integer=varint(in);
                else if (wire == 2) {
                    long length = varint(in);
                    if (length < 0 || length > in.available()) throw new IOException("备份字段长度无效。");
                    bytes=in.readNBytes((int)length);
                } else if (wire == 1 || wire == 5) {
                    int length=wire == 1 ? 8 : 4; bytes=in.readNBytes(length);
                    if(bytes.length!=length)throw new IOException("备份字段不完整。");
                } else throw new IOException("备份包含不支持的字段格式。");
                fields.add(new Field(number,wire,integer,bytes,Arrays.copyOfRange(data,start,data.length-in.available())));
            }
        }
        long integer(int number,long fallback){for(Field f:fields)if(f.number==number&&f.wire==0)return f.integer;return fallback;}
        String text(int number,String fallback){for(Field f:fields)if(f.number==number&&f.wire==2)return new String(f.bytes,StandardCharsets.UTF_8);return fallback;}
        List<byte[]> messages(int number){List<byte[]> result=new ArrayList<>();for(Field f:fields)if(f.number==number&&f.wire==2)result.add(f.bytes);return result;}
        double decimal(int number,double fallback){for(Field f:fields)if(f.number==number&&f.wire==5){int bits=0;for(int i=0;i<4;i++)bits|=(f.bytes[i]&255)<<(i*8);float value=Float.intBitsToFloat(bits);return Float.isFinite(value)?value:fallback;}return fallback;}
        List<Long> integers(int number)throws IOException {
            List<Long> result=new ArrayList<>();
            for(Field f:fields)if(f.number==number){if(f.wire==0)result.add(f.integer);else if(f.wire==2){ByteArrayInputStream in=new ByteArrayInputStream(f.bytes);while(in.available()>0)result.add(varint(in));}}
            return result;
        }
        byte[] excluding(Set<Integer> numbers)throws IOException {ByteArrayOutputStream out=new ByteArrayOutputStream();for(Field f:fields)if(!numbers.contains(f.number))out.write(f.raw);return out.toByteArray();}
    }
    private static long varint(InputStream in)throws IOException {
        long value=0;
        for(int shift=0;shift<64;shift+=7){int b=in.read();if(b<0||(shift==63&&b>1))throw new IOException("备份整数无效。");value|=(long)(b&127)<<shift;if((b&128)==0)return value;}
        throw new IOException("备份整数无效。");
    }
    private static final class Writer extends ByteArrayOutputStream {
        void variable(long value){while((value&~127L)!=0){write((int)(value&127)|128);value>>>=7;}write((int)value);}
        Writer integer(int number,long value){variable((long)number<<3);variable(value);return this;}
        Writer bytes(int number,byte[] value){variable(((long)number<<3)|2);variable(value.length);writeBytes(value);return this;}
        Writer text(int number,String value){return bytes(number,value.getBytes(StandardCharsets.UTF_8));}
        Writer decimal(int number,double value){variable(((long)number<<3)|5);int bits=Float.floatToIntBits((float)value);for(int i=0;i<4;i++)write((bits>>>(8*i))&255);return this;}
    }
    private static Message original(JSONObject item)throws IOException {
        try{return new Message(Base64.getDecoder().decode(item.optString("androidData","")));}
        catch(IllegalArgumentException e){throw new IOException("备份保留字段损坏。",e);}
    }
    private static String base64(byte[] data){return Base64.getEncoder().encodeToString(data);}

    private static JSONArray preferences(List<byte[]> records)throws Exception {
        JSONArray result=new JSONArray();
        for(byte[] raw:records){Message row=new Message(raw);List<byte[]> values=row.messages(2);if(values.isEmpty())continue;
            Message polymorphic=new Message(values.get(0));String type=polymorphic.text(1,"");List<byte[]> payloads=polymorphic.messages(2);if(payloads.isEmpty())continue;
            Message payload=new Message(payloads.get(0));Object value;String kind;
            if(type.endsWith("StringSetPreferenceValue")){JSONArray set=new JSONArray();for(byte[] v:payload.messages(1))set.put(new String(v,StandardCharsets.UTF_8));value=set;kind="set";}
            else if(type.endsWith("StringPreferenceValue")){value=payload.text(1,"");kind="string";}
            else if(type.endsWith("BooleanPreferenceValue")){value=payload.integer(1,0)!=0;kind="boolean";}
            else if(type.endsWith("FloatPreferenceValue")){value=payload.decimal(1,0);kind="float";}
            else if(type.endsWith("LongPreferenceValue")){value=payload.integer(1,0);kind="long";}
            else if(type.endsWith("IntPreferenceValue")){value=(int)payload.integer(1,0);kind="int";}
            else continue;
            result.put(new JSONObject().put("key",row.text(1,"")).put("type",kind).put("value",value));
        }return result;
    }

    private static byte[] preference(JSONObject item)throws Exception {
        String kind=item.getString("type"),name;Writer payload=new Writer();Object value=item.get("value");
        switch(kind){
            case "set": name="StringSetPreferenceValue";JSONArray set=(JSONArray)value;for(int i=0;i<set.length();i++)payload.text(1,set.getString(i));break;
            case "string": name="StringPreferenceValue";payload.text(1,(String)value);break;
            case "boolean": name="BooleanPreferenceValue";payload.integer(1,(Boolean)value?1:0);break;
            case "float": name="FloatPreferenceValue";payload.decimal(1,((Number)value).doubleValue());break;
            case "long": name="LongPreferenceValue";payload.integer(1,((Number)value).longValue());break;
            default: name="IntPreferenceValue";payload.integer(1,((Number)value).intValue());break;
        }
        Writer polymorphic=new Writer().text(1,"eu.kanade.tachiyomi.data.backup.models."+name).bytes(2,payload.toByteArray());
        return new Writer().text(1,item.getString("key")).bytes(2,polymorphic.toByteArray()).toByteArray();
    }

    public static JSONObject read(String path)throws Exception {
        byte[] data;
        try(InputStream input=new GZIPInputStream(Files.newInputStream(Path.of(path)))){
            data=input.readNBytes(LIMIT+1);if(data.length>LIMIT)throw new IOException("备份解压后超过 64 MiB。");
        }
        Message root=new Message(data);Map<Long,String> categoryNames=new HashMap<>();JSONArray categoryList=new JSONArray();
        for(byte[] raw:root.messages(2)){Message m=new Message(raw);String name=m.text(1,"");long order=m.integer(2,0);categoryNames.put(order,name);categoryList.put(new JSONObject().put("name",name).put("order",order));}
        JSONArray manga=new JSONArray();
        for(byte[] raw:root.messages(1)){
            Message m=new Message(raw);Map<String,Long> history=new HashMap<>();
            for(byte[] h:m.messages(104)){Message row=new Message(h);history.merge(row.text(1,""),row.integer(2,0),Math::max);}
            for(byte[] h:m.messages(102)){Message row=new Message(h);history.merge(row.text(0,""),row.integer(1,0),Math::max);}
            JSONArray chapters=new JSONArray(),categories=new JSONArray(),genres=new JSONArray();
            for(long order:m.integers(17)){String name=categoryNames.get(order);if(name!=null&&!name.isEmpty())categories.put(name);}
            for(byte[] c:m.messages(16)){
                Message row=new Message(c);String url=row.text(1,"");if(url.isEmpty())continue;
                chapters.put(new JSONObject().put("url",url).put("name",row.text(2,"章节")).put("scanlator",row.text(3,""))
                    .put("read",row.integer(4,0)!=0).put("bookmark",row.integer(5,0)!=0)
                    .put("lastPage",Math.max(0,row.integer(6,0))).put("pagesLeft",Math.max(0,row.integer(800,0)))
                    .put("number",row.decimal(9,-1)).put("uploaded",row.integer(8,0)).put("sourceOrder",row.integer(10,0))
                    .put("readAt",history.getOrDefault(url,0L)).put("memo",row.text(13,"{}")));
            }
            for(byte[] g:m.messages(m.messages(805).isEmpty()?7:805))genres.put(new String(g,StandardCharsets.UTF_8));
            String url=m.text(2,"");if(url.isEmpty())throw new IOException("备份漫画缺少地址。");
            manga.put(new JSONObject().put("source",Long.toString(m.integer(1,0))).put("url",url)
                .put("title",m.text(800,m.text(3,"漫画"))).put("thumbnail",m.text(9,""))
                .put("artist",m.text(801,m.text(4,""))).put("author",m.text(802,m.text(5,""))).put("description",m.text(804,m.text(6,"")))
                .put("genre",genres).put("status",m.integer(602,0)!=0?m.integer(602,0):m.integer(8,0)).put("favorite",m.integer(100,1)!=0)
                .put("viewerFlags",m.integer(103,m.integer(14,0)))
                .put("addedAt",m.integer(13,0)).put("memo",m.text(112,"{}"))
                .put("chapters",chapters).put("categories",categories).put("androidData",base64(raw)));
        }
        if(manga.length()==0&&categoryList.length()==0&&root.messages(104).isEmpty()&&root.messages(105).isEmpty())throw new IOException("备份中没有可恢复的数据。");
        // App/source preferences are kept separately on-device; never placed in WebDAV shelf metadata.
        JSONArray sourcePreferences=new JSONArray();
        for(byte[] raw:root.messages(105)){Message row=new Message(raw);sourcePreferences.put(new JSONObject().put("name",row.text(1,"")).put("preferences",preferences(row.messages(2))));}
        return new JSONObject().put("manga",manga).put("categoryList",categoryList)
            .put("appPreferences",preferences(root.messages(104))).put("sourcePreferences",sourcePreferences)
            .put("extraFields",base64(root.excluding(Set.of(1))));
    }

    public static boolean write(JSONObject request)throws Exception {
        Writer root=new Writer();
        String extras=request.optString("extraFields","");
        Set<Integer> omitted=new HashSet<>(Set.of(1,2,101));
        if(!request.optBoolean("includeAppPreferences",true))omitted.add(104);
        if(!request.optBoolean("includeSourcePreferences",true))omitted.add(105);
        Message originalRoot=new Message(extras.isEmpty()?new byte[0]:Base64.getDecoder().decode(extras));
        JSONArray sourcePreferences=request.optJSONArray("sourcePreferences"),appPreferences=request.optJSONArray("appPreferences");
        if(sourcePreferences!=null)omitted.add(105);
        if(appPreferences!=null)omitted.add(104);
        root.writeBytes(originalRoot.excluding(omitted));
        if(request.optBoolean("includeSourcePreferences",true)&&sourcePreferences!=null){
            Set<String> replaced=new HashSet<>();for(int i=0;i<sourcePreferences.length();i++)replaced.add(sourcePreferences.getJSONObject(i).getString("name"));
            for(byte[] raw:originalRoot.messages(105))if(!replaced.contains(new Message(raw).text(1,"")))root.bytes(105,raw);
            for(int i=0;i<sourcePreferences.length();i++){JSONObject item=sourcePreferences.getJSONObject(i);Writer row=new Writer().text(1,item.getString("name"));JSONArray prefs=item.getJSONArray("preferences");for(int j=0;j<prefs.length();j++)row.bytes(2,preference(prefs.getJSONObject(j)));root.bytes(105,row.toByteArray());}
        }
        if(request.optBoolean("includeAppPreferences",true)&&appPreferences!=null){
            Set<String> replaced=new HashSet<>();for(int i=0;i<appPreferences.length();i++)replaced.add(appPreferences.getJSONObject(i).getString("key"));
            for(byte[] raw:originalRoot.messages(104))if(!replaced.contains(new Message(raw).text(1,"")))root.bytes(104,raw);
            for(int i=0;i<appPreferences.length();i++)root.bytes(104,preference(appPreferences.getJSONObject(i)));
        }
        JSONArray names=request.optJSONArray("categoryNames");if(names==null)names=new JSONArray();
        Map<String,Integer> categories=new LinkedHashMap<>();
        Map<String,Message> previousCategories=new HashMap<>();
        for(byte[] raw:originalRoot.messages(2)){Message category=new Message(raw);previousCategories.put(category.text(1,""),category);}
        for(int i=0;i<names.length();i++) {
            String name=names.getString(i);if(categories.containsKey(name))continue;
            int order=categories.size();categories.put(name,order);
            Writer category=new Writer();
            if(previousCategories.containsKey(name))category.writeBytes(previousCategories.get(name).excluding(Set.of(1,2)));
            root.bytes(2,category.text(1,name).integer(2,order).toByteArray());
        }
        JSONArray books=request.getJSONArray("manga");
        for(int i=0;i<books.length();i++) {
            JSONObject b=books.getJSONObject(i);Message old=original(b);Writer m=new Writer();
            m.writeBytes(old.excluding(Set.of(1,2,3,4,5,6,7,8,9,13,14,16,17,100,102,103,104,112,800)));
            String title=b.getString("title"),baseTitle=old.text(3,title);
            if(!title.equals(baseTitle)||!old.messages(800).isEmpty())m.text(800,title);
            m.integer(1,Long.parseLong(b.getString("source"))).text(2,b.getString("url")).text(3,baseTitle)
                .integer(13,b.optLong("addedAt",old.integer(13,0))).integer(100,b.optBoolean("favorite",true)?1:0)
                .integer(14,b.optInt("viewerFlags",(int)old.integer(103,old.integer(14,0)))&7)
                .integer(103,b.optInt("viewerFlags",(int)old.integer(103,old.integer(14,0))));
            m.text(4,baseText(b,"artist",old,4,801)).text(5,baseText(b,"author",old,5,802))
                .text(6,baseText(b,"description",old,6,804)).integer(8,old.integer(602,0)!=0?old.integer(8,0):b.optInt("status",(int)old.integer(8,0)))
                .text(9,b.optString("thumbnail",old.text(9,""))).text(112,b.optString("memo",old.text(112,"{}")));
            JSONArray genres=b.optJSONArray("genre");if(genres!=null&&old.messages(805).isEmpty()){for(int j=0;j<genres.length();j++)m.text(7,genres.getString(j));}
            else for(byte[] g:old.messages(7))m.bytes(7,g);
            JSONArray cats=b.optJSONArray("categories");if(cats!=null)for(int j=0;j<cats.length();j++){Integer order=categories.get(cats.getString(j));if(order!=null)m.integer(17,order);}
            Map<String,byte[]> previous=new HashMap<>();for(byte[] raw:old.messages(16)){Message chapter=new Message(raw);previous.put(chapter.text(1,""),raw);}
            Map<String,byte[]> oldHistory=new HashMap<>();for(byte[] raw:old.messages(104)){Message row=new Message(raw);oldHistory.put(row.text(1,""),raw);}
            JSONArray chapters=b.optJSONArray("chapters");if(chapters==null)chapters=new JSONArray();
            for(int j=0;j<chapters.length();j++) {
                JSONObject c=chapters.getJSONObject(j);String url=c.getString("url");Message prior=new Message(previous.getOrDefault(url,new byte[0]));Writer chapter=new Writer();
                Set<Integer> chapterFields=new HashSet<>(Set.of(1,2,4,5,6,8,9,10,13,800));
                if(c.has("scanlator"))chapterFields.add(3);
                chapter.writeBytes(prior.excluding(chapterFields));
                if(c.has("scanlator")&&!c.optString("scanlator","").isEmpty())chapter.text(3,c.getString("scanlator"));
                chapter.text(1,url).text(2,c.getString("name")).integer(4,c.optBoolean("read",false)?1:0)
                    .integer(5,c.optBoolean("bookmark",false)?1:0).integer(6,c.optInt("lastPage",0)).integer(800,c.optInt("pagesLeft",0))
                    .integer(8,c.optLong("uploaded",prior.integer(8,0))).decimal(9,c.optDouble("number",prior.decimal(9,-1)))
                    .integer(10,c.optInt("sourceOrder",(int)prior.integer(10,j))).text(13,c.optString("memo",prior.text(13,"{}")));
                m.bytes(16,chapter.toByteArray());
                long readAt=c.optLong("readAt",0);if(readAt>0){Writer history=new Writer();history.writeBytes(new Message(oldHistory.getOrDefault(url,new byte[0])).excluding(Set.of(1,2)));history.text(1,url).integer(2,readAt);m.bytes(104,history.toByteArray());}
            }
            root.bytes(1,m.toByteArray());
        }
        JSONArray sources=request.optJSONArray("sources");Set<Long> sourceIDs=new HashSet<>();
        if(sources!=null)for(int i=0;i<sources.length();i++){JSONObject source=sources.getJSONObject(i);long id=Long.parseLong(source.getString("id"));sourceIDs.add(id);root.bytes(101,new Writer().text(1,source.getString("name")).integer(2,id).toByteArray());}
        for(byte[] raw:originalRoot.messages(101))if(!sourceIDs.contains(new Message(raw).integer(2,0)))root.bytes(101,raw);
        if(root.size()>LIMIT)throw new IOException("备份超过 64 MiB。");
        Path output=Path.of(request.getString("path"));Files.createDirectories(output.getParent());
        try(OutputStream out=new GZIPOutputStream(Files.newOutputStream(output))){root.writeTo(out);}
        return true;
    }

    private static String baseText(JSONObject book,String key,Message old,int base,int custom) {
        String value=book.optString(key,old.text(base,""));
        return !old.messages(custom).isEmpty()&&value.equals(old.text(custom,""))?old.text(base,""):value;
    }
}
