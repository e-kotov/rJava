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
        /* An explicit path must name the mapped file: JAVA_HOME's runtime is rejected. */
        REXP result = engine.eval("tryCatch({" +
            " library(rJava);" +
            " b <- try(.jloadJVM(rJava:::.find.jvm.library(Sys.getenv('JAVA_HOME'))[1]), silent = TRUE);" +
            " if (!inherits(b, 'try-error') || .jvmState()$state != 'not-loaded')" +
            "   stop('JAVA_HOME runtime was selected: ', if (inherits(b, 'try-error')) trimws(b) else 'loaded'," +
            "        '; state ', .jvmState()$state, '; mapped ', paste(unlist(.Call(rJava:::RgetMappedJVM)), collapse = ' '));" +
            " .jinit();" +
            " paste('OK', .jvmState()$state, .jcall('java/lang/System', 'S', 'getProperty', 'java.home')," +
            "   !is.jnull(.jengine()), sep = '|')" +
            "}, error = function(e) paste('ERROR', conditionMessage(e), sep = '|'))");
        String text = result == null ? "ERROR|no result" : result.asString();
        String expected = "OK|attached|" + System.getProperty("java.home") + "|TRUE";
        System.out.println("JRI host " + System.getProperty("java.version") + ": " + text);
        if (System.getProperty("os.name").startsWith("Windows")) {
            final String[] interrupted = new String[1];
            Thread evaluator = new Thread(new Runnable() {
                public void run() {
                    REXP value = engine.eval("tryCatch({Sys.sleep(60); 'MISSED'}, interrupt=function(e) 'INTERRUPTED')");
                    interrupted[0] = value == null ? "NULL" : value.asString();
                }
            });
            evaluator.setDaemon(true);
            evaluator.start();
            try {
                Thread.sleep(1000);
                engine.rniStop(0);
                evaluator.join(10000);
            } catch (InterruptedException e) { throw new RuntimeException(e); }
            if (evaluator.isAlive() || !"INTERRUPTED".equals(interrupted[0]) ||
                engine.eval("as.integer(1+1)").asInt() != 2) {
                System.err.println("FAIL: JRI interrupt/recovery: " + interrupted[0]);
                System.exit(3);
            }
            System.out.println("PASS jri-interrupt-recovery");
        }
        engine.end();
        if (!expected.equals(text)) {
            System.err.println("FAIL: expected " + expected);
            return;
        }
        System.out.println("PASS jri-host");
        System.exit(0);
    }
}
