import java.io.*;
import java.nio.file.*;
import com.googlecode.d2j.dex.Dex2jar;
import com.googlecode.dex2jar.tools.BaksmaliBaseDexExceptionHandler;
import com.googlecode.d2j.reader.MultiDexFileReader;
import net.dongliu.apk.parser.ApkFile;

public class ConvertApk {
    public static void main(String[] args) throws Exception {
        try (ApkFile apk = new ApkFile(args[0])) {
            System.out.println(apk.getManifestXml());
        }
        BaksmaliBaseDexExceptionHandler handler = new BaksmaliBaseDexExceptionHandler();
        Dex2jar.from(MultiDexFileReader.open(Files.readAllBytes(Paths.get(args[0]))))
            .withExceptionHandler(handler).reUseReg(false).topoLogicalSort().skipDebug(true)
            .optimizeSynchronized(false).printIR(false).noCode(false).skipExceptions(false)
            .dontSanitizeNames(true).computeFrames(true).to(Paths.get(args[1]));
        if (handler.hasException()) throw new IOException("Incomplete dex conversion: " + args[0]);
    }
}
