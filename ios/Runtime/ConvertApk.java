import net.dongliu.apk.parser.ApkFile;
import yokai.Artifact;

public class ConvertApk {
    public static void main(String[] args) throws Exception {
        try (ApkFile apk = new ApkFile(args[0])) {
            System.out.println(apk.getManifestXml());
        }
        Artifact.convert(args[0], args[1]);
    }
}
