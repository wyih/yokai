package yokai;

import java.io.*;
import java.nio.file.*;
import java.util.zip.*;
import javax.xml.parsers.*;
import org.w3c.dom.*;
import org.json.*;
import net.dongliu.apk.parser.ApkFile;
import com.googlecode.d2j.dex.Dex2jar;
import com.googlecode.d2j.Method;
import com.googlecode.d2j.node.*;
import com.googlecode.d2j.node.insn.*;
import com.googlecode.d2j.reader.BaseDexFileReader;
import com.googlecode.d2j.reader.DexFileReader;
import com.googlecode.d2j.reader.MultiDexFileReader;
import com.googlecode.d2j.reader.Op;
import com.googlecode.d2j.dex.writer.DexFileWriter;
import com.googlecode.dex2jar.tools.BaksmaliBaseDexExceptionHandler;
import static com.googlecode.d2j.DexConstants.ACC_PUBLIC;
import static com.googlecode.d2j.DexConstants.ACC_CONSTRUCTOR;

public final class Artifact {
    public static void convert(String input,String output)throws Exception {
        BaseDexFileReader reader=MultiDexFileReader.open(Files.readAllBytes(Paths.get(input)));
        DexFileNode dex=new DexFileNode();reader.accept(dex,DexFileReader.SKIP_DEBUG);
        java.util.Map<String,DexClassNode> classes=new java.util.HashMap<>();
        for(DexClassNode cls:dex.clzs)classes.put(cls.className,cls);
        java.util.Set<DexClassNode> constructors=new java.util.HashSet<>();
        for(DexClassNode cls:dex.clzs)for(DexMethodNode method:cls.methods==null?java.util.List.<DexMethodNode>of():cls.methods) {
            if(method.codeNode==null)continue;
            var stmts=method.codeNode.stmts;
            for(int i=1;i<stmts.size();i++) {
                if(!(stmts.get(i-1) instanceof TypeStmtNode allocation)||allocation.op!=Op.NEW_INSTANCE||
                   !(stmts.get(i) instanceof MethodStmtNode call)||call.op!=Op.INVOKE_DIRECT||
                   !call.method.getName().equals("<init>")||call.args.length!=1||call.args[0]!=allocation.a||
                   !call.method.getOwner().equals("Ljava/lang/Object;"))continue;
                DexClassNode target=classes.get(allocation.type);
                if(target==null||!"Ljava/lang/Object;".equals(target.superClass)||
                   target.methods!=null&&target.methods.stream().anyMatch(m->m.method.getName().equals("<init>")&&m.method.getParameterTypes().length==0))continue;
                // R8 can initialize a new subclass directly through Object's constructor.
                constructors.add(target);
                stmts.set(i,new MethodStmtNode(call.op,call.args,new Method(allocation.type,"<init>",new String[0],"V")));
            }
        }
        for(DexClassNode cls:constructors) {
            var method=cls.visitMethod(ACC_PUBLIC|ACC_CONSTRUCTOR,new Method(cls.className,"<init>",new String[0],"V"));
            var code=method.visitCode();code.visitRegister(1);
            code.visitMethodStmt(Op.INVOKE_DIRECT,new int[]{0},new Method("Ljava/lang/Object;","<init>",new String[0],"V"));
            code.visitStmt0R(Op.RETURN_VOID);code.visitEnd();method.visitEnd();
        }
        if(!constructors.isEmpty()) {
            DexFileWriter writer=new DexFileWriter();dex.accept(writer);
            reader=MultiDexFileReader.open(writer.toByteArray());
        }
        BaksmaliBaseDexExceptionHandler handler=new BaksmaliBaseDexExceptionHandler();
        Dex2jar.from(reader).withExceptionHandler(handler).reUseReg(false).topoLogicalSort().skipDebug(true)
            .optimizeSynchronized(false).printIR(false).noCode(false).skipExceptions(false)
            .dontSanitizeNames(true).computeFrames(true).to(Paths.get(output));
        if(handler.hasException())throw new IOException("Android 插件字节码转换失败，原有插件保留。");
    }

    static JSONObject inspect(String input,String output)throws Exception {
        String manifest;
        if(input.toLowerCase().endsWith(".apk")) {
            try(ApkFile apk=new ApkFile(input)){manifest=apk.getManifestXml();}
            convert(input,output);
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
