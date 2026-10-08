import java.io.*;
import java.nio.file.*;
import java.util.*;
import jdk.internal.module.ModuleInfoExtender;

public class ModulePackages {
    public static void main(String[] args) throws Exception {
        Path base = Paths.get(args[0]);
        Set<String> packages = new TreeSet<>();
        try (var files = Files.walk(base)) {
            for (Path file : files.filter(p -> p.toString().endsWith(".class")).toList()) {
                Path parent = base.relativize(file).getParent();
                if (parent != null) packages.add(parent.toString().replace('/', '.'));
            }
        }
        byte[] info = Files.readAllBytes(base.resolve("module-info.class"));
        byte[] updated = ModuleInfoExtender.newExtender(new ByteArrayInputStream(info)).packages(packages).toByteArray();
        Files.write(Paths.get(args[1]), updated);
        System.out.println("java.base descriptor: " + packages.size() + " actual packages");
    }
}
