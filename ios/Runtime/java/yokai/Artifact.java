package yokai;

import java.io.*;
import java.nio.file.*;
import java.util.zip.*;
import javax.xml.parsers.*;
import org.w3c.dom.*;
import org.json.*;
import net.dongliu.apk.parser.ApkFile;
import com.googlecode.d2j.dex.Dex2jar;
import com.googlecode.d2j.reader.MultiDexFileReader;
import com.googlecode.dex2jar.tools.BaksmaliBaseDexExceptionHandler;

final class Artifact {
    static JSONObject inspect(String input,String output)throws Exception {
        String manifest;
        if(input.toLowerCase().endsWith(".apk")) {
            try(ApkFile apk=new ApkFile(input)){manifest=apk.getManifestXml();}
            BaksmaliBaseDexExceptionHandler handler=new BaksmaliBaseDexExceptionHandler();
            Dex2jar.from(MultiDexFileReader.open(Files.readAllBytes(Paths.get(input))))
                .withExceptionHandler(handler).reUseReg(false).topoLogicalSort().skipDebug(true)
                .optimizeSynchronized(false).printIR(false).noCode(false).skipExceptions(false)
                .dontSanitizeNames(true).computeFrames(true).to(Paths.get(output));
            if(handler.hasException())throw new IOException("Android 插件字节码转换失败，原有插件保留。");
        }else {
            try(ZipFile zip=new ZipFile(input)){ZipEntry entry=zip.getEntry("AndroidManifest.xml");if(entry==null)throw new IOException("JAR 中没有漫画插件信息。");manifest=new String(zip.getInputStream(entry).readAllBytes(),java.nio.charset.StandardCharsets.UTF_8);}
            if(!input.equals(output))Files.copy(Paths.get(input),Paths.get(output),StandardCopyOption.REPLACE_EXISTING);
        }
        DocumentBuilderFactory factory=DocumentBuilderFactory.newInstance();
        factory.setNamespaceAware(true);
        factory.setFeature("http://apache.org/xml/features/disallow-doctype-decl",true);
        factory.setFeature("http://xml.org/sax/features/external-general-entities",false);
        factory.setFeature("http://xml.org/sax/features/external-parameter-entities",false);
        Element root=factory.newDocumentBuilder().parse(new ByteArrayInputStream(manifest.getBytes(java.nio.charset.StandardCharsets.UTF_8))).getDocumentElement();
        String pkg=root.getAttribute("package"),className="";
        NodeList metadata=root.getElementsByTagName("meta-data");String android="http://schemas.android.com/apk/res/android";
        for(int i=0;i<metadata.getLength();i++){Element item=(Element)metadata.item(i);if(item.getAttributeNS(android,"name").equals("tachiyomi.extension.class"))className=item.getAttributeNS(android,"value");}
        if(className.startsWith("."))className=pkg+className;
        if(!pkg.matches("[A-Za-z0-9_.]+")||className.isEmpty())throw new IOException("无效的漫画插件信息。");
        return new JSONObject().put("package",pkg).put("className",className).put("version",root.getAttributeNS(android,"versionName")).put("versionCode",root.getAttributeNS(android,"versionCode"));
    }
}
