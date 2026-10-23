# Common public rJava workload: identical for upstream master and the candidate.
windows_workload <- function(home) {
  .jinit <- rJava::.jinit
  J <- rJava::.jcall
  .jinit()
  actual <- normalizePath(J("java/lang/System", "S", "getProperty", "java.home"), winslash = "/")
  expected <- normalizePath(home, winslash = "/")
  stopifnot(identical(actual, expected) || identical(dirname(actual), expected))
  stopifnot(J(rJava::.jnew("java/lang/String", "comparison"), "I", "length") == 10L)
  deflater <- rJava::.jnew("java/util/zip/Deflater")
  J(deflater, "V", "setInput", rJava::.jarray(as.raw(1:100)))
  J(deflater, "V", "finish")
  stopifnot(J(deflater, "I", "deflate", rJava::.jarray(raw(200))) > 0L)
  J(deflater, "V", "end")
  address <- J("java/net/InetAddress", "Ljava/net/InetAddress;", "getByName", "127.0.0.1")
  socket <- rJava::.jnew("java/net/ServerSocket", 0L, 1L, address)
  stopifnot(J(socket, "I", "getLocalPort") > 0L)
  J(socket, "V", "close")
  digest <- J("java/security/MessageDigest", "Ljava/security/MessageDigest;", "getInstance", "SHA-256")
  stopifnot(length(J(digest, "[B", "digest", rJava::.jarray(as.raw(1:3)))) == 32L)
  bean <- J("java/lang/management/ManagementFactory", "Ljava/lang/management/RuntimeMXBean;", "getRuntimeMXBean")
  stopifnot(J(bean, "J", "getUptime") >= 0)
  store <- J("java/security/KeyStore", "Ljava/security/KeyStore;", "getInstance", "Windows-MY")
  J(store, "V", "load", rJava::.jnull("java/security/KeyStore$LoadStoreParameter"))
  image <- rJava::.jnew("java/awt/image/BufferedImage", 40L, 20L, 1L)
  graphics <- J(image, "Ljava/awt/Graphics2D;", "createGraphics")
  J(graphics, "V", "drawString", "rJava", 2L, 15L)
  out <- rJava::.jnew("java/io/ByteArrayOutputStream")
  stopifnot(J("javax/imageio/ImageIO", "Z", "write", rJava::.jcast(image, "java/awt/image/RenderedImage"),
              "png", rJava::.jcast(out, "java/io/OutputStream")), J(out, "I", "size") > 0L)
  J(graphics, "V", "dispose")
  cat("PASS common workload at", actual, "\n")
  TRUE
}
