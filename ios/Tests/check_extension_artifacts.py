#!/usr/bin/env python3
"""Convert and load APK/JAR plugins using only the modules bundled on iOS."""
from pathlib import Path
import os
import subprocess
import struct
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / 'ios/build/runtime'
BUILD = ROOT / 'ios/build/extension-artifact-check'
BUILD.mkdir(parents=True, exist_ok=True)
JAVA = RUNTIME / 'jdk-27.jdk/Contents/Home/bin/java'
CP = os.pathsep.join(map(str, [BUILD, RUNTIME / 'Engine.jar', RUNTIME / 'compat.jar']))

writer = Path(os.environ.get('YOKAI_JDK23', '/opt/homebrew/Cellar/openjdk/23.0.1/libexec/openjdk.jdk/Contents/Home'))
if not writer.exists():
    writer = RUNTIME / 'jdk-23.0.2.jdk/Contents/Home'
image = subprocess.check_output([str(writer / 'bin/jimage'), 'list', str(RUNTIME / 'lib/lib/modules')], text=True)
assert 'Module: jdk.zipfs' in image, 'The mobile runtime is missing the APK converter filesystem provider'
with zipfile.ZipFile(RUNTIME / 'compat.jar') as archive:
    for name in archive.namelist():
        if name.endswith('.class'):
            assert struct.unpack('>H', archive.read(name)[6:8])[0] >= 50, name + ' needs the unavailable legacy verifier'

(BUILD / 'NativeServices.java').write_text('''package yokai;
public class NativeServices {
 public static String readPreferences(String name){return "{}";}
 public static void writePreferences(String name,String json){}
 public static void openWebView(String url,String source){}
}''')
(BUILD / 'ArtifactCheck.java').write_text('''
import java.nio.file.*;
import org.json.*;
import yokai.Engine;
import yokai.Artifact;
import com.googlecode.d2j.*;
import com.googlecode.d2j.reader.Op;
import com.googlecode.d2j.dex.writer.DexFileWriter;
public class ArtifactCheck {
 static Object call(JSONObject request){
  JSONObject response=new JSONObject(Engine.execute(request.toString()));
  if(response.has("error"))throw new AssertionError(response.getString("error"));
  return response.get("value");
 }
 public static void main(String[] args)throws Exception {
  Path runtime=Path.of(args[0]), output=Path.of(args[1]);
  DexFileWriter dex=new DexFileWriter();
  var base=dex.visit(DexConstants.ACC_PUBLIC,"Lfixture/Base;","Ljava/lang/Object;",null);
  var value=base.visitMethod(DexConstants.ACC_PUBLIC,new Method("Lfixture/Base;","value",new String[0],"I"));
  var body=value.visitCode();body.visitRegister(2);body.visitConstStmt(Op.CONST_4,0,7);body.visitStmt1R(Op.RETURN,0);body.visitEnd();value.visitEnd();base.visitEnd();
  dex.visit(DexConstants.ACC_PUBLIC,"Lfixture/Marker;","Lfixture/Base;",null).visitEnd();
  dex.visit(DexConstants.ACC_PUBLIC,"Lfixture/Other;","Lfixture/Base;",null).visitEnd();
  dex.visit(DexConstants.ACC_PUBLIC|DexConstants.ACC_ENUM,"Lfixture/Kind;","Ljava/lang/Enum;",null).visitEnd();
  dex.visit(DexConstants.ACC_PUBLIC,"Lfixture/Choice;","Leu/kanade/tachiyomi/source/model/Filter$Select;",null).visitEnd();
  var factory=dex.visit(DexConstants.ACC_PUBLIC,"Lfixture/Factory;","Ljava/lang/Object;",null);
  var method=factory.visitMethod(DexConstants.ACC_PUBLIC|DexConstants.ACC_STATIC,new Method("Lfixture/Factory;","create",new String[0],"Lfixture/Marker;"));
  var code=method.visitCode();code.visitRegister(1);
  code.visitTypeStmt(Op.NEW_INSTANCE,0,0,"Lfixture/Marker;");
  DexLabel line=new DexLabel();code.visitLabel(line);code.visitDebug().visitLineNumber(1,line);
  code.visitMethodStmt(Op.INVOKE_DIRECT,new int[]{0},new Method("Ljava/lang/Object;","<init>",new String[0],"V"));
  code.visitStmt1R(Op.RETURN_OBJECT,0);code.visitEnd();method.visitEnd();
  method=factory.visitMethod(DexConstants.ACC_PUBLIC|DexConstants.ACC_STATIC,new Method("Lfixture/Factory;","kind",new String[0],"Lfixture/Kind;"));
  code=method.visitCode();code.visitRegister(3);
  code.visitTypeStmt(Op.NEW_INSTANCE,0,0,"Lfixture/Kind;");
  code.visitConstStmt(Op.CONST_STRING,1,"DOCUMENT");code.visitConstStmt(Op.CONST_4,2,0);
  code.visitMethodStmt(Op.INVOKE_DIRECT,new int[]{0,1,2},new Method("Ljava/lang/Enum;","<init>",new String[]{"Ljava/lang/String;","I"},"V"));
  code.visitStmt1R(Op.RETURN_OBJECT,0);code.visitEnd();method.visitEnd();
  method=factory.visitMethod(DexConstants.ACC_PUBLIC|DexConstants.ACC_STATIC,new Method("Lfixture/Factory;","choose",new String[]{"I"},"I"));
  code=method.visitCode();code.visitRegister(3);DexLabel other=new DexLabel(),merge=new DexLabel();
  code.visitJumpStmt(Op.IF_EQZ,2,0,other);
  code.visitTypeStmt(Op.NEW_INSTANCE,0,0,"Lfixture/Marker;");code.visitMethodStmt(Op.INVOKE_DIRECT,new int[]{0},new Method("Ljava/lang/Object;","<init>",new String[0],"V"));
  code.visitJumpStmt(Op.GOTO,0,0,merge);code.visitLabel(other);
  code.visitTypeStmt(Op.NEW_INSTANCE,0,0,"Lfixture/Other;");code.visitMethodStmt(Op.INVOKE_DIRECT,new int[]{0},new Method("Ljava/lang/Object;","<init>",new String[0],"V"));
  code.visitLabel(merge);code.visitMethodStmt(Op.INVOKE_VIRTUAL,new int[]{0},new Method("Lfixture/Base;","value",new String[0],"I"));
  code.visitStmt1R(Op.MOVE_RESULT,1);code.visitStmt1R(Op.RETURN,1);code.visitEnd();method.visitEnd();
  method=factory.visitMethod(DexConstants.ACC_PUBLIC|DexConstants.ACC_STATIC,new Method("Lfixture/Factory;","filter",new String[0],"Lfixture/Choice;"));
  code=method.visitCode();code.visitRegister(5);
  code.visitTypeStmt(Op.NEW_INSTANCE,0,0,"Lfixture/Choice;");code.visitStmt2R(Op.MOVE_OBJECT,4,0);
  code.visitConstStmt(Op.CONST_STRING,0,"全部");
  code.visitMethodStmt(Op.INVOKE_STATIC,new int[]{0},new Method("Ljava/util/Collections;","singletonList",new String[]{"Ljava/lang/Object;"},"Ljava/util/List;"));
  code.visitStmt1R(Op.MOVE_RESULT_OBJECT,2);
  code.visitMethodStmt(Op.INVOKE_INTERFACE,new int[]{2},new Method("Ljava/util/List;","toArray",new String[0],"[Ljava/lang/Object;"));
  code.visitStmt1R(Op.MOVE_RESULT_OBJECT,2);code.visitConstStmt(Op.CONST_STRING,1,"类型");code.visitConstStmt(Op.CONST_4,3,3);
  DexLabel loop=new DexLabel();code.visitLabel(loop);code.visitStmt2R1N(Op.ADD_INT_LIT8,3,3,-1);code.visitJumpStmt(Op.IF_NEZ,3,0,loop);
  code.visitMethodStmt(Op.INVOKE_DIRECT,new int[]{4,1,2,3},new Method("Leu/kanade/tachiyomi/source/model/Filter$Select;","<init>",new String[]{"Ljava/lang/String;","[Ljava/lang/Object;","I"},"V"));
  code.visitStmt1R(Op.RETURN_OBJECT,4);code.visitEnd();method.visitEnd();factory.visitEnd();dex.visitEnd();
  Path inlined=output.resolve("inlined.apk"), converted=output.resolve("inlined.jar");
  try(var zip=new java.util.zip.ZipOutputStream(Files.newOutputStream(inlined))){
   zip.putNextEntry(new java.util.zip.ZipEntry("classes.dex"));zip.write(dex.toByteArray());zip.closeEntry();
   zip.putNextEntry(new java.util.zip.ZipEntry("assets/i18n/messages_en.properties"));zip.write("title=fixture".getBytes(java.nio.charset.StandardCharsets.UTF_8));zip.closeEntry();
  }
  Files.deleteIfExists(converted);
  Artifact.convert(inlined.toString(),converted.toString());
  try(var loader=new java.net.URLClassLoader(new java.net.URL[]{converted.toUri().toURL()})){
   Object marker=Class.forName("fixture.Factory",true,loader).getMethod("create").invoke(null);
   if(!marker.getClass().getName().equals("fixture.Marker"))throw new AssertionError("Inlined constructor changed the allocated class");
   Enum<?> kind=(Enum<?>)Class.forName("fixture.Factory",true,loader).getMethod("kind").invoke(null);
   if(!kind.getClass().getName().equals("fixture.Kind")||!kind.name().equals("DOCUMENT")||kind.ordinal()!=0)throw new AssertionError("Inlined enum constructor changed");
   for(int branch:new int[]{0,1})if(!Class.forName("fixture.Factory",true,loader).getMethod("choose",int.class).invoke(null,branch).equals(7))throw new AssertionError("Sibling class merge changed");
   var filter=(eu.kanade.tachiyomi.source.model.Filter.Select<?>)Class.forName("fixture.Factory",true,loader).getMethod("filter").invoke(null);
   if(!filter.getClass().getName().equals("fixture.Choice")||!filter.getState().equals(0)||!filter.getValues()[0].equals("全部"))throw new AssertionError("Delayed constructor lost filter subclass or arguments");
   try(var stream=loader.getResourceAsStream("assets/i18n/messages_en.properties")){
    if(stream==null||!new String(stream.readAllBytes(),java.nio.charset.StandardCharsets.UTF_8).equals("title=fixture"))throw new AssertionError("APK assets were lost");
   }
  }
  System.out.println("R8 superclass chains, enum and delayed filter constructors, aliases, loops and APK resources retained.");
  for(String name:new String[]{"copymanga","hotmangas","vomic"}){
   Path input=runtime.resolve("downloads/"+name+(name.equals("vomic")?".jar":".apk"));
   Path jar=output.resolve(name+".jar");Files.deleteIfExists(jar);
   JSONObject info=(JSONObject)call(new JSONObject().put("action","inspect").put("input",input.toString()).put("output",jar.toString()));
   if(!info.getString("package").endsWith("."+name))throw new AssertionError(info);
   if(!Boolean.TRUE.equals(call(new JSONObject().put("action","validateArtifact").put("dataPath",output.toString()).put("path",jar.toString()).put("className",info.getString("className")))))throw new AssertionError(info);
   System.out.println(name+": inspected and loaded "+info.getString("version"));
  }
  Path invalid=output.resolve("invalid.jar");Files.copy(output.resolve("vomic.jar"),invalid,StandardCopyOption.REPLACE_EXISTING);
  var broken=new org.objectweb.asm.ClassWriter(0);
  broken.visit(52,1,"fixture/Broken",null,"java/lang/Object",null);
  var bad=broken.visitMethod(9,"bad","()Ljava/lang/String;",null,null);bad.visitCode();
  bad.visitTypeInsn(187,"java/lang/Object");bad.visitInsn(89);
  bad.visitMethodInsn(183,"java/lang/Object","<init>","()V",false);bad.visitInsn(176);bad.visitMaxs(2,0);bad.visitEnd();broken.visitEnd();
  try(var jar=FileSystems.newFileSystem(invalid)){Files.createDirectories(jar.getPath("/fixture"));Files.write(jar.getPath("/fixture/Broken.class"),broken.toByteArray());}
  JSONObject rejected=new JSONObject(Engine.execute(new JSONObject().put("action","validateArtifact").put("dataPath",output.toString()).put("path",invalid.toString()).put("className","keiyoushi.source.Generated").toString()));
  if(!rejected.optString("error").contains("兼容性检查"))throw new AssertionError("Lazy invalid class accepted: "+rejected);
  System.out.println("Invalid lazy request class rejected before installation.");
  var abstractAllocation=new org.objectweb.asm.ClassWriter(0);
  abstractAllocation.visit(52,1,"fixture/Broken",null,"java/lang/Object",null);
  var allocation=abstractAllocation.visitMethod(9,"bad","()V",null,null);allocation.visitCode();
  allocation.visitTypeInsn(187,"eu/kanade/tachiyomi/source/model/Filter$Select");allocation.visitInsn(87);allocation.visitInsn(177);allocation.visitMaxs(1,0);allocation.visitEnd();abstractAllocation.visitEnd();
  try(var jar=FileSystems.newFileSystem(invalid)){Files.write(jar.getPath("/fixture/Broken.class"),abstractAllocation.toByteArray());}
  try(var loader=new java.net.URLClassLoader(new java.net.URL[]{invalid.toUri().toURL()})){Class.forName("fixture.Broken",false,loader).getDeclaredMethods();}
  rejected=new JSONObject(Engine.execute(new JSONObject().put("action","validateArtifact").put("dataPath",output.toString()).put("path",invalid.toString()).put("className","keiyoushi.source.Generated").toString()));
  if(!rejected.optString("error").contains("兼容性检查"))throw new AssertionError("Abstract allocation accepted: "+rejected);
  System.out.println("Lazy abstract allocation rejected before installation.");
  for(int i=2;i<args.length;i++){
   Path input=Path.of(args[i]),jar=output.resolve(input.getFileName().toString()+".jar");Files.deleteIfExists(jar);
   JSONObject info=(JSONObject)call(new JSONObject().put("action","inspect").put("input",input.toString()).put("output",jar.toString()));
   call(new JSONObject().put("action","validateArtifact").put("dataPath",output.toString()).put("path",jar.toString()).put("className",info.getString("className")));
   JSONArray sources=(JSONArray)call(new JSONObject().put("action","load").put("dataPath",output.toString()).put("extensions",new JSONArray().put(new JSONObject().put("path",jar.toString()).put("package",info.getString("package")).put("className",info.getString("className")))));
   for(int j=0;j<sources.length();j++)call(new JSONObject().put("action","filters").put("source",sources.getJSONObject(j).getString("id")));
   System.out.println(info.getString("package")+" "+info.getString("version")+": all classes, factories and search filters verified");
  }
  System.exit(0);
 }
}''')
subprocess.run([str(JAVA.with_name('javac')), '--release', '17', '-cp', CP, '-d', str(BUILD),
                str(BUILD / 'NativeServices.java'), str(BUILD / 'ArtifactCheck.java')], check=True)
subprocess.run([str(JAVA), '-Xverify:all', '--limit-modules', 'java.base,java.logging,java.xml,jdk.unsupported,jdk.zipfs',
                '-cp', CP, 'ArtifactCheck', str(RUNTIME), str(BUILD), *sys.argv[1:]], check=True)
for name in ['inlined', 'copymanga', 'hotmangas', 'vomic', *[Path(path).name for path in sys.argv[1:]]]:
    with zipfile.ZipFile(BUILD / (name + '.jar')) as archive:
        assert archive.testzip() is None
        assert any(item.endswith('.class') for item in archive.namelist()), name
        if name != 'vomic':
            assert all(struct.unpack('>H', archive.read(item)[6:8])[0] >= 51
                       for item in archive.namelist() if item.endswith('.class')), 'APK classes must not use the desktop legacy verifier fallback'
print('APK/JAR conversion, source factories and archive integrity passed with the iOS module set.')
