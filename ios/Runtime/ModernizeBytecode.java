import java.nio.file.*;
import java.util.zip.*;
import org.objectweb.asm.*;

/** Prepare dependency bytecode for OpenJDK Mobile and current extension APIs. */
public class ModernizeBytecode {
    public static void main(String[] args) throws Exception {
        Path input = Path.of(args[0]), output = Path.of(args[1]);
        int changed = 0, groups = 0;
        try (ZipFile jar = new ZipFile(input.toFile());
             ZipOutputStream zip = new ZipOutputStream(Files.newOutputStream(output))) {
            for (var entry : java.util.Collections.list(jar.entries())) {
                byte[] bytes = jar.getInputStream(entry).readAllBytes();
                boolean legacy = entry.getName().endsWith(".class") && new ClassReader(bytes).readShort(6) < Opcodes.V1_6;
                // Current extensions instantiate Group directly; it has no abstract methods.
                boolean group = entry.getName().equals("eu/kanade/tachiyomi/source/model/Filter$Group.class");
                if (legacy || group || entry.getName().equals("eu/kanade/tachiyomi/source/model/Filter.class")) {
                    ClassWriter writer = new ClassWriter(legacy ? ClassWriter.COMPUTE_FRAMES : 0);
                    new ClassReader(bytes).accept(new ClassVisitor(Opcodes.ASM9, writer) {
                        public void visit(int version, int access, String name, String signature, String parent, String[] interfaces) {
                            super.visit(legacy ? Opcodes.V1_8 : version, group ? access & ~Opcodes.ACC_ABSTRACT : access, name, signature, parent, interfaces);
                        }
                        public void visitInnerClass(String name, String outerName, String innerName, int access) {
                            super.visitInnerClass(name, outerName, innerName, name.equals("eu/kanade/tachiyomi/source/model/Filter$Group") ? access & ~Opcodes.ACC_ABSTRACT : access);
                        }
                    }, legacy ? ClassReader.SKIP_FRAMES : 0);
                    bytes = writer.toByteArray();
                    if (legacy) changed++;
                    if (group) groups++;
                }
                zip.putNextEntry(new ZipEntry(entry.getName()));
                zip.write(bytes);
                zip.closeEntry();
            }
        }
        System.out.println("Added modern verification frames to " + changed + " legacy dependency classes");
        System.out.println("Enabled direct construction of " + groups + " filter Group API class");
    }
}
