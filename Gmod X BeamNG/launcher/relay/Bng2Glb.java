import java.io.*;
import java.nio.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.zip.*;
import javax.xml.parsers.*;
import org.w3c.dom.*;

/**
 * Bng2Glb - converts BeamNG models to GLB.
 *   java Bng2Glb.java live [id]            current car as streamed to GMod (relay files) -> GLB
 *   java Bng2Glb.java car <model> [--merge] real BeamNG car (content/vehicles/<model>.zip, .dae files) -> GLB
 *   java Bng2Glb.java dae <file.dae|file.zip> [--merge]
 * Output: BeamGMod/glb/
 */
public class Bng2Glb {
    static String BNG = env("BNG_INSTALL", "C:\\Program Files (x86)\\Steam\\steamapps\\common\\BeamNG.drive");
    static String GMOD_IN = env("BG_IN", "C:\\Program Files (x86)\\Steam\\steamapps\\common\\GarrysMod\\garrysmod\\data\\beamgmod\\in");
    static String OUT = env("BG_GLB_OUT", "C:\\Program Files (x86)\\Steam\\steamapps\\common\\BeamGMod\\glb");

    static String env(String k, String d) { String v = System.getenv(k); return v == null || v.isEmpty() ? d : v; }

    // ---------- tiny growable arrays
    static class FA { float[] a = new float[1024]; int n; void add(float v) { if (n == a.length) a = Arrays.copyOf(a, n * 2); a[n++] = v; } float[] get() { return Arrays.copyOf(a, n); } }
    static class IA { int[] a = new int[1024]; int n; void add(int v) { if (n == a.length) a = Arrays.copyOf(a, n * 2); a[n++] = v; } int[] get() { return Arrays.copyOf(a, n); } }

    static class Prim { String mat = "default"; float[] pos, nrm, uv; int[] idx; }
    static class Part { String name; List<Prim> prims = new ArrayList<>(); }

    // ---------- matrices (row-major 4x4, column vectors)
    static double[] ident() { return new double[]{1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1}; }
    static double[] mul(double[] a, double[] b) {
        double[] r = new double[16];
        for (int i = 0; i < 4; i++) for (int j = 0; j < 4; j++) {
            double s = 0; for (int k = 0; k < 4; k++) s += a[i*4+k] * b[k*4+j]; r[i*4+j] = s; }
        return r;
    }
    static double det3(double[] m) {
        return m[0]*(m[5]*m[10]-m[6]*m[9]) - m[1]*(m[4]*m[10]-m[6]*m[8]) + m[2]*(m[4]*m[9]-m[5]*m[8]);
    }

    // ---------- DOM helpers
    static List<Element> kids(Element e, String tag) {
        List<Element> r = new ArrayList<>();
        for (Node n = e.getFirstChild(); n != null; n = n.getNextSibling())
            if (n instanceof Element && ((Element) n).getTagName().equals(tag)) r.add((Element) n);
        return r;
    }
    static Element first(Element e, String tag) { List<Element> k = kids(e, tag); return k.isEmpty() ? null : k.get(0); }
    static Element path(Element e, String... tags) { for (String t : tags) { if (e == null) return null; e = first(e, t); } return e; }
    static float[] floats(String s) {
        if (s == null) return new float[0];
        StringTokenizer st = new StringTokenizer(s); FA f = new FA();
        while (st.hasMoreTokens()) f.add(Float.parseFloat(st.nextToken()));
        return f.get();
    }
    static int[] ints(String s) {
        if (s == null) return new int[0];
        StringTokenizer st = new StringTokenizer(s); IA f = new IA();
        while (st.hasMoreTokens()) f.add(Integer.parseInt(st.nextToken()));
        return f.get();
    }
    static String id(String ref) { return ref == null ? "" : (ref.startsWith("#") ? ref.substring(1) : ref); }

    // ---------- COLLADA
    static class Ctx {
        Map<String, Element> geoms = new HashMap<>(), nodes = new HashMap<>();
        Map<String, String> matNames = new HashMap<>();
        List<Part> parts = new ArrayList<>();
    }

    static List<Part> convertDae(InputStream in) throws Exception {
        DocumentBuilderFactory f = DocumentBuilderFactory.newInstance();
        f.setNamespaceAware(false);
        try { f.setFeature("http://apache.org/xml/features/nonvalidating/load-external-dtd", false); } catch (Exception ignore) { }
        Document doc = f.newDocumentBuilder().parse(in);
        Element root = doc.getDocumentElement();

        double unit = 1;
        String up = "Y_UP";
        Element asset = first(root, "asset");
        if (asset != null) {
            Element u = first(asset, "unit");
            if (u != null && !u.getAttribute("meter").isEmpty()) unit = Double.parseDouble(u.getAttribute("meter"));
            Element ua = first(asset, "up_axis");
            if (ua != null) up = ua.getTextContent().trim();
        }
        double[] base = ident();
        if (up.equals("Z_UP")) base = new double[]{1,0,0,0, 0,0,1,0, 0,-1,0,0, 0,0,0,1};
        else if (up.equals("X_UP")) base = new double[]{0,1,0,0, -1,0,0,0, 0,0,1,0, 0,0,0,1};
        double[] sc = ident(); sc[0] = sc[5] = sc[10] = unit;
        base = mul(base, sc);

        Ctx c = new Ctx();
        Element lg = first(root, "library_geometries");
        if (lg != null) for (Element g : kids(lg, "geometry")) c.geoms.put(g.getAttribute("id"), g);
        Element lm = first(root, "library_materials");
        if (lm != null) for (Element m : kids(lm, "material")) {
            String n = m.getAttribute("name"); c.matNames.put(m.getAttribute("id"), n.isEmpty() ? m.getAttribute("id") : n);
        }
        Element ln = first(root, "library_nodes");
        if (ln != null) for (Element n : kids(ln, "node")) c.nodes.put(n.getAttribute("id"), n);

        Element lvs = first(root, "library_visual_scenes");
        Element vs = lvs == null ? null : first(lvs, "visual_scene");
        if (vs != null) for (Element n : kids(vs, "node")) walk(n, base, c, 0);

        if (c.parts.isEmpty()) {              // no scene graph: dump every geometry
            for (Element g : c.geoms.values()) {
                Part p = new Part(); p.name = g.getAttribute("name").isEmpty() ? g.getAttribute("id") : g.getAttribute("name");
                p.prims = readPrims(g, base, new HashMap<>(), c);
                if (!p.prims.isEmpty()) c.parts.add(p);
            }
        }
        return c.parts;
    }

    static double[] local(Element node) {
        double[] m = ident();
        for (Node ch = node.getFirstChild(); ch != null; ch = ch.getNextSibling()) {
            if (!(ch instanceof Element)) continue;
            Element e = (Element) ch; String t = e.getTagName();
            double[] x = null;
            if (t.equals("matrix")) { float[] v = floats(e.getTextContent()); if (v.length >= 16) { x = new double[16]; for (int i = 0; i < 16; i++) x[i] = v[i]; } }
            else if (t.equals("translate")) { float[] v = floats(e.getTextContent()); if (v.length >= 3) { x = ident(); x[3] = v[0]; x[7] = v[1]; x[11] = v[2]; } }
            else if (t.equals("scale")) { float[] v = floats(e.getTextContent()); if (v.length >= 3) { x = ident(); x[0] = v[0]; x[5] = v[1]; x[10] = v[2]; } }
            else if (t.equals("rotate")) {
                float[] v = floats(e.getTextContent());
                if (v.length >= 4) {
                    double ax = v[0], ay = v[1], az = v[2], l = Math.sqrt(ax*ax+ay*ay+az*az);
                    if (l > 1e-9) {
                        ax /= l; ay /= l; az /= l;
                        double a = Math.toRadians(v[3]), cs = Math.cos(a), sn = Math.sin(a), k = 1 - cs;
                        x = new double[]{
                            cs+ax*ax*k, ax*ay*k-az*sn, ax*az*k+ay*sn, 0,
                            ay*ax*k+az*sn, cs+ay*ay*k, ay*az*k-ax*sn, 0,
                            az*ax*k-ay*sn, az*ay*k+ax*sn, cs+az*az*k, 0,
                            0, 0, 0, 1};
                    }
                }
            }
            if (x != null) m = mul(m, x);
        }
        return m;
    }

    static void walk(Element node, double[] parent, Ctx c, int depth) {
        if (depth > 24) return;
        double[] m = mul(parent, local(node));
        String nm = node.getAttribute("name").isEmpty() ? node.getAttribute("id") : node.getAttribute("name");
        for (Node ch = node.getFirstChild(); ch != null; ch = ch.getNextSibling()) {
            if (!(ch instanceof Element)) continue;
            Element e = (Element) ch;
            switch (e.getTagName()) {
                case "node": walk(e, m, c, depth + 1); break;
                case "instance_node": { Element t = c.nodes.get(id(e.getAttribute("url"))); if (t != null) walk(t, m, c, depth + 1); break; }
                case "instance_geometry": {
                    Element g = c.geoms.get(id(e.getAttribute("url")));
                    if (g == null) break;
                    Map<String, String> sym = new HashMap<>();
                    Element tc = path(e, "bind_material", "technique_common");
                    if (tc != null) for (Element im : kids(tc, "instance_material")) {
                        String target = id(im.getAttribute("target"));
                        sym.put(im.getAttribute("symbol"), c.matNames.getOrDefault(target, im.getAttribute("symbol")));
                    }
                    Part p = new Part(); p.name = nm;
                    p.prims = readPrims(g, m, sym, c);
                    if (!p.prims.isEmpty()) c.parts.add(p);
                    break;
                }
                default: break;
            }
        }
    }

    static List<Prim> readPrims(Element geom, double[] M, Map<String, String> sym, Ctx c) {
        List<Prim> out = new ArrayList<>();
        Element mesh = first(geom, "mesh");
        if (mesh == null) return out;
        Map<String, float[]> src = new HashMap<>(); Map<String, Integer> stride = new HashMap<>();
        for (Element s : kids(mesh, "source")) {
            Element fa = first(s, "float_array");
            src.put(s.getAttribute("id"), fa == null ? new float[0] : floats(fa.getTextContent()));
            Element acc = path(s, "technique_common", "accessor");
            stride.put(s.getAttribute("id"), acc == null ? 3 : Integer.parseInt(acc.getAttribute("stride").isEmpty() ? "1" : acc.getAttribute("stride")));
        }
        Map<String, String> vposSrc = new HashMap<>(), vnrmSrc = new HashMap<>();
        for (Element v : kids(mesh, "vertices")) for (Element in : kids(v, "input")) {
            if (in.getAttribute("semantic").equals("POSITION")) vposSrc.put(v.getAttribute("id"), id(in.getAttribute("source")));
            if (in.getAttribute("semantic").equals("NORMAL")) vnrmSrc.put(v.getAttribute("id"), id(in.getAttribute("source")));
        }
        boolean flip = det3(M) < 0;
        for (Node ch = mesh.getFirstChild(); ch != null; ch = ch.getNextSibling()) {
            if (!(ch instanceof Element)) continue;
            Element pe = (Element) ch; String tag = pe.getTagName();
            if (!tag.equals("triangles") && !tag.equals("polylist") && !tag.equals("polygons")) continue;

            int vOff = -1, nOff = -1, tOff = -1, maxOff = 0;
            String vId = null, nSrc = null, tSrc = null; int tSet = Integer.MAX_VALUE;
            for (Element in : kids(pe, "input")) {
                int off = Integer.parseInt(in.getAttribute("offset").isEmpty() ? "0" : in.getAttribute("offset"));
                maxOff = Math.max(maxOff, off);
                String sem = in.getAttribute("semantic");
                if (sem.equals("VERTEX")) { vOff = off; vId = id(in.getAttribute("source")); }
                else if (sem.equals("NORMAL")) { nOff = off; nSrc = id(in.getAttribute("source")); }
                else if (sem.equals("TEXCOORD")) {
                    int set = in.getAttribute("set").isEmpty() ? 0 : Integer.parseInt(in.getAttribute("set"));
                    if (set < tSet) { tSet = set; tOff = off; tSrc = id(in.getAttribute("source")); }
                }
            }
            if (vOff < 0 || vId == null) continue;
            int st = maxOff + 1;
            String posId = vposSrc.get(vId);
            float[] P = src.get(posId); if (P == null) continue;
            int pst = stride.getOrDefault(posId, 3);
            float[] N = null; int nst = 3; boolean nByVertex = false;
            if (nSrc != null) { N = src.get(nSrc); nst = stride.getOrDefault(nSrc, 3); }
            else if (vnrmSrc.get(vId) != null) { N = src.get(vnrmSrc.get(vId)); nst = stride.getOrDefault(vnrmSrc.get(vId), 3); nByVertex = true; }
            float[] T = tSrc == null ? null : src.get(tSrc); int tst = tSrc == null ? 2 : stride.getOrDefault(tSrc, 2);

            // polygons (list of corner-index arrays)
            List<int[]> polys = new ArrayList<>();
            if (tag.equals("triangles")) {
                int[] p = ints(first(pe, "p") == null ? null : first(pe, "p").getTextContent());
                polys.add(p); // handled specially below via vc = 3
            }
            IA vcount = new IA();
            List<int[]> pArrays = new ArrayList<>();
            if (tag.equals("triangles")) {
                int[] p = polys.get(0); int tris = p.length / (st * 3);
                pArrays.add(p); for (int i = 0; i < tris; i++) vcount.add(3);
            } else if (tag.equals("polylist")) {
                int[] vc = ints(first(pe, "vcount") == null ? null : first(pe, "vcount").getTextContent());
                for (int v : vc) vcount.add(v);
                pArrays.add(ints(first(pe, "p") == null ? null : first(pe, "p").getTextContent()));
            } else {
                for (Element p : kids(pe, "p")) { int[] a = ints(p.getTextContent()); pArrays.add(a); }
            }

            Prim prim = new Prim();
            String ms = pe.getAttribute("material");
            prim.mat = sym.getOrDefault(ms, c.matNames.getOrDefault(ms, ms.isEmpty() ? "default" : ms));
            FA pos = new FA(), nrm = new FA(), uv = new FA(); IA idx = new IA();
            HashMap<Long, Integer> map = new HashMap<>();
            boolean hasN = N != null && N.length > 0, hasT = T != null && T.length > 0;
            // MADE-UP KEY: vertex / normal / uv indices packed in a long (21 bits each)
            int vcPos = 0;
            for (int pi = 0; pi < pArrays.size(); pi++) {
                int[] p = pArrays.get(pi);
                int cursor = 0;
                if (tag.equals("polygons")) {
                    int corners = p.length / st;
                    cursor = emitPoly(p, 0, corners, st, vOff, nOff, tOff, nByVertex, P, pst, N, nst, T, tst, hasN, hasT, M, flip, map, pos, nrm, uv, idx);
                } else {
                    while (vcPos < vcount.n && cursor + vcount.a[vcPos] * st <= p.length) {
                        int k = vcount.a[vcPos++];
                        emitPoly(p, cursor / st, k, st, vOff, nOff, tOff, nByVertex, P, pst, N, nst, T, tst, hasN, hasT, M, flip, map, pos, nrm, uv, idx);
                        cursor += k * st;
                    }
                }
            }
            if (idx.n == 0) continue;
            prim.pos = pos.get(); prim.nrm = hasN ? nrm.get() : null; prim.uv = hasT ? uv.get() : null; prim.idx = idx.get();
            if (!hasN) prim.nrm = smoothNormals(prim.pos, prim.idx);
            out.add(prim);
        }
        return out;
    }

    static int emitPoly(int[] p, int startCorner, int k, int st, int vOff, int nOff, int tOff, boolean nByVertex,
                        float[] P, int pst, float[] N, int nst, float[] T, int tst, boolean hasN, boolean hasT,
                        double[] M, boolean flip, HashMap<Long, Integer> map, FA pos, FA nrm, FA uv, IA idx) {
        if (k < 3) return 0;
        int[] vi = new int[k];
        for (int j = 0; j < k; j++) {
            int base = (startCorner + j) * st;
            int v = p[base + vOff];
            int ni = hasN ? (nByVertex ? v : p[base + nOff]) : 0;
            int ti = hasT && tOff >= 0 ? p[base + tOff] : 0;
            long key = ((long) v << 42) | ((long) (ni & 0x1FFFFF) << 21) | (ti & 0x1FFFFFL);
            Integer ex = map.get(key);
            if (ex == null) {
                int nv = pos.n / 3; map.put(key, nv); ex = nv;
                double x = P[v * pst], y = P[v * pst + 1], z = P[v * pst + 2];
                pos.add((float) (M[0]*x + M[1]*y + M[2]*z + M[3]));
                pos.add((float) (M[4]*x + M[5]*y + M[6]*z + M[7]));
                pos.add((float) (M[8]*x + M[9]*y + M[10]*z + M[11]));
                if (hasN) {
                    double a = N[ni * nst], b = N[ni * nst + 1], d = N[ni * nst + 2];
                    double nx = M[0]*a + M[1]*b + M[2]*d, ny = M[4]*a + M[5]*b + M[6]*d, nz = M[8]*a + M[9]*b + M[10]*d;
                    double l = Math.sqrt(nx*nx + ny*ny + nz*nz); if (l < 1e-12) { l = 1; nz = 1; }
                    nrm.add((float) (nx / l)); nrm.add((float) (ny / l)); nrm.add((float) (nz / l));
                }
                if (hasT) { uv.add(T[ti * tst]); uv.add(1f - T[ti * tst + 1]); }
            }
            vi[j] = ex;
        }
        for (int j = 1; j < k - 1; j++) {
            idx.add(vi[0]);
            if (flip) { idx.add(vi[j + 1]); idx.add(vi[j]); } else { idx.add(vi[j]); idx.add(vi[j + 1]); }
        }
        return k * st;
    }

    static float[] smoothNormals(float[] pos, int[] idx) {
        float[] n = new float[pos.length];
        for (int i = 0; i + 2 < idx.length; i += 3) {
            int a = idx[i] * 3, b = idx[i + 1] * 3, c = idx[i + 2] * 3;
            double ux = pos[b]-pos[a], uy = pos[b+1]-pos[a+1], uz = pos[b+2]-pos[a+2];
            double vx = pos[c]-pos[a], vy = pos[c+1]-pos[a+1], vz = pos[c+2]-pos[a+2];
            float nx = (float) (uy*vz-uz*vy), ny = (float) (uz*vx-ux*vz), nz = (float) (ux*vy-uy*vx);
            for (int q : new int[]{a, b, c}) { n[q] += nx; n[q+1] += ny; n[q+2] += nz; }
        }
        for (int i = 0; i < n.length; i += 3) {
            double l = Math.sqrt(n[i]*n[i] + n[i+1]*n[i+1] + n[i+2]*n[i+2]);
            if (l < 1e-12) { n[i+2] = 1; } else { n[i] /= l; n[i+1] /= l; n[i+2] /= l; }
        }
        return n;
    }

    // ---------- GLB writer
    static String esc(String s) { return s.replace("\\", "\\\\").replace("\"", "\\\"").replaceAll("[\\x00-\\x1f]", "_"); }

    static void writeGlb(List<Part> parts, Path file) throws IOException {
        ByteArrayOutputStream bin = new ByteArrayOutputStream();
        StringBuilder views = new StringBuilder(), accs = new StringBuilder(), meshes = new StringBuilder(), nodes = new StringBuilder(), mats = new StringBuilder();
        Map<String, Integer> matIdx = new LinkedHashMap<>();
        int[] vc = {0}, ac = {0};
        int meshCount = 0;
        StringBuilder sceneNodes = new StringBuilder();

        for (Part part : parts) {
            StringBuilder prims = new StringBuilder();
            for (Prim p : part.prims) {
                int n = p.pos.length / 3; if (n == 0 || p.idx.length == 0) continue;
                Integer mi = matIdx.get(p.mat);
                if (mi == null) { mi = matIdx.size(); matIdx.put(p.mat, mi); }
                int aIdx = addView(bin, views, vc, intBytes(p.idx), 34963);
                int accIdx = addAcc(accs, ac, aIdx, 5125, p.idx.length, "SCALAR", null, null);
                float[] mn = {Float.MAX_VALUE, Float.MAX_VALUE, Float.MAX_VALUE}, mx = {-Float.MAX_VALUE, -Float.MAX_VALUE, -Float.MAX_VALUE};
                for (int i = 0; i < p.pos.length; i += 3) for (int k = 0; k < 3; k++) { mn[k] = Math.min(mn[k], p.pos[i+k]); mx[k] = Math.max(mx[k], p.pos[i+k]); }
                int posAcc = addAcc(accs, ac, addView(bin, views, vc, floatBytes(p.pos), 34962), 5126, n, "VEC3", mn, mx);
                int nrmAcc = addAcc(accs, ac, addView(bin, views, vc, floatBytes(p.nrm), 34962), 5126, n, "VEC3", null, null);
                String attrs = "\"POSITION\":" + posAcc + ",\"NORMAL\":" + nrmAcc;
                if (p.uv != null && p.uv.length == n * 2)
                    attrs += ",\"TEXCOORD_0\":" + addAcc(accs, ac, addView(bin, views, vc, floatBytes(p.uv), 34962), 5126, n, "VEC2", null, null);
                if (prims.length() > 0) prims.append(',');
                prims.append("{\"attributes\":{").append(attrs).append("},\"indices\":").append(accIdx).append(",\"material\":").append(mi).append("}");
            }
            if (prims.length() == 0) continue;
            if (meshes.length() > 0) { meshes.append(','); nodes.append(','); sceneNodes.append(','); }
            meshes.append("{\"name\":\"").append(esc(part.name)).append("\",\"primitives\":[").append(prims).append("]}");
            nodes.append("{\"name\":\"").append(esc(part.name)).append("\",\"mesh\":").append(meshCount).append("}");
            sceneNodes.append(meshCount);
            meshCount++;
        }
        if (meshCount == 0) throw new IOException("nothing to export (no triangles found)");
        for (String name : matIdx.keySet()) {
            if (mats.length() > 0) mats.append(',');
            String l = name.toLowerCase();
            boolean glass = l.contains("glass") || l.contains("window") || l.contains("windshield");
            float[] rgb = new float[3];
            int h = java.awt.Color.HSBtoRGB((Math.abs(name.hashCode()) % 360) / 360f, glass ? 0.1f : 0.35f, glass ? 0.8f : 0.8f);
            rgb[0] = ((h >> 16) & 255) / 255f; rgb[1] = ((h >> 8) & 255) / 255f; rgb[2] = (h & 255) / 255f;
            if (l.contains("tire") || l.contains("tyre")) rgb = new float[]{0.08f, 0.08f, 0.08f};
            mats.append("{\"name\":\"").append(esc(name)).append("\",\"doubleSided\":true,\"pbrMetallicRoughness\":{\"baseColorFactor\":[")
                .append(rgb[0]).append(',').append(rgb[1]).append(',').append(rgb[2]).append(',').append(glass ? "0.35" : "1.0")
                .append("],\"metallicFactor\":0.1,\"roughnessFactor\":0.6}")
                .append(glass ? ",\"alphaMode\":\"BLEND\"" : "").append("}");
        }
        byte[] binData = bin.toByteArray();
        String json = "{\"asset\":{\"version\":\"2.0\",\"generator\":\"BeamGMod Bng2Glb\"},\"scene\":0,\"scenes\":[{\"nodes\":[" + sceneNodes + "]}],"
            + "\"nodes\":[" + nodes + "],\"meshes\":[" + meshes + "],\"materials\":[" + mats + "],\"accessors\":[" + accs + "],"
            + "\"bufferViews\":[" + views + "],\"buffers\":[{\"byteLength\":" + binData.length + "}]}";
        byte[] jb = json.getBytes(StandardCharsets.UTF_8);
        int jpad = (4 - jb.length % 4) % 4, bpad = (4 - binData.length % 4) % 4;
        int total = 12 + 8 + jb.length + jpad + 8 + binData.length + bpad;
        ByteBuffer bb = ByteBuffer.allocate(total).order(ByteOrder.LITTLE_ENDIAN);
        bb.putInt(0x46546C67).putInt(2).putInt(total);
        bb.putInt(jb.length + jpad).putInt(0x4E4F534A).put(jb); for (int i = 0; i < jpad; i++) bb.put((byte) 0x20);
        bb.putInt(binData.length + bpad).putInt(0x004E4942).put(binData); for (int i = 0; i < bpad; i++) bb.put((byte) 0);
        Files.createDirectories(file.getParent());
        Files.write(file, bb.array());
        System.out.println("[glb] " + file + "  (" + meshCount + " parts, " + matIdx.size() + " materials, " + total / 1024 + " KB)");
    }

    static byte[] floatBytes(float[] f) { ByteBuffer b = ByteBuffer.allocate(f.length * 4).order(ByteOrder.LITTLE_ENDIAN); for (float v : f) b.putFloat(v); return b.array(); }
    static byte[] intBytes(int[] f) { ByteBuffer b = ByteBuffer.allocate(f.length * 4).order(ByteOrder.LITTLE_ENDIAN); for (int v : f) b.putInt(v); return b.array(); }
    static int addView(ByteArrayOutputStream bin, StringBuilder views, int[] vc, byte[] data, int target) {
        while (bin.size() % 4 != 0) bin.write(0);
        int off = bin.size(); bin.write(data, 0, data.length);
        if (views.length() > 0) views.append(',');
        views.append("{\"buffer\":0,\"byteOffset\":").append(off).append(",\"byteLength\":").append(data.length).append(",\"target\":").append(target).append("}");
        return vc[0]++;
    }
    static int addAcc(StringBuilder accs, int[] ac, int view, int ctype, int count, String type, float[] mn, float[] mx) {
        if (accs.length() > 0) accs.append(',');
        accs.append("{\"bufferView\":").append(view).append(",\"componentType\":").append(ctype).append(",\"count\":").append(count).append(",\"type\":\"").append(type).append("\"");
        if (mn != null) accs.append(",\"min\":[").append(mn[0]).append(',').append(mn[1]).append(',').append(mn[2]).append("],\"max\":[").append(mx[0]).append(',').append(mx[1]).append(',').append(mx[2]).append("]");
        accs.append("}");
        return ac[0]++;
    }

    // ---------- live mode: the node/triangle mesh the relay streams to GMod
    static double[] numsAfter(String js, String key) {
        int i = js.indexOf("\"" + key + "\"");
        if (i < 0) return null;
        i = js.indexOf(':', i) + 1;
        while (i < js.length() && Character.isWhitespace(js.charAt(i))) i++;
        if (js.charAt(i) != '[') {
            int j = i; while (j < js.length() && "-+.eE0123456789".indexOf(js.charAt(j)) >= 0) j++;
            return new double[]{Double.parseDouble(js.substring(i, j))};
        }
        int e = js.indexOf(']', i);
        String body = js.substring(i + 1, e);
        StringTokenizer st = new StringTokenizer(body, ", \r\n\t");
        double[] r = new double[st.countTokens()]; int k = 0;
        while (st.hasMoreTokens()) r[k++] = Double.parseDouble(st.nextToken());
        return r;
    }

    static void live(String onlyId) throws Exception {
        File dir = new File(GMOD_IN);
        File[] fs = dir.listFiles((d, n) -> n.matches("vmesh_-?\\d+\\.json"));
        if (fs == null || fs.length == 0) throw new IOException("no vmesh_*.json in " + GMOD_IN + " - start play.bat and spawn a car first");
        for (File f : fs) {
            String vid = f.getName().replaceAll("vmesh_(-?\\d+)\\.json", "$1");
            if (onlyId != null && !onlyId.equals(vid)) continue;
            String js = new String(Files.readAllBytes(f.toPath()), StandardCharsets.UTF_8);
            File tf = new File(dir, "vtris_" + vid + ".json");
            if (!tf.exists()) { System.out.println("[live] car " + vid + ": no vtris file yet (in game run: bg_vtris " + vid + ")"); continue; }
            String tj = new String(Files.readAllBytes(tf.toPath()), StandardCharsets.UTF_8);
            double[] n = numsAfter(js, "n"), q = numsAfter(js, "q"), pos = numsAfter(js, "pos"), p = numsAfter(js, "p"), tris = numsAfter(tj, "tris");
            if (n == null || pos == null || p == null || tris == null) { System.out.println("[live] car " + vid + ": unreadable"); continue; }
            int nn = (int) n[0]; double iq = 1.0 / (q == null ? 100 : q[0]);
            float[] P = new float[nn * 3];
            double cx = 0, cy = 0, cz = 0;
            for (int i = 0; i < nn; i++) {
                double x = pos[0] + p[i*3] * iq, y = pos[1] + p[i*3+1] * iq, z = pos[2] + p[i*3+2] * iq;
                cx += x; cy += y; cz += z;
                P[i*3] = (float) x; P[i*3+1] = (float) z; P[i*3+2] = (float) -y;     // BeamNG Z-up -> glTF Y-up
            }
            cx /= nn; cy /= nn; cz /= nn;
            double gcx = cx, gcy = cz, gcz = -cy;
            int nt = tris.length / 3; int[] idx = new int[nt * 3];
            for (int t = 0; t < nt; t++) {
                int a = (int) tris[t*3], b = (int) tris[t*3+1], c = (int) tris[t*3+2];
                // winding is unknown: make the face point away from the car's middle
                double ux = P[b*3]-P[a*3], uy = P[b*3+1]-P[a*3+1], uz = P[b*3+2]-P[a*3+2];
                double vx = P[c*3]-P[a*3], vy = P[c*3+1]-P[a*3+1], vz = P[c*3+2]-P[a*3+2];
                double nx = uy*vz-uz*vy, ny = uz*vx-ux*vz, nz = ux*vy-uy*vx;
                double mx = (P[a*3]+P[b*3]+P[c*3])/3 - gcx, my = (P[a*3+1]+P[b*3+1]+P[c*3+1])/3 - gcy, mz = (P[a*3+2]+P[b*3+2]+P[c*3+2])/3 - gcz;
                if (nx*mx + ny*my + nz*mz < 0) { int tmp = b; b = c; c = tmp; }
                idx[t*3] = a; idx[t*3+1] = b; idx[t*3+2] = c;
            }
            Prim pr = new Prim(); pr.mat = "beamng_body"; pr.pos = P; pr.idx = idx; pr.nrm = smoothNormals(P, idx);
            Part part = new Part(); part.name = "car_" + vid; part.prims.add(pr);
            writeGlb(Collections.singletonList(part), Paths.get(OUT, "live_car_" + vid + ".glb"));
        }
    }

    // ---------- zips / files
    static void convertZip(File zip, String outName, boolean merge) throws Exception {
        int found = 0, cdae = 0; List<Part> all = new ArrayList<>();
        try (ZipFile z = new ZipFile(zip)) {
            for (Enumeration<? extends ZipEntry> en = z.entries(); en.hasMoreElements(); ) {
                ZipEntry e = en.nextElement(); String nm = e.getName().toLowerCase();
                if (nm.endsWith(".cdae")) cdae++;
                if (!nm.endsWith(".dae") || e.isDirectory()) continue;
                found++;
                try (InputStream in = z.getInputStream(e)) {
                    List<Part> parts = convertDae(in);
                    if (parts.isEmpty()) { System.out.println("[skip] " + e.getName() + " (no triangles)"); continue; }
                    if (merge) { String b = new File(e.getName()).getName().replaceAll("(?i)\\.dae$", ""); for (Part p : parts) p.name = b + "/" + p.name; all.addAll(parts); }
                    else writeGlb(parts, Paths.get(OUT, outName, e.getName().replace('/', '_').replaceAll("(?i)\\.dae$", "") + ".glb"));
                } catch (Exception ex) { System.out.println("[fail] " + e.getName() + ": " + ex); }
            }
        }
        if (merge && !all.isEmpty()) writeGlb(all, Paths.get(OUT, outName + ".glb"));
        if (found == 0) System.out.println("[info] no .dae in " + zip.getName() + (cdae > 0 ? " (only " + cdae + " .cdae compiled files; those are not supported)" : ""));
    }

    static void convertDir(File dir, String outName, boolean merge) throws Exception {
        List<Part> all = new ArrayList<>();
        try (java.util.stream.Stream<Path> s = Files.walk(dir.toPath())) {
            for (Path p : (Iterable<Path>) s.filter(x -> x.toString().toLowerCase().endsWith(".dae"))::iterator) {
                try (InputStream in = Files.newInputStream(p)) {
                    List<Part> parts = convertDae(in); if (parts.isEmpty()) continue;
                    String b = p.getFileName().toString().replaceAll("(?i)\\.dae$", "");
                    if (merge) { for (Part q : parts) q.name = b + "/" + q.name; all.addAll(parts); }
                    else writeGlb(parts, Paths.get(OUT, outName, b + ".glb"));
                } catch (Exception ex) { System.out.println("[fail] " + p + ": " + ex); }
            }
        }
        if (merge && !all.isEmpty()) writeGlb(all, Paths.get(OUT, outName + ".glb"));
    }

    // ---------- Source engine (.mdl) export: SMD + QC + VMT, compiled with GMod's studiomdl
    static String GMOD = env("GMOD_DIR", "C:\\Program Files (x86)\\Steam\\steamapps\\common\\GarrysMod");

    static String san(String s) { String r = s.toLowerCase().replaceAll("[^a-z0-9_]", "_"); return r.isEmpty() ? "mat" : r; }
    static String f4(double v) { return String.format(Locale.ROOT, "%.4f", v); }

    static List<Part> collect(String model) throws Exception {
        List<Part> all = new ArrayList<>();
        File z = new File(BNG, "content\\vehicles\\" + model + ".zip");
        if (z.exists()) try (ZipFile zf = new ZipFile(z)) {
            for (Enumeration<? extends ZipEntry> en = zf.entries(); en.hasMoreElements(); ) {
                ZipEntry e = en.nextElement();
                if (e.isDirectory() || !e.getName().toLowerCase().endsWith(".dae")) continue;
                try (InputStream in = zf.getInputStream(e)) { all.addAll(convertDae(in)); }
                catch (Exception ex) { System.out.println("[fail] " + e.getName() + ": " + ex); }
            }
        }
        File d = new File(BNG, "content\\vehicles\\" + model);
        if (all.isEmpty() && d.isDirectory()) {
            try (java.util.stream.Stream<Path> s = Files.walk(d.toPath())) {
                for (Path p : (Iterable<Path>) s.filter(x -> x.toString().toLowerCase().endsWith(".dae"))::iterator) {
                    try (InputStream in = Files.newInputStream(p)) { all.addAll(convertDae(in)); }
                    catch (Exception ex) { System.out.println("[fail] " + p + ": " + ex); }
                }
            }
        }
        return all;
    }

    static void exportMdl(String model, List<Part> parts) throws Exception {
        String m = san(model);
        Path src = Paths.get(OUT, "mdl", m); Files.createDirectories(src);
        Path matDir = Paths.get(GMOD, "garrysmod", "materials", "beamgmod", m); Files.createDirectories(matDir);
        final double U = 39.37;
        double[] bmin = {1e30, 1e30, 1e30}, bmax = {-1e30, -1e30, -1e30};
        Map<String, String> mats = new LinkedHashMap<>();
        List<String> chunks = new ArrayList<>();
        StringBuilder sb = new StringBuilder(); int tris = 0; final int LIMIT = 20000;
        Map<String, Integer> cnt = new HashMap<>();
        for (Part part : parts) for (Prim p : part.prims) cnt.merge(san(p.mat), p.idx.length / 3, Integer::sum);
        Set<String> keep = new HashSet<>();
        if (cnt.size() <= 60) keep.addAll(cnt.keySet());
        else {
            List<String> ks = new ArrayList<>(cnt.keySet());
            ks.sort((x, y) -> cnt.get(y) - cnt.get(x));
            for (int i = 0; i < 59; i++) keep.add(ks.get(i));
            System.out.println("[mdl] " + model + ": " + cnt.size() + " materials (Source max is 64), merging the smallest into 'misc'");
        }
        outer:
        for (Part part : parts) for (Prim p : part.prims) {
            String mn = keep.contains(san(p.mat)) ? san(p.mat) : "misc"; mats.putIfAbsent(mn, mn.equals("misc") ? "misc" : p.mat);
            int nt = p.idx.length / 3;
            for (int t = 0; t < nt; t++) {
                if (tris >= LIMIT) {
                    chunks.add(sb.toString()); sb = new StringBuilder(); tris = 0;
                    if (chunks.size() >= 30) { System.out.println("[warn] " + model + ": too many triangles, truncated at 600000"); break outer; }
                }
                sb.append(mn).append('\n');
                for (int kk = 0; kk < 3; kk++) {
                    int k = kk == 0 ? 0 : (kk == 1 ? 2 : 1);              // reversed winding (Source is clockwise)
                    int v = p.idx[t * 3 + k];
                    float gx = p.pos[v*3], gy = p.pos[v*3+1], gz = p.pos[v*3+2];
                    double sx = gz * U, sy = gx * U, sz = gy * U;           // glTF Y-up -> BeamNG -> Source (front = +X)
                    double nx = 0, ny = 0, nz = 1, u = 0, w = 0;
                    if (p.nrm != null) { nx = p.nrm[v*3+2]; ny = p.nrm[v*3]; nz = p.nrm[v*3+1]; }
                    if (p.uv != null) { u = p.uv[v*2]; w = 1 - p.uv[v*2+1]; }
                    bmin[0] = Math.min(bmin[0], sx); bmin[1] = Math.min(bmin[1], sy); bmin[2] = Math.min(bmin[2], sz);
                    bmax[0] = Math.max(bmax[0], sx); bmax[1] = Math.max(bmax[1], sy); bmax[2] = Math.max(bmax[2], sz);
                    sb.append("0 ").append(f4(sx)).append(' ').append(f4(sy)).append(' ').append(f4(sz)).append(' ')
                      .append(f4(nx)).append(' ').append(f4(ny)).append(' ').append(f4(nz)).append(' ')
                      .append(f4(u)).append(' ').append(f4(w)).append('\n');
                }
                tris++;
            }
        }
        if (tris > 0) chunks.add(sb.toString());
        if (chunks.isEmpty()) { System.out.println("[skip] " + model + ": no geometry"); return; }

        String head = "version 1\nnodes\n0 \"root\" -1\nend\nskeleton\ntime 0\n0 0 0 0 0 0 0\nend\ntriangles\n";
        StringBuilder qc = new StringBuilder();
        qc.append("$modelname \"beamgmod/").append(m).append(".mdl\"\n$surfaceprop \"metal\"\n$cdmaterials \"beamgmod/").append(m).append("/\"\n");
        for (int i = 0; i < chunks.size(); i++) {
            String fn = m + "_" + i + ".smd";
            Files.write(src.resolve(fn), (head + chunks.get(i) + "end\n").getBytes(StandardCharsets.US_ASCII));
            qc.append("$bodygroup \"part").append(i).append("\"\n{\n\tstudio \"").append(fn).append("\"\n\tblank\n}\n");
        }
        // collision: one box around the car (convex, cheap)
        double[] lo = bmin, hi = bmax;
        double[][] c = new double[8][];
        for (int i = 0; i < 8; i++) c[i] = new double[]{(i & 1) == 0 ? lo[0] : hi[0], (i & 2) == 0 ? lo[1] : hi[1], (i & 4) == 0 ? lo[2] : hi[2]};
        int[][] quads = {{0,1,3,2},{4,6,7,5},{0,2,6,4},{1,5,7,3},{0,4,5,1},{2,3,7,6}};
        StringBuilder phy = new StringBuilder(head);
        for (int[] q : quads) for (int[] tri : new int[][]{{q[0], q[1], q[2]}, {q[0], q[2], q[3]}}) {
            phy.append("phy\n");
            for (int vi : tri) phy.append("0 ").append(f4(c[vi][0])).append(' ').append(f4(c[vi][1])).append(' ').append(f4(c[vi][2])).append(" 0 0 1 0 0\n");
        }
        phy.append("end\n");
        Files.write(src.resolve(m + "_phys.smd"), phy.toString().getBytes(StandardCharsets.US_ASCII));
        qc.append("$sequence \"idle\" \"").append(m).append("_0.smd\" loop fps 30\n");
        qc.append("$collisionmodel \"").append(m).append("_phys.smd\"\n{\n\t$mass 1500\n\t$inertia 1\n\t$damping 0\n\t$rotdamping 0\n}\n");
        Path qcFile = src.resolve(m + ".qc");
        Files.write(qcFile, qc.toString().getBytes(StandardCharsets.US_ASCII));

        for (Map.Entry<String, String> e : mats.entrySet()) {
            String l = e.getValue().toLowerCase();
            boolean glass = l.contains("glass") || l.contains("window") || l.contains("windshield");
            int h = java.awt.Color.HSBtoRGB((Math.abs(e.getValue().hashCode()) % 360) / 360f, glass ? 0.1f : 0.35f, 0.8f);
            double r = ((h >> 16) & 255) / 255.0, g = ((h >> 8) & 255) / 255.0, b = (h & 255) / 255.0;
            if (l.contains("tire") || l.contains("tyre")) { r = g = b = 0.08; }
            String vmt = "\"VertexLitGeneric\"\n{\n\t\"$basetexture\" \"models/debug/debugwhite\"\n\t\"$color2\" \"[" + f4(r) + " " + f4(g) + " " + f4(b) + "]\"\n"
                + (glass ? "\t\"$translucent\" 1\n\t\"$alpha\" 0.35\n" : "") + "}\n";
            Files.write(matDir.resolve(e.getKey() + ".vmt"), vmt.getBytes(StandardCharsets.US_ASCII));
        }

        Path exe = Paths.get(GMOD, "bin", "studiomdl.exe");
        if (!Files.exists(exe)) exe = Paths.get(GMOD, "bin", "win64", "studiomdl.exe");
        if (!Files.exists(exe)) { System.out.println("[mdl] studiomdl.exe not found; QC is at " + qcFile); return; }
        File log = src.resolve("compile.log").toFile();
        Process pr = new ProcessBuilder(exe.toString(), "-game", Paths.get(GMOD, "garrysmod").toString(), "-nop4", qcFile.toString())
            .directory(src.toFile()).redirectErrorStream(true).redirectOutput(log).start();
        boolean done = pr.waitFor(10, java.util.concurrent.TimeUnit.MINUTES);
        if (!done) pr.destroyForcibly();
        Path mdl = Paths.get(GMOD, "garrysmod", "models", "beamgmod", m + ".mdl");
        if (Files.exists(mdl)) System.out.println("[mdl] OK  " + mdl + "  (" + chunks.size() + " parts)  ->  in GMod: bg_prop " + m);
        else {
            System.out.println("[mdl] FAILED " + model + ", see " + log);
            List<String> lines = Files.readAllLines(log.toPath(), StandardCharsets.ISO_8859_1);
            for (int i = Math.max(0, lines.size() - 8); i < lines.size(); i++) System.out.println("   " + lines.get(i));
        }
    }

    public static void main(String[] a) throws Exception {
        if (a.length == 0) {
            System.out.println("usage:\n  live [id]               current car from the relay -> glb\n  car <model> [--merge]   BeamNG car (e.g. etk800, pickup) -> glb\n  dae <file.dae|zip>      any dae or zip -> glb\noutput: " + OUT);
            return;
        }
        boolean merge = Arrays.asList(a).contains("--merge");
        switch (a[0]) {
            case "live": live(a.length > 1 && !a[1].startsWith("--") ? a[1] : null); break;
            case "mdl": {
                if (a.length < 2) { System.out.println("mdl <model>"); return; }
                exportMdl(a[1], collect(a[1]));
                break;
            }
            case "all": {
                File[] zs = new File(BNG, "content\\vehicles").listFiles((d, n) -> n.toLowerCase().endsWith(".zip") && !n.equalsIgnoreCase("common.zip"));
                if (zs == null) { System.out.println("no vehicles folder under " + BNG); return; }
                Arrays.sort(zs);
                for (int i = 0; i < zs.length; i++) {
                    String nm = zs[i].getName().replaceAll("(?i)\\.zip$", "");
                    System.out.println("[" + (i + 1) + "/" + zs.length + "] " + nm);
                    try { List<Part> ps = collect(nm); if (ps.isEmpty()) System.out.println("[skip] " + nm + ": no .dae"); else exportMdl(nm, ps); }
                    catch (Throwable t) { System.out.println("[fail] " + nm + ": " + t); }
                }
                break;
            }
            case "car": {
                if (a.length < 2) { System.out.println("car <model>"); return; }
                String m = a[1]; boolean did = false;
                File z = new File(BNG, "content\\vehicles\\" + m + ".zip");
                if (!z.exists()) z = new File(BNG, "content/vehicles/" + m + ".zip");
                if (z.exists()) { convertZip(z, m, merge); did = true; }
                File d = new File(BNG, "content\\vehicles\\" + m);
                if (d.isDirectory()) { convertDir(d, m, merge); did = true; }
                if (!did) System.out.println("car not found: " + z);
                break;
            }
            case "dae": {
                File f = new File(a[1]); String base = f.getName().replaceAll("(?i)\\.(dae|zip)$", "");
                if (f.getName().toLowerCase().endsWith(".zip")) convertZip(f, base, merge);
                else try (InputStream in = new FileInputStream(f)) { writeGlb(convertDae(in), Paths.get(OUT, base + ".glb")); }
                break;
            }
            default: System.out.println("unknown mode " + a[0]);
        }
    }
}