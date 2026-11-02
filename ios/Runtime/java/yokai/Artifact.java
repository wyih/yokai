package yokai;

import java.io.*;
import java.nio.file.*;
import java.util.zip.*;
import javax.xml.parsers.*;
import org.w3c.dom.*;
import org.json.*;
import org.objectweb.asm.*;
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
        java.util.Map<Method,DexClassNode> constructors=new java.util.LinkedHashMap<>();
        for(DexClassNode cls:dex.clzs)for(DexMethodNode method:cls.methods==null?java.util.List.<DexMethodNode>of():cls.methods) {
            if(method.codeNode==null)continue;
            var stmts=method.codeNode.stmts;
            for(int i=0;i<stmts.size();i++) {
                if(!(stmts.get(i) instanceof TypeStmtNode allocation)||allocation.op!=Op.NEW_INSTANCE)continue;
                for(int j=i+1;j<stmts.size();j++) {
                    var next=stmts.get(j);
                    if(next instanceof ConstStmtNode constant&&constant.a!=allocation.a)continue;
                    if(next instanceof MethodStmtNode call&&(call.op==Op.INVOKE_DIRECT||call.op==Op.INVOKE_DIRECT_RANGE)&&
                       call.method.getName().equals("<init>")&&call.args.length>0&&call.args[0]==allocation.a&&
                       !call.method.getOwner().equals(allocation.type)&&
                       restoreConstructors(allocation.type,call.method,classes,constructors)) {
                        // R8 can inline forwarding constructors, including enums and superclass chains.
                        stmts.set(j,new MethodStmtNode(call.op,call.args,new Method(allocation.type,"<init>",call.method.getParameterTypes(),"V")));
                    }
                    break;
                }
            }
        }
        for(var entry:constructors.entrySet()) {
            Method signature=entry.getKey();DexClassNode cls=entry.getValue();
            var method=cls.visitMethod(ACC_PUBLIC|ACC_CONSTRUCTOR,signature);
            int registers=1;for(String type:signature.getParameterTypes())registers+=type.equals("J")||type.equals("D")?2:1;
            int[] args=new int[registers];for(int i=0;i<registers;i++)args[i]=i;
            var code=method.visitCode();code.visitRegister(registers);
            code.visitMethodStmt(Op.INVOKE_DIRECT_RANGE,args,new Method(cls.superClass,"<init>",signature.getParameterTypes(),"V"));
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
        java.util.Map<String,ClassReader> types=new java.util.HashMap<>();
        try(ZipFile jar=new ZipFile(output)) {
            for(ZipEntry entry:java.util.Collections.list(jar.entries())) {
                if(!entry.getName().endsWith(".class"))continue;
                ClassReader type=new ClassReader(jar.getInputStream(entry).readAllBytes());types.put(type.getClassName(),type);
            }
        }
        try(FileSystem jar=FileSystems.newFileSystem(Paths.get(output))) {
            for(ClassReader type:new java.util.ArrayList<>(types.values())) {
                ClassWriter writer=new FrameWriter(types);
                type.accept(new ClassVisitor(Opcodes.ASM9,writer) {
                    public void visit(int version,int access,String name,String signature,String parent,String[] interfaces) {
                        // Version 50 lets desktop Java silently retry the legacy verifier; iOS cannot.
                        super.visit(Math.max(version,Opcodes.V1_8),access,name,signature,parent,interfaces);
                    }
                },ClassReader.SKIP_FRAMES);
                Files.write(jar.getPath("/"+type.getClassName()+".class"),writer.toByteArray());
            }
        }
        if(input.toLowerCase(java.util.Locale.ROOT).endsWith(".apk")) {
            try(ZipFile apk=new ZipFile(input);FileSystem jar=FileSystems.newFileSystem(Paths.get(output))) {
                for(ZipEntry entry:java.util.Collections.list(apk.entries())) {
                    if(entry.isDirectory()||!entry.getName().startsWith("assets/"))continue;
                    Path target=jar.getPath("/"+entry.getName()).normalize();
                    if(!target.startsWith("/assets/"))throw new IOException("无效的插件资源路径。");
                    Files.createDirectories(target.getParent());
                    try(InputStream resource=apk.getInputStream(entry)){Files.copy(resource,target,StandardCopyOption.REPLACE_EXISTING);}
                }
            }
        }
    }

    private static final class FrameWriter extends ClassWriter {
        private final java.util.Map<String,ClassReader> types;
        FrameWriter(java.util.Map<String,ClassReader> types){super(COMPUTE_FRAMES);this.types=types;}
        private ClassReader type(String name) {
            return types.computeIfAbsent(name,key->{
                try(InputStream input=Artifact.class.getClassLoader().getResourceAsStream(key+".class")) {
                    if(input==null)throw new IOException("缺少插件依赖："+key);
                    return new ClassReader(input);
                }catch(IOException error){throw new java.io.UncheckedIOException(error);}
            });
        }
        private boolean accepts(String parent,String child) {
            if(parent.equals(child)||parent.equals("java/lang/Object"))return true;
            ClassReader type=type(child);
            if(type.getSuperName()!=null&&accepts(parent,type.getSuperName()))return true;
            for(String face:type.getInterfaces())if(accepts(parent,face))return true;
            return false;
        }
        protected String getCommonSuperClass(String first,String second) {
            if(accepts(first,second))return first;
            if(accepts(second,first))return second;
            if((type(first).getAccess()&Opcodes.ACC_INTERFACE)!=0||(type(second).getAccess()&Opcodes.ACC_INTERFACE)!=0)return "java/lang/Object";
            do {first=type(first).getSuperName();}while(!accepts(first,second));
            return first;
        }
    }

    private static boolean restoreConstructors(String type,Method original,java.util.Map<String,DexClassNode> classes,java.util.Map<Method,DexClassNode> restored) {
        if(type.equals(original.getOwner()))return true;
        DexClassNode cls=classes.get(type);if(cls==null)return false;
        Method signature=new Method(type,"<init>",original.getParameterTypes(),"V");
        if(restored.containsKey(signature))return true;
        if(cls.methods!=null&&cls.methods.stream().anyMatch(m->m.method.equals(signature)))return false;
        if(!restoreConstructors(cls.superClass,original,classes,restored))return false;
        restored.put(signature,cls);return true;
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
