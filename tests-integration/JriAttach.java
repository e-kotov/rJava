import org.rosuda.JRI.REXP;
import org.rosuda.JRI.Rengine;

/* A Java application hosts the JVM and embeds R through JRI. rJava loaded in
   that R must attach to the running JVM, not select the JAVA_HOME runtime. */
public class JriAttach {
    public static void main(String[] args) {
        try {
            run();
        } catch (Throwable e) {
            e.printStackTrace();
        }
        System.exit(1); /* the R thread is not a daemon, so always exit */
    }

    static void run() {
        Rengine engine = new Rengine(new String[] { "--vanilla", "--no-echo" }, false, null);
        if (!engine.waitForR()) {
            System.err.println("FAIL: cannot start embedded R");
            System.exit(2);
        }
        REXP result = engine.eval("tryCatch({" +
            " library(rJava); .jinit();" +
            " paste('OK', .jvmState()$state, .jcall('java/lang/System', 'S', 'getProperty', 'java.home')," +
            "   !is.jnull(.jengine()), sep = '|')" +
            "}, error = function(e) paste('ERROR', conditionMessage(e), sep = '|'))");
        String text = result == null ? "ERROR|no result" : result.asString();
        String expected = "OK|attached|" + System.getProperty("java.home") + "|TRUE";
        System.out.println("JRI host " + System.getProperty("java.version") + ": " + text);
        engine.end();
        if (!expected.equals(text)) {
            System.err.println("FAIL: expected " + expected);
            return;
        }
        System.out.println("PASS jri-host");
        System.exit(0);
    }
}
