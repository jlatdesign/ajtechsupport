// =====================================================================
//  Edge Function "unifi" — lee el inventario de UniFi (Site Manager API)
//  Solo el Super admin la puede usar. Es de SOLO LECTURA en UniFi.
//
//  Instalar (una sola vez):
//   1) Supabase → Edge Functions → Secrets → Add new secret
//        Name:  UNIFI_API_KEY      Value: (tu API key de unifi.ui.com → API)
//   2) Edge Functions → Deploy a new function → Via Editor
//        Nombre: unifi  → borra el ejemplo, pega TODO este archivo → Deploy
//
//  La llave NUNCA va en el index.html ni en GitHub.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const API = "https://api.ui.com";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

// GET a la API de UniFi, probando /v1 y luego /ea; sigue las páginas (nextToken)
async function uiGet(key: string, ruta: string, params: Record<string, string | string[]> = {}) {
  const todos: any[] = [];
  for (const ver of ["v1", "ea"]) {
    let next = "", primera = true, ok = false;
    while (primera || next) {
      primera = false;
      const qs = new URLSearchParams();
      for (const [k, v] of Object.entries(params)) (Array.isArray(v) ? v : [v]).forEach((x) => qs.append(k, x));
      if (next) qs.set("nextToken", next);
      const r = await fetch(`${API}/${ver}/${ruta}${qs.toString() ? "?" + qs : ""}`, { headers: { "X-API-KEY": key, Accept: "application/json" } });
      if (r.status === 404 && ver === "v1") break;            // esta versión no existe: probar /ea
      if (r.status === 401 || r.status === 403) throw new Error("UniFi rechazó la API key (revisa UNIFI_API_KEY).");
      if (r.status === 429) throw new Error("UniFi: demasiadas consultas, espera un minuto.");
      if (!r.ok) throw new Error(`UniFi respondió ${r.status}`);
      const j = await r.json();
      todos.push(...(Array.isArray(j?.data) ? j.data : []));
      next = j?.nextToken || "";
      ok = true;
    }
    if (ok) return todos;
  }
  return todos;
}

const nombreHost = (h: any) =>
  h?.reportedState?.name || h?.reportedState?.hostname || h?.userData?.name || h?.hostname || h?.ipAddress || h?.id;

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "método no permitido" }, 405);
  try {
    const key = Deno.env.get("UNIFI_API_KEY");
    if (!key) return json({ error: "Falta el secreto UNIFI_API_KEY en Supabase → Edge Functions → Secrets." }, 500);
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    // Solo el Super admin
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: quien } = await sb.auth.getUser(token);
    if (!quien?.user) return json({ error: "Sesión no válida. Vuelve a entrar." }, 401);
    const { data: perfil } = await sb.from("perfiles").select("rol").eq("user_id", quien.user.id).maybeSingle();
    const b = await req.json().catch(() => ({}));
    // las métricas del internet (solo lectura) también las pueden ver los operadores; lo demás solo el Super admin
    const puede = perfil?.rol === "admin" || (b.accion === "isp" && perfil?.rol === "operador");
    if (!puede) return json({ error: "Solo el Super admin puede usar la conexión con UniFi." }, 403);

    // ---------- Lista de consolas (para conectar un cliente) ----------
    if (b.accion === "consolas") {
      const hosts = await uiGet(key, "hosts");
      return json({
        consolas: hosts.map((h: any) => ({
          id: h.id,
          nombre: nombreHost(h),
          modelo: h?.reportedState?.hardware?.name || h?.reportedState?.hardware?.shortname || h?.type || "",
          ip: h?.ipAddress || h?.reportedState?.ip || "",
          tipo: h?.type || "",
        })),
      });
    }

    // ---------- Equipos de las consolas conectadas a UN cliente ----------
    if (b.accion === "equipos") {
      const cliente = String(b.cliente || "").trim();
      if (!cliente) return json({ error: "Falta el cliente." }, 400);
      const { data: cls } = await sb.from("clientes").select("nombre, unifi_hosts");
      const c = (cls || []).find((x: any) => String(x.nombre).trim().toLowerCase() === cliente.toLowerCase());
      const ids: string[] = (Array.isArray(c?.unifi_hosts) ? c!.unifi_hosts : []).map((h: any) => String(h?.id || h)).filter(Boolean);
      if (!ids.length) return json({ error: "Este cliente no tiene consolas UniFi conectadas." }, 400);

      const grupos = await uiGet(key, "devices", { "hostIds[]": ids });
      const equipos: any[] = [];
      for (const g of grupos) {
        if (!ids.includes(String(g?.hostId))) continue;          // nunca devolver consolas de otros clientes
        for (const d of g?.devices || []) {
          equipos.push({
            id: d.id, nombre: d.name || d.model || d.mac, modelo: d.model || "", corto: d.shortname || "",
            mac: d.mac || "", ip: d.ip || "", estado: d.status || "", firmware: d.version || "",
            actualizar: !!d.updateAvailable || d.firmwareStatus === "updateAvailable",
            linea: d.productLine || "", consola: !!d.isConsole, host: g.hostName || g.hostId, hostId: String(g.hostId || ""),
          });
        }
      }
      return json({ equipos });
    }

    // ---------- 🛰 Internet según el gateway (ISP Metrics): latencia, pérdida, uptime y velocidad medidos por el propio gateway ----------
    // 5m = bloques de 5 minutos (últimas 24 h) · 1h = bloques de 1 hora (últimos 30 días)
    if (b.accion === "isp") {
      const cliente = String(b.cliente || "").trim();
      const { data: cls } = await sb.from("clientes").select("nombre, unifi_hosts");
      const c = (cls || []).find((x: any) => String(x.nombre).trim().toLowerCase() === cliente.toLowerCase());
      const ids: string[] = (Array.isArray(c?.unifi_hosts) ? c!.unifi_hosts : []).map((h: any) => String(h?.id || h)).filter(Boolean);
      if (!ids.length) return json({ error: "Este cliente no tiene consolas UniFi conectadas (botón 🔗 UniFi)." }, 400);
      const tipo = b.tipo === "1h" ? "1h" : "5m";
      const fin = b.hasta ? new Date(b.hasta) : new Date();
      const lim = tipo === "5m" ? 24 * 3600e3 : 30 * 24 * 3600e3;
      let ini = b.desde ? new Date(b.desde) : new Date(fin.getTime() - (tipo === "5m" ? 24 * 3600e3 : 7 * 24 * 3600e3));
      if (fin.getTime() - ini.getTime() > lim) ini = new Date(fin.getTime() - lim);
      const todos = await uiGet(key, "sites");
      const sitios = todos.filter((x: any) => ids.includes(String(x.hostId)));
      if (!sitios.length) return json({ error: "No encontré los sitios de las consolas de este cliente." }, 404);
      const nombreSitio = (x: any) => x?.meta?.desc || x?.meta?.name || x?.siteId || "";
      const cuerpo = { sites: sitios.map((x: any) => ({ hostId: String(x.hostId), siteId: String(x.siteId), beginTimestamp: ini.toISOString(), endTimestamp: fin.toISOString() })) };
      let datos: any[] = [];
      for (const ver of ["ea", "v1"]) {
        const r = await fetch(`${API}/${ver}/isp-metrics/${tipo}/query`, { method: "POST", headers: { "X-API-KEY": key, Accept: "application/json", "Content-Type": "application/json" }, body: JSON.stringify(cuerpo) });
        if (r.status === 404) continue;
        if (r.status === 401 || r.status === 403) throw new Error("UniFi rechazó la API key (revisa UNIFI_API_KEY).");
        if (r.status === 429) throw new Error("UniFi: demasiadas consultas, espera un minuto.");
        if (!r.ok) throw new Error(`UniFi respondió ${r.status}`);
        const j = await r.json(); datos = Array.isArray(j?.data) ? j.data : Array.isArray(j?.data?.metrics) ? j.data.metrics : []; break;
      }
      const num = (...v: any[]) => { for (const x of v) { const n = typeof x === "object" && x ? (x.kbps ?? x.value ?? x.avg) : x; if (n != null && isFinite(Number(n))) return Number(n); } return null; };
      const salida = datos.map((it: any, i: number) => {
        const st = sitios.find((x: any) => String(x.siteId) === String(it.siteId) && (!it.hostId || String(x.hostId) === String(it.hostId))) || sitios[i] || sitios[0];
        const periodos = (Array.isArray(it.periods) ? it.periods : []).map((p: any) => { const w = p?.data?.wan || p?.wan || p?.data || {};
          return { t: p.metricTime || p.time, lat: num(w.avgLatency, w.latency_avg), max: num(w.maxLatency, w.latency_max), perdida: num(w.packetLoss, w.packet_loss),
            uptime: num(w.uptime), bajada: num(w.download_kbps, w.downloadKbps, w.download), subida: num(w.upload_kbps, w.uploadKbps, w.upload), isp: w.ispName || w.isp_name || "" }; })
          .filter((p: any) => p.t).sort((a: any, b: any) => String(a.t).localeCompare(String(b.t)));
        return { hostId: st?.hostId || it.hostId || "", siteId: st?.siteId || it.siteId || "", sitio: nombreSitio(st), periodos };
      });
      return json({ tipo, desde: ini.toISOString(), hasta: fin.toISOString(), sitios: salida });
    }

    return json({ error: "acción no válida" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
