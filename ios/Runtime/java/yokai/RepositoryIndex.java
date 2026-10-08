package yokai;

import java.io.*;
import java.nio.file.*;
import java.util.zip.GZIPInputStream;
import org.json.*;

/** Uses ExtensionIndexDto's original protobuf field numbers. */
public final class RepositoryIndex {
    public static String read(String path) throws Exception {
        byte[] bytes;
        try(BufferedInputStream input=new BufferedInputStream(Files.newInputStream(Path.of(path)))) {
            input.mark(2);int first=input.read(),second=input.read();input.reset();
            InputStream stream=first==0x1f&&second==0x8b?new GZIPInputStream(input):input;
            bytes=stream.readNBytes(16*1024*1024+1);
            if(bytes.length>16*1024*1024)throw new IOException("扩展索引超过 16 MiB。");
        }
        AndroidBackup.Message root=new AndroidBackup.Message(bytes);
        JSONArray entries=new JSONArray();
        for(byte[] list:root.messages(101)) {
            for(byte[] raw:new AndroidBackup.Message(list).messages(1)) {
                AndroidBackup.Message extension=new AndroidBackup.Message(raw);
                JSONObject item=new JSONObject().put("name",extension.text(1,""))
                    .put("packageName",extension.text(2,""))
                    .put("versionCode",extension.integer(5,0)).put("versionName",extension.text(6,""));
                for(byte[] resource:extension.messages(3)) {
                    AndroidBackup.Message resources=new AndroidBackup.Message(resource);
                    item.put("resources",new JSONObject().put("apkUrl",resources.text(1,""))).put("icon",resources.text(2,""));
                }
                entries.put(item);
            }
        }
        if(entries.length()==0)throw new IOException("扩展索引中没有可安装的插件。");
        return entries.toString();
    }
}
