import java.io.*;
import java.nio.ByteOrder;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import jdk.tools.jlink.internal.BasicImageWriter;
import jdk.tools.jlink.internal.ImageResourcesTree;

/** Packs unchanged OpenJDK Mobile classes; no desktop VM or jlink optimizations. */
public class JimageBuilder {
    public static void main(String[] args) throws Exception {
        SortedMap<String, byte[]> entries = new TreeMap<>();
        Path base = Paths.get(args[0]);
        try (var stream = Files.walk(base)) {
            for (Path file : stream.filter(Files::isRegularFile).toList())
                entries.put("/java.base/" + base.relativize(file).toString(), Files.readAllBytes(file));
        }
        entries.put("/java.base/module-info.class", Files.readAllBytes(Paths.get("module-build/java.base-module-info.class")));
        Path jmods = Paths.get(args[1]);
        for (String module : List.of("java.logging", "java.xml", "jdk.unsupported")) {
            try (ZipFile zip = new ZipFile(jmods.resolve(module + ".jmod").toFile())) {
                for (var item : Collections.list(zip.entries())) {
                    if (!item.isDirectory() && item.getName().startsWith("classes/"))
                        entries.put("/" + module + "/" + item.getName().substring(8), zip.getInputStream(item).readAllBytes());
                }
            }
        }
        BasicImageWriter writer = new BasicImageWriter(ByteOrder.LITTLE_ENDIAN);
        long offset = 0;
        for (var item : entries.entrySet()) {
            writer.addLocation(item.getKey(), offset, 0, item.getValue().length);
            offset += item.getValue().length;
        }
        ImageResourcesTree tree = new ImageResourcesTree(offset, writer, new ArrayList<>(entries.keySet()));
        Path output = Paths.get(args[2]);
        Files.createDirectories(output.getParent());
        try (DataOutputStream out = new DataOutputStream(new BufferedOutputStream(Files.newOutputStream(output)))) {
            out.write(writer.getBytes());
            for (byte[] content : entries.values()) out.write(content);
            tree.addContent(out);
        }
        System.out.println(entries.size() + " unchanged resources packed in " + output);
    }
}
