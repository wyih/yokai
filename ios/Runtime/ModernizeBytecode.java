import java.nio.file.*;
import java.util.zip.*;
import org.objectweb.asm.*;

/** Add stack maps to legacy dependency classes for OpenJDK Mobile's verifier. */
public class ModernizeBytecode {
    public static void main(String[] args) throws Exception {
        Path input = Path.of(args[0]), output = Path.of(args[1]);
        int changed = 0;
        try (ZipFile jar = new ZipFile(input.toFile());
             ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(output))) {
            for (var entry : java.util.Collections.list(jar.entries())) {
                byte[] bytes = jar.getInputStream(entry).readAllBytes();
                if (entry.getName().endsWith(".class") && new ClassReader(bytes).readShort(6) < Opcodes.V1_6) {
                    ClassWriter writer = new ClassWriter(ClassWriter.COMPUTE_FRAMES);
                    new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9, writer) {
                        public void visit(int version, int access, String name, String signature, String parent, String[] interfaces) {
                            super.visit(Opcodes.V1_8, access, name, signature, parent, interfaces);
                        }
                    }, ClassReader.SKIP_FRAMES);
                    bytes = writer.toByteArray();
                    changed++;
                }
                zip.putNextEntry(new ZipEntry(entry.getName()));
                zip.write(bytes);
                zip.closeEntry();
            }
        }
        System.out.println("Added modern verification frames to " + changed + " legacy dependency classes");
    }
}
