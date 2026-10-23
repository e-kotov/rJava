import org.rosuda.JRI.REXP;
import org.rosuda.JRI.Rengine;

/* An application can supply JRI independently of the installed rJava build. */
public class WindowsCompareJri {
    public static void main(String[] args) {
        try {
            Rengine engine = new Rengine(new String[] { "--vanilla", "--no-echo" }, false, null);
            if (!engine.waitForR()) throw new RuntimeException("cannot start embedded R");
            REXP result = engine.eval("tryCatch({" +
                " library(rJava);" +
                " source(Sys.getenv('RJE_COMPARE_WORKLOAD'));" +
                " stopifnot(windows_workload(Sys.getenv('RJE_JAVA_HOME_TEST')));" +
                " stopifnot(.jvmState()$state == 'attached');" +
                " 'PASS external JRI host'" +
                " }, error=function(e) paste('FAIL external JRI host:', conditionMessage(e)))");
            String text = result == null ? "FAIL no embedded R result" : result.asString();
            System.out.println(text);
            System.exit("PASS external JRI host".equals(text) ? 0 : 1);
        } catch (Throwable e) {
            e.printStackTrace();
            System.exit(2);
        }
    }
}
