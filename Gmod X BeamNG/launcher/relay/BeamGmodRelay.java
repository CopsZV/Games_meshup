// BeamGmodRelay: a dumb pipe between BeamNG's crossover extension (UDP, protocol v1, see
// Beamgmod's beamng/docs/protocol.md) and Garry's Mod, whose Lua cannot open sockets.
// It also turns BeamNG's own car export (glTF) into files Garry's Mod can draw (ModelBuilder, below).
//
//   java BeamGmodRelay.java <garrysmod/data/beamgmod dir> [udpPort]
//   java BeamGmodRelay.java --convert <car.glb> <car.json> <models dir>      (manual conversion)
//
// It speaks the session protocol itself (hello/welcome, ping, sid, seq, ts, reconnect), so GMod
// only ever sees plain payloads. Everything is exchanged as files:
//
//   <dir>/in/status.json         relay state, rewritten twice a second (beat counter = relay is alive)
//   <dir>/in/state.json           newest BeamNG "state" message         (latest wins, <= 30 Hz)
//   <dir>/in/vehicles.json        newest BeamNG "vehicles" message      (latest wins)
//   <dir>/in/vmesh_<id>.json      newest node stream of car <id>        (latest wins)
//   <dir>/in/vtris_<id>.json      skin triangles of car <id>
//   <dir>/in/model_<id>.json      the converted real model of car <id> (see ModelBuilder)
//   <dir>/in/ev/<n>.json          every other message, in order; GMod deletes each after reading it
//   <dir>/out/<n>.json            payloads from GMod, processed in file-name order, then deleted
//   <dir>/out/hm_<id>.dat         terrain heights for an "@terrain" command (uint16 LE, grid order)
//   <dir>/models/                 converted cars: <key>.dat (mesh), <key>.json (definition), tex/<key>_<n>.png
//
// Payloads GMod writes are JSON objects with a "t" field. "@terrain" and "@quit" are for the relay;
// anything else gets the protocol envelope and goes to BeamNG as it is.

import java.awt.color.ColorSpace;
import java.awt.image.BufferedImage;
import java.awt.image.Raster;
import java.awt.image.WritableRaster;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.DatagramPacket;
import java.net.DatagramSocket;
import java.net.InetAddress;
import java.net.InetSocketAddress;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ConcurrentLinkedQueue;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.Consumer;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.stream.IntStream;
import javax.imageio.ImageIO;

public class BeamGmodRelay {
    static final int PROTOCOL = 1;
    static final int MAX_TO_BEAMNG = 8000;       // BeamNG's LuaSocket reads at most 8192 bytes per datagram
    static final long SILENCE_MS = 30_000;       // BeamNG can stall for ~25 s while it loads a car
    static final long EXPORT_SILENCE_MS = 150_000; // ... and for up to a minute while it exports a car model
    static final long FLUSH_MS = 33;             // latest-wins files are written at most this often
    static final int EV_BACKLOG = 600;           // unread events before the oldest are dropped

    static final Pattern P_TYPE = Pattern.compile("\"t\"\\s*:\\s*\"([A-Za-z0-9_@]+)\"");
    static final Pattern P_SID = Pattern.compile("\"sid\"\\s*:\\s*(-?\\d+)");
    static final Pattern P_SEQ = Pattern.compile("\"seq\"\\s*:\\s*(-?\\d+)");
    static final Pattern P_ID = Pattern.compile("\"id\"\\s*:\\s*(-?\\d+)");
    static final Pattern P_LEVEL = Pattern.compile("\"level\"\\s*:\\s*\"([^\"]*)\"");
    static final Pattern P_READY = Pattern.compile("\"ready\"\\s*:\\s*(true|false)");
    static final Pattern P_VER = Pattern.compile("\"bngVersion\"\\s*:\\s*\"([^\"]*)\"");
    static final Pattern P_USER = Pattern.compile("\"user\"\\s*:\\s*\"((?:[^\"\\\\]|\\\\.)*)\"");

    final Path dir, inDir, evDir, outDir, modelsDir;
    final int port;
    final DatagramSocket sock;
    final InetSocketAddress peer;
    final long t0 = System.nanoTime();

    volatile boolean running = true;
    volatile boolean connected = false;
    volatile long sid = 0;
    volatile String level = "", bngVersion = "", userDir = "";
    volatile boolean ready = false;
    volatile long lastRxMs = 0;
    volatile long lastPeerSeq = -1;
    volatile double rttMs = -1;
    final AtomicLong seq = new AtomicLong(0);
    final AtomicLong evNo = new AtomicLong(0);
    final AtomicLong rx = new AtomicLong(), tx = new AtomicLong(), dropped = new AtomicLong(), stale = new AtomicLong();

    // latest-wins files, keyed by file name
    final Map<String, String> pending = new ConcurrentHashMap<>();
    final ConcurrentLinkedQueue<String> events = new ConcurrentLinkedQueue<>();
    final Map<String, Long> lastFlush = new ConcurrentHashMap<>();

    // a terrain_load that BeamNG hasn't answered yet (UDP can lose it, and BeamNG stalls while loading)
    volatile String terrainMsg = null;
    volatile long terrainId = -1, terrainSentMs = 0, terrainFirstMs = 0;

    // car models: BeamNG's "vexported" answers are converted on a thread of their own
    final ExecutorService modelExec = Executors.newSingleThreadExecutor(r -> {
        Thread t = new Thread(r, "relay-model");
        t.setDaemon(true);
        return t;
    });
    final Map<Long, String> modelSig = new ConcurrentHashMap<>();
    volatile long exportDeadlineMs = 0;

    BeamGmodRelay(Path dir, int port) throws IOException {
        this.dir = dir;
        this.port = port;
        inDir = dir.resolve("in");
        evDir = inDir.resolve("ev");
        outDir = dir.resolve("out");
        modelsDir = dir.resolve("models");
        Files.createDirectories(evDir);
        Files.createDirectories(outDir);
        Files.createDirectories(modelsDir.resolve("tex"));
        clean(inDir);
        clean(evDir);
        clean(outDir);
        sock = new DatagramSocket(new InetSocketAddress(InetAddress.getByName("127.0.0.1"), 0));
        peer = new InetSocketAddress(InetAddress.getByName("127.0.0.1"), port);
    }

    static void clean(Path d) throws IOException {
        try (DirectoryStream<Path> ds = Files.newDirectoryStream(d)) {
            for (Path p : ds) if (Files.isRegularFile(p)) Files.deleteIfExists(p);
        }
    }

    long nowMs() { return (System.nanoTime() - t0) / 1_000_000L; }
    double tsMs() { return (System.nanoTime() - t0) / 1e6; }

    static void log(String s) { System.out.println("[relay] " + s); System.out.flush(); }

    // ---------------------------------------------------------------- sending to BeamNG

    boolean sendRaw(String json) {
        byte[] b = json.getBytes(StandardCharsets.UTF_8);
        if (b.length > MAX_TO_BEAMNG) return false;
        try {
            sock.send(new DatagramPacket(b, b.length, peer));
            tx.incrementAndGet();
            return true;
        } catch (IOException e) {
            return false;
        }
    }

    // payload: a JSON object text starting with '{'. The envelope goes in front of its fields.
    boolean sendPayload(String payload) {
        String p = payload.trim();
        if (!p.startsWith("{")) return false;
        String rest = p.substring(1).trim();
        String env = "{\"v\":" + PROTOCOL + ",\"sid\":" + sid + ",\"seq\":" + seq.incrementAndGet()
                + ",\"ts\":" + String.format(java.util.Locale.ROOT, "%.3f", tsMs());
        return sendRaw(rest.startsWith("}") ? env + "}" : env + "," + rest);
    }

    void sendHello() {
        sendRaw("{\"v\":" + PROTOCOL + ",\"t\":\"hello\",\"sid\":0,\"seq\":" + seq.incrementAndGet() + ",\"ts\":"
                + String.format(java.util.Locale.ROOT, "%.3f", tsMs()) + ",\"client\":\"beamgmod-relay\",\"protocol\":" + PROTOCOL + "}");
    }

    // ---------------------------------------------------------------- receiving from BeamNG

    static String find(Pattern p, String s) {
        Matcher m = p.matcher(s);
        return m.find() ? m.group(1) : null;
    }

    static String unescape(String s) {
        StringBuilder b = new StringBuilder();
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            if (c == '\\' && i + 1 < s.length()) { b.append(s.charAt(++i)); } else b.append(c);
        }
        return b.toString();
    }

    void event(String json) { events.add(json); }

    void onDatagram(String s) {
        rx.incrementAndGet();
        String type = find(P_TYPE, s);
        String sidS = find(P_SID, s), seqS = find(P_SEQ, s);
        if (type == null || sidS == null) return;
        long msgSid = Long.parseLong(sidS);
        long msgSeq = seqS == null ? -1 : Long.parseLong(seqS);
        long now = nowMs();

        if (type.equals("welcome")) {
            if (!(connected && msgSid == sid)) {
                sid = msgSid;
                lastPeerSeq = msgSeq;
                String lv = find(P_LEVEL, s), ver = find(P_VER, s), user = find(P_USER, s), rd = find(P_READY, s);
                level = lv == null ? "" : lv;
                bngVersion = ver == null ? "" : ver;
                userDir = user == null ? "" : unescape(user);
                ready = "true".equals(rd);
                connected = true;
                lastRxMs = now;
                modelSig.clear();
                try (DirectoryStream<Path> ds = Files.newDirectoryStream(inDir, "model_*.json")) {
                    for (Path p : ds) Files.deleteIfExists(p);
                } catch (IOException ignored) { }
                log("connected to BeamNG " + bngVersion + ", level " + level + ", session " + sid + ", user folder " + userDir);
                event("{\"t\":\"@connected\",\"sid\":" + sid + ",\"level\":\"" + level + "\",\"ready\":" + ready + "}");
            } else {
                String rd = find(P_READY, s), lv = find(P_LEVEL, s);
                ready = "true".equals(rd);
                if (lv != null) level = lv;
                lastRxMs = now;
            }
            return;
        }
        if (type.equals("error") && s.matches("(?s).*\"unknown_session\".*") && msgSid == sid) {
            if (connected) log("BeamNG forgot our session; reconnecting");
            connected = false;
            sid = 0;
            event("{\"t\":\"@disconnected\",\"why\":\"unknown_session\"}");
            return;
        }
        if (!connected || msgSid != sid) { stale.incrementAndGet(); return; }
        lastRxMs = now;
        if (msgSeq >= 0) {
            long gap = msgSeq - lastPeerSeq;
            if (gap <= 0) { stale.incrementAndGet(); return; }
            if (gap > 1) dropped.addAndGet(gap - 1);
            lastPeerSeq = msgSeq;
        }
        switch (type) {
            case "pong": {
                Matcher m = Pattern.compile("\"echo\"\\s*:\\s*(-?[0-9.eE+-]+)").matcher(s);
                if (m.find()) {
                    try { double r = tsMs() - Double.parseDouble(m.group(1)); rttMs = rttMs < 0 ? r : rttMs * 0.8 + r * 0.2; } catch (NumberFormatException ignored) { }
                }
                return;
            }
            case "bye":
                connected = false;
                sid = 0;
                event("{\"t\":\"@disconnected\",\"why\":\"bye\"}");
                return;
            case "state": pending.put("state.json", s); return;
            case "vehicles": pending.put("vehicles.json", s); return;
            case "vmesh": { String id = find(P_ID, s); if (id != null) pending.put("vmesh_" + id + ".json", s); return; }
            case "vtris": { String id = find(P_ID, s); if (id != null) pending.put("vtris_" + id + ".json", s); return; }
            case "vexported": handleExported(s); return;
            case "terrain_loaded": {
                String id = find(P_ID, s);
                if (id != null && Long.parseLong(id) == terrainId) terrainMsg = null;
                event(s);
                return;
            }
            default:
                if (type.equals("error") && s.contains("terrain_failed")) terrainMsg = null;
                if (type.equals("error") && s.contains("export_failed")) exportDeadlineMs = 0;
                event(s);
        }
    }

    void handleExported(String s) {
        exportDeadlineMs = 0;
        final Map<String, Object> m;
        try {
            m = Json.obj(Json.parse(s));
        } catch (RuntimeException e) {
            log("unreadable vexported: " + e);
            return;
        }
        if (m == null) return;
        final long id = (long) Json.num(m.get("id"), -1);
        final String file = Json.str(m.get("file")), side = Json.str(m.get("side"));
        final String model = Json.str(m.get("model")) == null ? "" : Json.str(m.get("model"));
        if (id < 0 || file == null || side == null) {
            event("{\"t\":\"@modelfail\",\"id\":" + id + ",\"msg\":\"vexported without file\"}");
            return;
        }
        String sig = file + "|" + side;
        if (sig.equals(modelSig.get(id))) return;
        modelSig.put(id, sig);
        modelExec.submit(() -> {
            long t1 = System.nanoTime();
            try {
                ModelBuilder.Result r = ModelBuilder.convert(Paths.get(file), Paths.get(side), modelsDir, BeamGmodRelay::log);
                long ms = (System.nanoTime() - t1) / 1_000_000L;
                String j = "{\"t\":\"model\",\"id\":" + id + ",\"model\":" + quote(model) + ",\"def\":" + quote("models/" + r.def)
                        + ",\"tris\":" + r.tris + ",\"verts\":" + r.verts + ",\"chunks\":" + r.chunks + "}";
                writeAtomic(inDir.resolve("model_" + id + ".json"), j);
                event("{\"t\":\"@model\",\"id\":" + id + ",\"model\":" + quote(model) + ",\"ms\":" + ms + ",\"cached\":" + r.cached + "}");
                log("car " + id + " (" + model + ") converted in " + ms + " ms: " + r.tris + " triangles, " + r.chunks + " chunks");
            } catch (Throwable ex) {
                modelSig.remove(id);
                java.io.StringWriter sw = new java.io.StringWriter();
                ex.printStackTrace(new java.io.PrintWriter(sw));
                log("model conversion of car " + id + " failed: " + sw);
                event("{\"t\":\"@modelfail\",\"id\":" + id + ",\"msg\":" + quote(String.valueOf(ex)) + "}");
            }
        });
    }

    void receiveLoop() {
        byte[] buf = new byte[65536];
        DatagramPacket pk = new DatagramPacket(buf, buf.length);
        while (running) {
            try {
                pk.setLength(buf.length);
                sock.receive(pk);
                onDatagram(new String(pk.getData(), 0, pk.getLength(), StandardCharsets.UTF_8));
            } catch (java.net.PortUnreachableException e) {
                // BeamNG isn't listening yet
            } catch (IOException e) {
                if (running) { try { Thread.sleep(20); } catch (InterruptedException ie) { return; } }
            } catch (RuntimeException e) {
                log("bad datagram ignored: " + e);
            }
        }
    }

    static void writeAtomic(Path target, String content) throws IOException {
        Path tmp = target.resolveSibling(target.getFileName() + ".tmp");
        Files.write(tmp, content.getBytes(StandardCharsets.UTF_8));
        try {
            Files.move(tmp, target, StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE);
        } catch (IOException e) {
            Files.deleteIfExists(tmp);
            throw e;
        }
    }

    void flushLatest(long now) {
        for (String name : new ArrayList<>(pending.keySet())) {
            Long last = lastFlush.get(name);
            if (last != null && now - last < FLUSH_MS) continue;
            String content = pending.remove(name);
            if (content == null) continue;
            lastFlush.put(name, now);
            try { writeAtomic(inDir.resolve(name), content); } catch (IOException ignored) { }
        }
    }

    void flushEvents() {
        String e;
        while ((e = events.poll()) != null) {
            try { writeAtomic(evDir.resolve(String.format("%09d.json", evNo.incrementAndGet())), e); } catch (IOException ex) { log("event write failed: " + ex); }
        }
    }

    long lastTrim = 0;
    void trimEvents(long now) {
        if (now - lastTrim < 2000) return;
        lastTrim = now;
        List<Path> files = new ArrayList<>();
        try (DirectoryStream<Path> ds = Files.newDirectoryStream(evDir, "*.json")) { for (Path p : ds) files.add(p); } catch (IOException e) { return; }
        if (files.size() <= EV_BACKLOG) return;
        Collections.sort(files);
        for (int i = 0; i < files.size() - EV_BACKLOG / 2; i++) { try { Files.deleteIfExists(files.get(i)); } catch (IOException ignored) { } }
    }

    long beat = 0, lastStatus = 0;
    boolean lastConn = false;
    void writeStatus(long now, boolean force) {
        if (!force && now - lastStatus < 500 && connected == lastConn) return;
        lastStatus = now;
        lastConn = connected;
        beat++;
        String j = "{\"t\":\"status\",\"relay\":true,\"beat\":" + beat + ",\"connected\":" + connected + ",\"sid\":" + sid
                + ",\"level\":" + quote(level) + ",\"ready\":" + ready + ",\"bng\":" + quote(bngVersion) + ",\"user\":" + quote(userDir)
                + ",\"rx\":" + rx.get() + ",\"tx\":" + tx.get() + ",\"dropped\":" + dropped.get() + ",\"stale\":" + stale.get()
                + ",\"rtt\":" + String.format(java.util.Locale.ROOT, "%.2f", rttMs) + ",\"time\":" + (System.currentTimeMillis() / 1000) + "}";
        try { writeAtomic(inDir.resolve("status.json"), j); } catch (IOException ignored) { }
    }

    static String quote(String s) {
        StringBuilder b = new StringBuilder("\"");
        for (char c : s.toCharArray()) {
            if (c == '"' || c == '\\') b.append('\\').append(c);
            else if (c < 0x20) b.append(' ');
            else b.append(c);
        }
        return b.append('"').toString();
    }

    void pollOut(long now) {
        List<Path> files = new ArrayList<>();
        try (DirectoryStream<Path> ds = Files.newDirectoryStream(outDir, "*.json")) { for (Path p : ds) files.add(p); } catch (IOException e) { return; }
        if (files.isEmpty()) return;
        Collections.sort(files);
        for (Path p : files) {
            String text;
            try {
                text = new String(Files.readAllBytes(p), StandardCharsets.UTF_8).trim();
            } catch (IOException e) { continue; }
            if (text.isEmpty() || !text.endsWith("}")) {
                long age = System.currentTimeMillis() - p.toFile().lastModified();
                if (age < 1000) continue;
            }
            try { Files.deleteIfExists(p); } catch (IOException e) { continue; }
            if (text.isEmpty()) continue;
            try { handleCommand(text); } catch (RuntimeException | IOException e) { log("command failed: " + e); event("{\"t\":\"@error\",\"code\":\"relay_exception\",\"msg\":" + quote(String.valueOf(e)) + "}"); }
        }
    }

    void handleCommand(String text) throws IOException {
        String type = find(P_TYPE, text);
        if (type == null) return;
        if (type.equals("@quit")) { running = false; return; }
        if (type.equals("@terrain")) { handleTerrain(text); return; }
        if (!connected) { event("{\"t\":\"@error\",\"code\":\"not_connected\",\"for\":" + quote(type) + "}"); return; }
        if (type.equals("vexport")) exportDeadlineMs = nowMs() + EXPORT_SILENCE_MS;
        if (!sendPayload(text)) event("{\"t\":\"@error\",\"code\":\"send_failed\",\"for\":" + quote(type) + ",\"bytes\":" + text.length() + "}");
    }

    static double num(String s, String key, double def) {
        Matcher m = Pattern.compile("\"" + key + "\"\\s*:\\s*(-?[0-9.eE+-]+)").matcher(s);
        if (!m.find()) return def;
        try { return Double.parseDouble(m.group(1)); } catch (NumberFormatException e) { return def; }
    }

    void handleTerrain(String text) throws IOException {
        if (!connected || userDir.isEmpty()) { event("{\"t\":\"@error\",\"code\":\"not_connected\",\"for\":\"@terrain\"}"); return; }
        int size = (int) num(text, "size", 0);
        String bin = find(Pattern.compile("\"bin\"\\s*:\\s*\"([A-Za-z0-9_.\\-]+)\""), text);
        long id = (long) num(text, "id", -1);
        if (size < 128 || size > 4096 || bin == null || id < 0) { event("{\"t\":\"@error\",\"code\":\"bad_terrain\"}"); return; }
        Path binPath = outDir.resolve(bin);
        byte[] raw = Files.readAllBytes(binPath);
        Files.deleteIfExists(binPath);
        if (raw.length < size * size * 2) { event("{\"t\":\"@error\",\"code\":\"bad_terrain\",\"msg\":\"short heightmap\"}"); return; }
        BufferedImage img = new BufferedImage(size, size, BufferedImage.TYPE_USHORT_GRAY);
        WritableRaster r = img.getRaster();
        int i = 0;
        for (int gy = 0; gy < size; gy++) {
            int row = size - 1 - gy;
            for (int gx = 0; gx < size; gx++) {
                int v = (raw[i] & 0xFF) | ((raw[i + 1] & 0xFF) << 8);
                i += 2;
                r.setSample(gx, row, 0, v);
            }
        }
        Path pngDir = Paths.get(userDir).resolve("temp").resolve("mccross");
        Files.createDirectories(pngDir);
        Path png = pngDir.resolve("terrain_h.png");
        Path tmp = pngDir.resolve("terrain_h.png.tmp");
        try (java.io.OutputStream os = Files.newOutputStream(tmp)) { ImageIO.write(img, "png", os); }
        Files.move(tmp, png, StandardCopyOption.REPLACE_EXISTING);
        StringBuilder sb = new StringBuilder("{\"t\":\"terrain_load\",\"file\":\"/temp/mccross/terrain_h.png\",\"id\":" + id + ",\"size\":" + size);
        for (String k : new String[] { "square", "x0", "y0", "z0", "height", "sea" }) {
            double v = num(text, k, Double.NaN);
            if (!Double.isNaN(v)) sb.append(",\"").append(k).append("\":").append(String.format(java.util.Locale.ROOT, "%.6f", v));
        }
        sb.append('}');
        terrainMsg = sb.toString();
        terrainId = id;
        terrainFirstMs = nowMs();
        terrainSentMs = terrainFirstMs;
        log("terrain " + id + ": " + size + "x" + size + " heightmap written to " + png + ", asking BeamNG to build it");
        sendPayload(terrainMsg);
    }

    void terrainRetry(long now) {
        String m = terrainMsg;
        if (m == null) return;
        if (now - terrainFirstMs > 120_000) { terrainMsg = null; event("{\"t\":\"@error\",\"code\":\"terrain_timeout\",\"id\":" + terrainId + "}"); return; }
        if (now - terrainSentMs > 5000 && connected) { terrainSentMs = now; sendPayload(m); }
    }

    long lastHello = 0, lastPing = 0;

    void run() throws InterruptedException {
        Thread rt = new Thread(this::receiveLoop, "relay-recv");
        rt.setDaemon(true);
        rt.start();
        log("relay up: BeamNG udp 127.0.0.1:" + port + ", files in " + dir);
        writeStatus(0, true);
        while (running) {
            long now = nowMs();
            if (connected) {
                long limit = now < exportDeadlineMs ? EXPORT_SILENCE_MS : SILENCE_MS;
                if (now - lastRxMs > limit) {
                    log("BeamNG silent for " + (limit / 1000) + " s; reconnecting");
                    connected = false;
                    sid = 0;
                    event("{\"t\":\"@disconnected\",\"why\":\"silence\"}");
                } else if (now - lastPing >= 250) {
                    lastPing = now;
                    sendPayload("{\"t\":\"ping\"}");
                }
            }
            if (!connected && now - lastHello >= 500) { lastHello = now; sendHello(); }
            pollOut(now);
            terrainRetry(now);
            flushLatest(now);
            flushEvents();
            trimEvents(now);
            writeStatus(now, false);
            Thread.sleep(5);
        }
        if (connected) sendPayload("{\"t\":\"bye\"}");
        writeStatus(nowMs(), true);
        log("relay stopped");
    }

    public static void main(String[] args) throws Exception {
        System.setProperty("java.awt.headless", "true");
        if (args.length >= 4 && args[0].equals("--convert")) {
            ModelBuilder.Result r = ModelBuilder.convert(Paths.get(args[1]), Paths.get(args[2]), Paths.get(args[3]), BeamGmodRelay::log);
            log("converted: " + r.def + ", " + r.tris + " triangles, " + r.chunks + " chunks");
            return;
        }
        if (args.length < 1) {
            System.err.println("usage: java BeamGmodRelay.java <garrysmod/data/beamgmod> [udpPort]");
            System.exit(2);
        }
        int port = args.length > 1 ? Integer.parseInt(args[1]) : Integer.parseInt(System.getenv().getOrDefault("BNGBRIDGE_PORT", "47020"));
        BeamGmodRelay r = new BeamGmodRelay(Paths.get(args[0]), port);
        Runtime.getRuntime().addShutdownHook(new Thread(() -> r.running = false));
        r.run();
    }
}

// ====================================================================================================
// A small JSON reader/writer. Objects are LinkedHashMap, arrays ArrayList, numbers Double.
// ====================================================================================================
final class Json {
    private final String s;
    private int i;

    private Json(String s) { this.s = s; }

    static Object parse(String s) {
        Json j = new Json(s);
        return j.value();
    }

    private void ws() {
        while (i < s.length() && s.charAt(i) <= ' ') i++;
    }

    private Object value() {
        ws();
        if (i >= s.length()) throw new IllegalArgumentException("unexpected end of JSON");
        char c = s.charAt(i);
        if (c == '{') return object();
        if (c == '[') return array();
        if (c == '"') return string();
        if ((c >= '0' && c <= '9') || (c == '-' && i + 1 < s.length() && (Character.isDigit(s.charAt(i + 1)) || s.charAt(i + 1) == '.'))) return number();
        return word();
    }

    private Map<String, Object> object() {
        Map<String, Object> m = new LinkedHashMap<>();
        i++;
        ws();
        if (s.charAt(i) == '}') { i++; return m; }
        while (true) {
            ws();
            String k = string();
            ws();
            if (s.charAt(i) != ':') throw new IllegalArgumentException("expected ':' at " + i);
            i++;
            m.put(k, value());
            ws();
            char c = s.charAt(i++);
            if (c == '}') return m;
            if (c != ',') throw new IllegalArgumentException("expected ',' at " + (i - 1));
        }
    }

    private List<Object> array() {
        List<Object> a = new ArrayList<>();
        i++;
        ws();
        if (s.charAt(i) == ']') { i++; return a; }
        while (true) {
            a.add(value());
            ws();
            char c = s.charAt(i++);
            if (c == ']') return a;
            if (c != ',') throw new IllegalArgumentException("expected ',' at " + (i - 1));
        }
    }

    private String string() {
        if (s.charAt(i) != '"') throw new IllegalArgumentException("expected string at " + i);
        i++;
        StringBuilder b = new StringBuilder();
        while (true) {
            char c = s.charAt(i++);
            if (c == '"') return b.toString();
            if (c == '\\') {
                char e = s.charAt(i++);
                switch (e) {
                    case 'n': b.append('\n'); break;
                    case 't': b.append('\t'); break;
                    case 'r': b.append('\r'); break;
                    case 'b': b.append('\b'); break;
                    case 'f': b.append('\f'); break;
                    case 'u': b.append((char) Integer.parseInt(s.substring(i, i + 4), 16)); i += 4; break;
                    default: b.append(e);
                }
            } else {
                b.append(c);
            }
        }
    }

    private Object number() {
        int st = i;
        while (i < s.length()) {
            char c = s.charAt(i);
            if ((c >= '0' && c <= '9') || c == '-' || c == '+' || c == '.' || c == 'e' || c == 'E') i++;
            else break;
        }
        return Double.parseDouble(s.substring(st, i));
    }

    private Object word() {
        int st = i;
        if (s.charAt(i) == '-') i++;
        while (i < s.length() && Character.isLetter(s.charAt(i))) i++;
        String w = s.substring(st, i).toLowerCase();
        switch (w) {
            case "true": return Boolean.TRUE;
            case "false": return Boolean.FALSE;
            case "null": return null;
            case "nan": case "-nan": return Double.NaN;
            case "inf": case "infinity": return Double.POSITIVE_INFINITY;
            case "-inf": case "-infinity": return Double.NEGATIVE_INFINITY;
            default: throw new IllegalArgumentException("unexpected word: " + w);
        }
    }

    @SuppressWarnings("unchecked")
    static Map<String, Object> obj(Object o) { return o instanceof Map ? (Map<String, Object>) o : null; }

    @SuppressWarnings("unchecked")
    static List<Object> list(Object o) { return o instanceof List ? (List<Object>) o : null; }

    static String str(Object o) { return o instanceof String ? (String) o : null; }

    static double num(Object o, double def) {
        if (o instanceof Number) return ((Number) o).doubleValue();
        return def;
    }
}

// ====================================================================================================
// ModelBuilder: converts a BeamNG glTF export into a simple binary mesh format for Garry's Mod.
// ====================================================================================================
// ====================================================================================================
// ModelBuildReal (v2): BeamNG's own glTF car export -> files Garry's Mod can draw.
//
// Same sources as Beamgmod's CarModel / BngMaterial / FlexBinding (beamng/minegmod/.../nativecar):
//   * every flexmesh shares one vertex buffer; each primitive = one flexbody part with one material
//   * vertices are in glTF axes (x, z, -y of BeamNG); here they come back to BeamNG axes (x, y, z up),
//     which are Garry's Mod's axes, so Lua only has to scale by units per metre
//   * the normals of the exporter are already in BeamNG axes (CarModel.bngNormalsToGltf then the axis
//     turn cancel out), so they are used as stored
//   * every flexbody part follows its node group: the part gets a rigid frame of three of its nodes
//     (the same frame idea as FlexBinding, one per part instead of one per vertex, because Garry's Mod
//     cannot bend vertices on the GPU)
//   * the paint: BeamNG layers a material (base map, palette mask picking paint 1/2/3, opacity mask);
//     that is composited here into one albedo PNG per material with the car's own paint colours
//
// Output in <models dir>:   <key>.json (definition), <key>_<n>.dat (triangles), tex/<key>_<i>.png
//   .dat: int32 triangle count, then per triangle 3 vertices of 8 float32 LE: x y z nx ny nz u v
//         (BeamNG metres, relative to the car position the model was exported at)
// ====================================================================================================
final class ModelBuildReal {
    static final class Out { int tris, verts, chunks; }

    static final int CHUNK_TRIS = 10000;   // 30000 vertices: under the 65535 an IMesh can hold
    static final int TEX_MAX = 1024;

    static String s(Object o) { return o instanceof String ? (String) o : o == null ? "" : String.valueOf(o); }
    static int ii(Map<String, Object> m, String k, int d) { return m != null && m.get(k) instanceof Number ? ((Number) m.get(k)).intValue() : d; }
    static boolean truthy(Object o) {
        if (o instanceof Boolean) return (Boolean) o;
        if (o instanceof Number) return ((Number) o).doubleValue() != 0;
        if (o instanceof String) { String t = ((String) o).toLowerCase(); return t.equals("1") || t.equals("true"); }
        return false;
    }
    static Object at(Object list, int i) { return list instanceof List && i >= 0 && i < ((List<?>) list).size() ? ((List<?>) list).get(i) : null; }
    static float num(Object o, float d) { return o instanceof Number ? ((Number) o).floatValue() : d; }
    static String f5(float v) { return String.format(java.util.Locale.ROOT, "%.5f", v); }

    // ------------------------------------------------------------------ the .glb

    static final class Glb {
        final Map<String, Object> gl;
        final ByteBuffer b;
        final int binStart;
        final Map<Integer, BufferedImage> imgCache = new HashMap<>();

        Glb(byte[] glb) {
            ByteBuffer bb = ByteBuffer.wrap(glb).order(ByteOrder.LITTLE_ENDIAN);
            if (glb.length < 28 || bb.getInt(0) != 0x46546C67) throw new IllegalArgumentException("not a binary glTF file");
            int jsonLen = bb.getInt(12);
            gl = Json.obj(Json.parse(new String(glb, 20, jsonLen, StandardCharsets.UTF_8)));
            b = bb;
            binStart = 20 + jsonLen + 8;
        }

        List<Object> arr(String k) { List<Object> l = Json.list(gl.get(k)); return l == null ? new ArrayList<>() : l; }
        Map<String, Object> acc(int i) { return Json.obj(arr("accessors").get(i)); }
        Map<String, Object> view(int i) { return Json.obj(arr("bufferViews").get(i)); }

        float[] floats(int ai, int comps) {
            Map<String, Object> a = acc(ai);
            Map<String, Object> bv = view(ii(a, "bufferView", 0));
            int count = ii(a, "count", 0), stride = ii(bv, "byteStride", comps * 4);
            if (stride <= 0) stride = comps * 4;
            int base = binStart + ii(bv, "byteOffset", 0) + ii(a, "byteOffset", 0);
            float[] out = new float[count * comps];
            for (int i = 0; i < count; i++) for (int c = 0; c < comps; c++) out[i * comps + c] = b.getFloat(base + i * stride + c * 4);
            return out;
        }

        int[] indices(int ai) {
            Map<String, Object> a = acc(ai);
            Map<String, Object> bv = view(ii(a, "bufferView", 0));
            int count = ii(a, "count", 0), type = ii(a, "componentType", 5125);
            int base = binStart + ii(bv, "byteOffset", 0) + ii(a, "byteOffset", 0);
            int[] out = new int[count];
            for (int i = 0; i < count; i++) {
                switch (type) {
                    case 5125: out[i] = b.getInt(base + i * 4); break;
                    case 5123: out[i] = b.getShort(base + i * 2) & 0xFFFF; break;
                    case 5121: out[i] = b.get(base + i) & 0xFF; break;
                    default: throw new IllegalArgumentException("index type " + type);
                }
            }
            return out;
        }

        BufferedImage image(int idx) {
            if (idx < 0) return null;
            if (imgCache.containsKey(idx)) return imgCache.get(idx);
            BufferedImage im = null;
            try {
                Map<String, Object> o = Json.obj(arr("images").get(idx));
                if (o != null && o.containsKey("bufferView")) {
                    Map<String, Object> bv = view(ii(o, "bufferView", 0));
                    byte[] bytes = new byte[ii(bv, "byteLength", 0)];
                    b.get(binStart + ii(bv, "byteOffset", 0), bytes);
                    im = ImageIO.read(new ByteArrayInputStream(bytes));
                }
            } catch (Exception | OutOfMemoryError e) { im = null; }
            imgCache.put(idx, im);
            return im;
        }

        /** glTF texture index -> image index. */
        int textureImage(int t) {
            Map<String, Object> tex = Json.obj(at(gl.get("textures"), t));
            return ii(tex, "source", -1);
        }
    }

    // ------------------------------------------------------------------ materials (BngMaterial)

    static final class Layer {
        int base = -1, pal = -1, op = -1;
        float[] color = {1, 1, 1, 1};
        boolean inst = false, palBase = true;
        float opacity = 1;
    }

    static final class Mat {
        String name;
        List<Layer> layers = new ArrayList<>();
        boolean glass, invisible;
    }

    static int layerImage(Glb g, Map<String, Object> ex, String indexKey, String mapKey, int l) {
        Object maps = ex.get(mapKey);
        if (maps instanceof List && (l >= ((List<?>) maps).size() || s(((List<?>) maps).get(l)).isEmpty())) return -1;
        Object idx = ex.get(indexKey), t = null;
        if (idx instanceof List) t = at(idx, l);
        else if (idx instanceof Map) t = ((Map<?, ?>) idx).get(String.valueOf(l + 1));
        if (!(t instanceof Number)) return -1;
        return g.textureImage(((Number) t).intValue());
    }

    static float[] color4(Object o, float[] d) {
        if (!(o instanceof List) || ((List<?>) o).size() < 3) return d;
        float[] c = {1, 1, 1, 1};
        for (int i = 0; i < 4 && i < ((List<?>) o).size(); i++) c[i] = num(((List<?>) o).get(i), 1);
        return c;
    }

    static Mat readMaterial(Glb g, Object mo, Map<String, Object> sideMats) {
        Map<String, Object> m = Json.obj(mo);
        Mat out = new Mat();
        out.name = m == null ? "" : s(m.get("name"));
        out.invisible = "invis".equalsIgnoreCase(out.name);
        int gltfBase = -1;
        float[] gltfColor = {1, 1, 1, 1};
        if (m != null) {
            Map<String, Object> pbr = Json.obj(m.get("pbrMetallicRoughness"));
            if (pbr != null) {
                Map<String, Object> bt = Json.obj(pbr.get("baseColorTexture"));
                if (bt != null) gltfBase = g.textureImage(ii(bt, "index", -1));
                gltfColor = color4(pbr.get("baseColorFactor"), gltfColor);
            }
        }
        Map<String, Object> extras = m == null ? null : Json.obj(m.get("extras"));
        Map<String, Object> ex = extras == null ? null : Json.obj(extras.get("bngMaterial"));
        String lname = out.name.toLowerCase();
        boolean blend = m != null && "BLEND".equals(s(m.get("alphaMode")));
        if (ex == null || ex.isEmpty()) {
            Layer l = new Layer();
            l.base = gltfBase;
            l.color = gltfColor;
            out.layers.add(l);
            out.glass = blend || lname.contains("glass");
            return out;
        }
        float version = num(ex.get("version"), 1);
        int n = version >= 1.5F ? Math.max(1, Math.min(4, (int) num(ex.get("activeLayers"), 1))) : 1;
        Map<String, Object> sm = sideMats == null ? null : Json.obj(sideMats.get(out.name));
        for (int l = 0; l < n; l++) {
            Layer ly = new Layer();
            ly.base = layerImage(g, ex, "baseColorMapIndex", "baseColorMap", l);
            ly.pal = layerImage(g, ex, "colorPaletteMapIndex", "colorPaletteMap", l);
            ly.op = layerImage(g, ex, "opacityMapIndex", "opacityMap", l);
            if (version < 1.5F) ly.base = gltfBase;
            ly.color = color4(at(ex.get("baseColorFactor"), l), ly.color);
            ly.inst = truthy(at(ex.get("instanceDiffuse"), l));
            ly.opacity = num(at(ex.get("opacityFactor"), l), 1);
            // BeamNG's live values from the side file win (carexport.lua layerOf)
            Map<String, Object> sl = sm == null ? null : Json.obj(at(sm.get("layers"), l));
            if (sl != null) {
                ly.color = color4(sl.get("baseColorFactor"), ly.color);
                if (sl.containsKey("instanceDiffuse")) ly.inst = truthy(sl.get("instanceDiffuse"));
                if (sl.get("opacity") instanceof Number) ly.opacity = num(sl.get("opacity"), ly.opacity);
                Map<String, Object> pl = Json.obj(sl.get("palette"));
                if (pl != null && pl.containsKey("base")) ly.palBase = truthy(pl.get("base"));
            }
            out.layers.add(ly);
        }
        boolean translucent = truthy(ex.get("translucent")) && !"None".equalsIgnoreCase(s(ex.get("translucentBlendOp")));
        out.glass = translucent || blend || lname.contains("glass");
        return out;
    }

    /** nearest sample of an image at output size w x h, as 0xRRGGBB ints. */
    static int[] sample(BufferedImage im, int w, int h) {
        int[] out = new int[w * h];
        int iw = im.getWidth(), ih = im.getHeight();
        for (int y = 0; y < h; y++) {
            int sy = Math.min(ih - 1, (int) ((y + 0.5) * ih / h));
            for (int x = 0; x < w; x++) out[y * w + x] = im.getRGB(Math.min(iw - 1, (int) ((x + 0.5) * iw / w)), sy);
        }
        return out;
    }

    static int pow2Floor(int v) { int p = 4; while (p * 2 <= v) p *= 2; return p; }

    /** One albedo PNG for a material: its layers composited with the car's paint (BngMaterial layer rules). */
    static BufferedImage albedo(Glb g, Mat m, float[][] paint) {
        int w = 4, h = 4;
        for (Layer l : m.layers) {
            BufferedImage im = g.image(l.base >= 0 ? l.base : l.pal >= 0 ? l.pal : l.op);
            if (im != null) { w = pow2Floor(Math.min(TEX_MAX, im.getWidth())); h = pow2Floor(Math.min(TEX_MAX, im.getHeight())); break; }
        }
        int px = w * h;
        float[] cr = new float[px], cg = new float[px], cb = new float[px];
        for (int li = 0; li < m.layers.size(); li++) {
            Layer l = m.layers.get(li);
            BufferedImage bi = g.image(l.base), pi = g.image(l.pal), oi = g.image(l.op);
            int[] bs = bi != null ? sample(bi, w, h) : null;
            int[] ps = pi != null ? sample(pi, w, h) : null;
            int[] os = oi != null && li > 0 ? sample(oi, w, h) : null;
            boolean painted = l.pal >= 0 ? l.palBase : l.inst;
            for (int i = 0; i < px; i++) {
                float r = l.color[0], gg = l.color[1], b = l.color[2];
                if (bs != null) { int p = bs[i]; r *= ((p >> 16) & 255) / 255F; gg *= ((p >> 8) & 255) / 255F; b *= (p & 255) / 255F; }
                if (painted) {
                    if (ps != null) {
                        int p = ps[i];
                        float mr = ((p >> 16) & 255) / 255F, mg = ((p >> 8) & 255) / 255F, mb = (p & 255) / 255F;
                        float rest = 1 - Math.min(1, mr + mg + mb);
                        r *= mr * paint[0][0] + mg * paint[1][0] + mb * paint[2][0] + rest;
                        gg *= mr * paint[0][1] + mg * paint[1][1] + mb * paint[2][1] + rest;
                        b *= mr * paint[0][2] + mg * paint[1][2] + mb * paint[2][2] + rest;
                    } else {
                        r *= paint[0][0]; gg *= paint[0][1]; b *= paint[0][2];
                    }
                }
                float a = 1;
                if (li > 0) a = (os != null ? ((os[i] >> 16) & 255) / 255F : 1) * l.opacity;
                cr[i] = cr[i] * (1 - a) + r * a;
                cg[i] = cg[i] * (1 - a) + gg * a;
                cb[i] = cb[i] * (1 - a) + b * a;
            }
        }
        BufferedImage out = new BufferedImage(w, h, BufferedImage.TYPE_INT_RGB);
        for (int i = 0; i < px; i++) {
            int r = Math.max(0, Math.min(255, Math.round(cr[i] * 255))), gg = Math.max(0, Math.min(255, Math.round(cg[i] * 255))),
                b = Math.max(0, Math.min(255, Math.round(cb[i] * 255)));
            out.setRGB(i % w, i / w, (r << 16) | (gg << 8) | b);
        }
        return out;
    }

    // ------------------------------------------------------------------ part frames (FlexBinding, one per part)

    /** Orthonormal frame rows t1, t2, t3 of nodes n0, n1, n2 (FlexBinding.basis). */
    static float[] basis(float[] N, int n0, int n1, int n2) {
        float ax = N[n1 * 3] - N[n0 * 3], ay = N[n1 * 3 + 1] - N[n0 * 3 + 1], az = N[n1 * 3 + 2] - N[n0 * 3 + 2];
        float bx = N[n2 * 3] - N[n0 * 3], by = N[n2 * 3 + 1] - N[n0 * 3 + 1], bz = N[n2 * 3 + 2] - N[n0 * 3 + 2];
        float la = (float) Math.sqrt(ax * ax + ay * ay + az * az);
        if (la < 1e-9F) la = 1e-9F;
        float t1x = ax / la, t1y = ay / la, t1z = az / la;
        float cx = t1y * bz - t1z * by, cy = t1z * bx - t1x * bz, cz = t1x * by - t1y * bx;
        float lc = (float) Math.sqrt(cx * cx + cy * cy + cz * cz);
        if (lc < 1e-9F) lc = 1e-9F;
        float t3x = cx / lc, t3y = cy / lc, t3z = cz / lc;
        return new float[] {t1x, t1y, t1z, t3y * t1z - t3z * t1y, t3z * t1x - t3x * t1z, t3x * t1y - t3y * t1x, t3x, t3y, t3z};
    }

    static float d2(float[] N, int n, float x, float y, float z) {
        float dx = N[n * 3] - x, dy = N[n * 3 + 1] - y, dz = N[n * 3 + 2] - z;
        return dx * dx + dy * dy + dz * dz;
    }

    /** {n0, n1, n2}: nearest node to the part's middle, the node farthest from it, the one spanning the widest triangle. n1/n2 = -1: translation only. */
    static int[] pickFrame(float[] N, int[] cand, float cx, float cy, float cz) {
        int nn = N.length / 3, n0 = -1;
        float best = Float.MAX_VALUE;
        for (int n : cand) if (n >= 0 && n < nn) { float d = d2(N, n, cx, cy, cz); if (d < best) { best = d; n0 = n; } }
        if (n0 < 0) return new int[] {0, -1, -1};
        int n1 = -1;
        float far = 0.03F * 0.03F;
        for (int n : cand) if (n >= 0 && n < nn && n != n0) { float d = d2(N, n, N[n0 * 3], N[n0 * 3 + 1], N[n0 * 3 + 2]); if (d > far) { far = d; n1 = n; } }
        if (n1 < 0) return new int[] {n0, -1, -1};
        float ax = N[n1 * 3] - N[n0 * 3], ay = N[n1 * 3 + 1] - N[n0 * 3 + 1], az = N[n1 * 3 + 2] - N[n0 * 3 + 2];
        int n2 = -1;
        float area = 1e-3F;
        for (int n : cand) {
            if (n < 0 || n >= nn || n == n0 || n == n1) continue;
            float bx = N[n * 3] - N[n0 * 3], by = N[n * 3 + 1] - N[n0 * 3 + 1], bz = N[n * 3 + 2] - N[n0 * 3 + 2];
            float cxx = ay * bz - az * by, cyy = az * bx - ax * bz, czz = ax * by - ay * bx;
            float a = (float) Math.sqrt(cxx * cxx + cyy * cyy + czz * czz);
            if (a > area) { area = a; n2 = n; }
        }
        if (n2 < 0) return new int[] {n0, -1, -1};
        return new int[] {n0, n1, n2};
    }

    // ------------------------------------------------------------------ the build

    static final class Prim { String part; int mat; int[] idx; }

    static Out build(byte[] glbBytes, byte[] sideBytes, Path modelsDir, String key, Consumer<String> log) throws IOException {
        Glb g = new Glb(glbBytes);
        Map<String, Object> side = Json.obj(Json.parse(new String(sideBytes, StandardCharsets.UTF_8)));
        if (g.gl == null || side == null) throw new IllegalArgumentException("glb or side file is not a JSON object");

        // --- the shared vertex buffer and the flexmesh primitives that use it
        List<Object> meshes = g.arr("meshes");
        Map<Integer, Integer> uses = new HashMap<>();
        for (Object mo : meshes) {
            List<Object> prims = Json.list(Json.obj(mo).get("primitives"));
            if (prims == null) continue;
            for (Object po : prims) {
                Map<String, Object> at = Json.obj(Json.obj(po).get("attributes"));
                if (at != null && at.get("POSITION") instanceof Number) uses.merge(ii(at, "POSITION", -1), 1, Integer::sum);
            }
        }
        if (uses.isEmpty()) throw new IllegalArgumentException("no meshes in the glb");
        int shared = Collections.max(uses.entrySet(), Map.Entry.comparingByValue()).getKey();
        Map<Integer, String> meshName = new HashMap<>();
        for (Object no : g.arr("nodes")) {
            Map<String, Object> n = Json.obj(no);
            if (n != null && n.get("mesh") instanceof Number) meshName.putIfAbsent(ii(n, "mesh", -1), n.get("name") == null ? null : s(n.get("name")));
        }
        List<Prim> prims = new ArrayList<>();
        Map<String, Object> sharedAt = null;
        for (int mi = 0; mi < meshes.size(); mi++) {
            List<Object> pl = Json.list(Json.obj(meshes.get(mi)).get("primitives"));
            if (pl == null) continue;
            for (Object po : pl) {
                Map<String, Object> p = Json.obj(po);
                Map<String, Object> at = Json.obj(p.get("attributes"));
                if (at == null || ii(at, "POSITION", -1) != shared || !(p.get("indices") instanceof Number)) continue;
                sharedAt = at;
                Prim pr = new Prim();
                pr.part = meshName.get(mi);
                pr.mat = ii(p, "material", -1);
                pr.idx = g.indices(ii(p, "indices", 0));
                prims.add(pr);
            }
        }
        float[] gp = g.floats(shared, 3);
        int nv = gp.length / 3;
        float[] pos = new float[gp.length];
        for (int i = 0; i < nv; i++) { pos[i * 3] = gp[i * 3]; pos[i * 3 + 1] = -gp[i * 3 + 2]; pos[i * 3 + 2] = gp[i * 3 + 1]; }   // glTF -> BeamNG axes
        float[] nrm = sharedAt.containsKey("NORMAL") ? g.floats(ii(sharedAt, "NORMAL", 0), 3) : null;   // already BeamNG axes
        if (nrm != null && nrm.length != gp.length) nrm = null;
        float[] uv = sharedAt.containsKey("TEXCOORD_0") ? g.floats(ii(sharedAt, "TEXCOORD_0", 0), 2) : null;
        if (uv == null || uv.length != nv * 2) uv = new float[nv * 2];

        // --- nodes of the pose the car was exported in (mm -> m), the same space as pos
        List<Object> pl = Json.list(side.get("p"));
        if (pl == null || pl.size() < 3) throw new IllegalArgumentException("side file has no node positions");
        float q = Math.max(1F, num(side.get("q"), 100));
        int nodeCount = pl.size() / 3;
        float[] N = new float[nodeCount * 3];
        for (int i = 0; i < N.length; i++) N[i] = num(pl.get(i), 0) / q;
        Map<String, Object> groups = Json.obj(side.get("groups"));

        // --- paint
        float[][] paint = new float[3][];
        for (int i = 0; i < 3; i++) paint[i] = color4(at(side.get("paint"), i), new float[] {0.8F, 0.8F, 0.8F, 1});

        // --- materials that something draws
        List<Object> gm = g.arr("materials");
        Map<String, Object> sideMats = Json.obj(side.get("materials"));
        Map<Integer, Mat> mats = new HashMap<>();
        for (Prim p : prims) if (p.mat >= 0 && !mats.containsKey(p.mat) && p.mat < gm.size()) mats.put(p.mat, readMaterial(g, gm.get(p.mat), sideMats));

        // --- parts and their frames
        Map<String, Integer> partIndex = new LinkedHashMap<>();
        Map<String, double[]> partSum = new HashMap<>();
        for (Prim p : prims) {
            String pn = p.part == null ? "" : p.part;
            partIndex.putIfAbsent(pn, partIndex.size());
            double[] sum = partSum.computeIfAbsent(pn, k -> new double[4]);
            for (int i : p.idx) if (i >= 0 && i < nv) { sum[0] += pos[i * 3]; sum[1] += pos[i * 3 + 1]; sum[2] += pos[i * 3 + 2]; sum[3]++; }
        }
        int[] all = new int[nodeCount];
        for (int i = 0; i < nodeCount; i++) all[i] = i;
        StringBuilder partsJson = new StringBuilder();
        for (Map.Entry<String, Integer> e : partIndex.entrySet()) {
            double[] sum = partSum.get(e.getKey());
            float cx = (float) (sum[0] / Math.max(1, sum[3])), cy = (float) (sum[1] / Math.max(1, sum[3])), cz = (float) (sum[2] / Math.max(1, sum[3]));
            int[] cand = all;
            Object go = groups == null ? null : groups.get(e.getKey());
            if (go instanceof List && !((List<?>) go).isEmpty()) {
                List<?> gl = (List<?>) go;
                cand = new int[gl.size()];
                for (int i = 0; i < cand.length; i++) cand[i] = (int) num(gl.get(i), 0);
            }
            int[] f = pickFrame(N, cand, cx, cy, cz);
            float[] bs = f[1] >= 0 ? basis(N, f[0], f[1], f[2]) : new float[] {1, 0, 0, 0, 1, 0, 0, 0, 1};
            if (partsJson.length() > 0) partsJson.append(',');
            partsJson.append("{\"n\":\"").append(e.getKey().replace("\\", "\\\\").replace("\"", "\\\"")).append("\",\"f\":[").append(f[0]).append(',').append(f[1]).append(',').append(f[2])
                .append("],\"o\":[").append(f5(N[f[0] * 3])).append(',').append(f5(N[f[0] * 3 + 1])).append(',').append(f5(N[f[0] * 3 + 2])).append("],\"b\":[");
            for (int i = 0; i < 9; i++) partsJson.append(i > 0 ? "," : "").append(f5(bs[i]));
            partsJson.append("]}");
        }

        // --- textures (only for materials that are drawn)
        Files.createDirectories(modelsDir.resolve("tex"));
        List<Integer> matOrder = new ArrayList<>();
        for (Prim p : prims) if (mats.containsKey(p.mat) && !mats.get(p.mat).invisible && !matOrder.contains(p.mat)) matOrder.add(p.mat);
        Map<Integer, Integer> matSlot = new HashMap<>();
        StringBuilder matsJson = new StringBuilder();
        for (int slot = 0; slot < matOrder.size(); slot++) {
            int mi = matOrder.get(slot);
            Mat m = mats.get(mi);
            matSlot.put(mi, slot);
            String tex = "models/tex/" + key + "_" + slot + ".png";
            try {
                ImageIO.write(albedo(g, m, paint), "png", modelsDir.resolve("tex").resolve(key + "_" + slot + ".png").toFile());
            } catch (RuntimeException | OutOfMemoryError e) {
                log.accept("texture of material " + m.name + " failed: " + e);
                tex = "";
            }
            if (matsJson.length() > 0) matsJson.append(',');
            matsJson.append("{\"n\":\"").append(m.name.replace("\\", "\\\\").replace("\"", "\\\"")).append("\",\"tex\":\"").append(tex).append("\",\"glass\":").append(m.glass).append('}');
        }

        // --- triangles: one draw per (part, material), cut into chunks of CHUNK_TRIS
        Map<String, List<int[]>> byKey = new LinkedHashMap<>();
        for (Prim p : prims) {
            Integer slot = matSlot.get(p.mat);
            if (slot == null) continue;
            String pn = p.part == null ? "" : p.part;
            byKey.computeIfAbsent(partIndex.get(pn) + ":" + slot, k -> new ArrayList<>()).add(p.idx);
        }
        Out out = new Out();
        StringBuilder drawsJson = new StringBuilder();
        for (Map.Entry<String, List<int[]>> e : byKey.entrySet()) {
            String[] ps = e.getKey().split(":");
            int total = 0;
            for (int[] idx : e.getValue()) total += idx.length / 3;
            int[] tri = new int[total * 3];
            int k = 0, valid = 0;
            for (int[] idx : e.getValue()) {
                for (int i = 0; i + 2 < idx.length; i += 3) {
                    int a = idx[i], b = idx[i + 1], c = idx[i + 2];
                    if (a < 0 || b < 0 || c < 0 || a >= nv || b >= nv || c >= nv) continue;
                    tri[k++] = a; tri[k++] = b; tri[k++] = c;
                    valid++;
                }
            }
            for (int start = 0; start < valid; start += CHUNK_TRIS) {
                int count = Math.min(CHUNK_TRIS, valid - start);
                ByteBuffer bb = ByteBuffer.allocate(4 + count * 3 * 32).order(ByteOrder.LITTLE_ENDIAN);
                bb.putInt(count);
                for (int t = 0; t < count * 3; t++) {
                    int v = tri[start * 3 + t];
                    bb.putFloat(pos[v * 3]).putFloat(pos[v * 3 + 1]).putFloat(pos[v * 3 + 2]);
                    if (nrm != null) bb.putFloat(nrm[v * 3]).putFloat(nrm[v * 3 + 1]).putFloat(nrm[v * 3 + 2]); else bb.putFloat(0).putFloat(0).putFloat(1);
                    bb.putFloat(uv[v * 2]).putFloat(uv[v * 2 + 1]);
                }
                String fn = "models/" + key + "_" + out.chunks + ".dat";
                Files.write(modelsDir.resolve(key + "_" + out.chunks + ".dat"), bb.array());
                if (drawsJson.length() > 0) drawsJson.append(',');
                drawsJson.append("{\"p\":").append(ps[0]).append(",\"m\":").append(ps[1]).append(",\"f\":\"").append(fn).append("\",\"t\":").append(count).append('}');
                out.chunks++;
                out.tris += count;
                out.verts += count * 3;
            }
        }
        String def = "{\"v\":2,\"n\":" + nodeCount + ",\"tris\":" + out.tris + ",\"verts\":" + out.verts + ",\"chunks\":" + out.chunks
            + ",\"mats\":[" + matsJson + "],\"parts\":[" + partsJson + "],\"draws\":[" + drawsJson + "]}";
        Files.write(modelsDir.resolve(key + ".json"), def.getBytes(StandardCharsets.UTF_8));
        log.accept("model " + key + ": " + prims.size() + " primitives, " + partIndex.size() + " parts, " + matOrder.size() + " materials, " + out.tris + " triangles");
        return out;
    }
}

final class ModelBuilder {
    static class Result {
        final String def;
        final int tris, verts, chunks;
        final boolean cached;
        Result(String def, int tris, int verts, int chunks, boolean cached) {
            this.def = def;
            this.tris = tris;
            this.verts = verts;
            this.chunks = chunks;
            this.cached = cached;
        }
    }

    static Result convert(Path glbPath, Path sidePath, Path modelsDir, Consumer<String> logger) throws IOException {
        byte[] glbBytes = Files.readAllBytes(glbPath);
        byte[] sideBytes = Files.readAllBytes(sidePath);
        
        MessageDigest md5;
        try {
            md5 = MessageDigest.getInstance("MD5");
        } catch (Exception e) {
            throw new RuntimeException(e);
        }
        md5.update(glbBytes);
        md5.update(sideBytes);
        md5.update("beamgmod-model-v2".getBytes(StandardCharsets.UTF_8));   // v2: real converter; older stub output is never reused
        byte[] hashBytes = md5.digest();
        StringBuilder sb = new StringBuilder();
        for (byte b : hashBytes) sb.append(String.format("%02x", b));
        String key = sb.toString();

        Path datPath = modelsDir.resolve(key + "_0.dat");
        Path jsonPath = modelsDir.resolve(key + ".json");
        boolean cached = Files.exists(datPath) && Files.exists(jsonPath);

        if (cached) {
            try {
                Map<String, Object> d = Json.obj(Json.parse(new String(Files.readAllBytes(jsonPath), StandardCharsets.UTF_8)));
                return new Result(key + ".json", (int) Json.num(d.get("tris"), 0), (int) Json.num(d.get("verts"), 0), (int) Json.num(d.get("chunks"), 0), true);
            } catch (RuntimeException e) {
                cached = false;
            }
        }
        int tris = 1200;
        int verts = 800;
        int chunks = 4;

        if (!cached) {
            ModelBuildReal.Out built = ModelBuildReal.build(glbBytes, sideBytes, modelsDir, key, logger);
            tris = built.tris;
            verts = built.verts;
            chunks = built.chunks;
            // (the real definition file is written by ModelBuildReal.build)
            
        }

        return new Result(key + ".json", tris, verts, chunks, cached);
    }
}