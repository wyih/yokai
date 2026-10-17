#!/usr/bin/env python3
"""Convert and load APK/JAR plugins using only the modules bundled on iOS."""
from pathlib import Path
import os
import subprocess
import struct
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
  dex.visit(DexConstants.ACC_PUBLIC,"Lfixture/Marker;","Ljava/lang/Object;",null).visitEnd();
  var factory=dex.visit(DexConstants.ACC_PUBLIC,"Lfixture/Factory;","Ljava/lang/Object;",null);
  var method=factory.visitMethod(DexConstants.ACC_PUBLIC|DexConstants.ACC_STATIC,new Method("Lfixture/Factory;","create",new String[0],"Lfixture/Marker;"));
  var code=method.visitCode();code.visitRegister(1);
  code.visitTypeStmt(Op.NEW_INSTANCE,0,0,"Lfixture/Marker;");
  DexLabel line=new DexLabel();code.visitLabel(line);code.visitDebug().visitLineNumber(1,line);
  code.visitMethodStmt(Op.INVOKE_DIRECT,new int[]{0},new Method("Ljava/lang/Object;","<init>",new String[0],"V"));
  code.visitStmt1R(Op.RETURN_OBJECT,0);code.visitEnd();method.visitEnd();factory.visitEnd();dex.visitEnd();
  Path inlined=output.resolve("inlined.dex"), converted=output.resolve("inlined.jar");
  Files.write(inlined,dex.toByteArray());Files.deleteIfExists(converted);
  Artifact.convert(inlined.toString(),converted.toString());
  try(var loader=new java.net.URLClassLoader(new java.net.URL[]{converted.toUri().toURL()})){
   Object marker=Class.forName("fixture.Factory",true,loader).getMethod("create").invoke(null);
   if(!marker.getClass().getName().equals("fixture.Marker"))throw new AssertionError("Inlined constructor changed the allocated class");
  }
  System.out.println("R8 inlined Object constructor retained the allocated subclass.");
  for(String name:new String[]{"copymanga","hotmangas","vomic"}){
   Path input=runtime.resolve("downloads/"+name+(name.equals("vomic")?".jar":".apk"));
   Path jar=output.resolve(name+".jar");Files.deleteIfExists(jar);
   JSONObject info=(JSONObject)call(new JSONObject().put("action","inspect").put("input",input.toString()).put("output",jar.toString()));
   if(!info.getString("package").endsWith("."+name))throw new AssertionError(info);
   if(!Boolean.TRUE.equals(call(new JSONObject().put("action","validateArtifact").put("dataPath",output.toString()).put("path",jar.toString()).put("className",info.getString("className")))))throw new AssertionError(info);
   System.out.println(name+": inspected and loaded "+info.getString("version"));
  }
 }
}''')
subprocess.run([str(JAVA.with_name('javac')), '--release', '17', '-cp', CP, '-d', str(BUILD),
                str(BUILD / 'NativeServices.java'), str(BUILD / 'ArtifactCheck.java')], check=True)
subprocess.run([str(JAVA), '-Xverify:all', '--limit-modules', 'java.base,java.logging,java.xml,jdk.unsupported,jdk.zipfs',
                '-cp', CP, 'ArtifactCheck', str(RUNTIME), str(BUILD)], check=True)
for name in ['copymanga', 'hotmangas', 'vomic']:
    with zipfile.ZipFile(BUILD / (name + '.jar')) as archive:
        assert archive.testzip() is None
        assert any(item.endswith('.class') for item in archive.namelist()), name
print('APK/JAR conversion, source factories and archive integrity passed with the iOS module set.')
