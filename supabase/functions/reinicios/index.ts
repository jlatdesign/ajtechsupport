// =====================================================================
//  Edge Function "reinicios" — reinicia equipos UniFi (ahora o programado)
//   · Reinicio normal de un equipo adoptado (AP, switch, gateway):
//       POST /v1/sites/{siteId}/devices/{deviceId}/actions            {"action":"RESTART"}
//   · Ciclo de PoE de un puerto del switch (teléfonos, cámaras, cualquier equipo PoE):
//       POST /v1/sites/{siteId}/devices/{switchId}/interfaces/ports/{idx}/actions  {"action":"POWER_CYCLE"}
//   Todo pasa por la nube de UniFi (Site Manager → connector) hasta la consola del cliente:
//       https://api.ui.com/v1/connector/consoles/{consoleId}/proxy/network/integration/v1/...
//
//  Instalar (una sola vez):
//   1) Ya tienes el secreto UNIFI_API_KEY (el mismo de la función "unifi").
//   2) Edge Functions → Deploy a new function → Via Editor
//        Nombre: reinicios → borra el ejemplo, pega TODO este archivo → Deploy
//   3) En la función "reinicios" → Details → apaga "Verify JWT with legacy secret"
//      (el reloj de la base de datos la llama sin usuario; la función revisa ella misma quién llama).
//   4) Corre supabase-reinicios.sql (crea las tablas y el reloj que revisa cada minuto).
//
//  Quién la puede usar:
//   · La app: solo el Super admin (rol admin).
//   · El reloj (pg_cron): con la llave secreta guardada en la tabla reinicio_cron.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const CONNECTOR = "https://api.ui.com/v1/connector/consoles";
const ESPERA_MIN = 2;          // minutos mínimos entre dos reinicios del mismo equipo
const TARDE_MIN = 15;          // si el reloj se atrasó más que esto, no se ejecuta (se marca "omitido")
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-cron-key",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });
const macN = (m: unknown) => String(m || "").toLowerCase().replace(/[^0-9a-f]/g, "");
const hostIds = (c: any): string[] => {
  let v = c?.unifi_hosts;
  if (typeof v === "string") { try { v = JSON.parse(v); } catch { v = []; } }
  return (Array.isArray(v) ? v : []).map((h: any) => String(h?.id || h)).filter(Boolean);
};

// Llamada a la API de Network de la consola, pasando por la nube de UniFi
async function net(key: string, consola: string, ruta: string, metodo = "GET", body?: unknown) {
  const r = await fetch(`${CONNECTOR}/${encodeURIComponent(consola)}/proxy/network/integration/v1/${ruta}`, {
    method: metodo,
    headers: { "X-API-KEY": key, Accept: "application/json", ...(body ? { "Content-Type": "application/json" } : {}) },
    body: body ? JSON.stringify(body) : undefined,
  });
  const txt = await r.text();
  let j: any = null; try { j = txt ? JSON.parse(txt) : null; } catch { /* sin json */ }
  if (r.status === 401 || r.status === 403) throw new Error("UniFi no dio permiso (la API key debe ser de un usuario Admin de esa consola).");
  if (r.status === 429) throw new Error("UniFi: demasiadas consultas, espera un minuto.");
  if (r.status === 404 && /connector|console/i.test(txt) && !/resource/i.test(txt)) throw new Error("La consola no responde por la nube (¿apagada o sin internet? ¿firmware viejo?).");
  if (!r.ok) throw new Error(`UniFi respondió ${r.status}${j?.message ? ": " + j.message : ""}`);
  return j;
}
const lista = (j: any) => (Array.isArray(j?.data) ? j.data : Array.isArray(j) ? j : []);

// Busca un equipo (por MAC) en las consolas del cliente → { consola, sitio, id, detalle }
async function buscar(key: string, consolas: string[], mac: string, cache: Map<string, any[]>) {
  for (const consola of consolas) {
    let sitios: any[] = cache.get("s:" + consola) || [];
    if (!cache.has("s:" + consola)) { sitios = lista(await net(key, consola, "sites?limit=200")); cache.set("s:" + consola, sitios); }
    for (const s of sitios) {
      const k = `d:${consola}:${s.id}`;
      let devs: any[] = cache.get(k) || [];
      if (!cache.has(k)) {
        devs = [];
        for (let off = 0; off < 2000; off += 200) {
          const pg = await net(key, consola, `sites/${s.id}/devices?offset=${off}&limit=200`);
          const d = lista(pg); devs.push(...d);
          if (d.length < 200) break;
        }
        cache.set(k, devs);
      }
      const d = devs.find((x: any) => macN(x.macAddress || x.mac) === mac);
      if (d) return { consola, sitio: s.id, sitioNombre: s.name || s.internalReference || "", id: d.id, nombre: d.name, modelo: d.model };
    }
  }
  return null;
}
const puertosDe = (det: any) => {
  const p = Array.isArray(det?.interfaces?.ports) ? det.interfaces.ports : Array.isArray(det?.ports) ? det.ports : [];
  return p.map((x: any) => ({ idx: Number(x.idx ?? x.portIdx ?? x.index), estado: x.state || "", velocidad: x.speedMbps ?? null,
    conector: x.connector || "", poe: !!(x.poe?.enabled ?? x.poeEnabled), poeEstado: x.poe?.state || "" })).filter((x: any) => Number.isFinite(x.idx));
};

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "método no permitido" }, 405);
  const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, { auth: { persistSession: false, autoRefreshToken: false } });
  try {
    const key = Deno.env.get("UNIFI_API_KEY");
    if (!key) return json({ error: "Falta el secreto UNIFI_API_KEY en Supabase → Edge Functions → Secrets." }, 500);
    const b = await req.json().catch(() => ({}));

    // ---- ¿Quién llama? el reloj (llave secreta) o un usuario Super admin
    let autor = "";
    const cronKey = req.headers.get("x-cron-key");
    if (cronKey) {
      const { data: k } = await sb.from("reinicio_cron").select("clave").limit(1).maybeSingle();
      if (!k?.clave || k.clave !== cronKey) return json({ error: "llave del reloj inválida" }, 401);
      autor = "⏰ programado";
    } else {
      const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
      const { data: quien } = await sb.auth.getUser(token);
      if (!quien?.user) return json({ error: "Sesión no válida. Vuelve a entrar." }, 401);
      const { data: perfil } = await sb.from("perfiles").select("rol").eq("user_id", quien.user.id).maybeSingle();
      if (perfil?.rol !== "admin") return json({ error: "Solo el Super admin puede reiniciar equipos." }, 403);
      autor = String(quien.user.email || "").split("@")[0];
      if (b.accion === "tick") return json({ error: "acción no válida" }, 400);
    }

    const cache = new Map<string, any[]>();
    const equipo = async (id: string) => (await sb.from("equipos").select("id, cliente, nombre, tipo, mac, modelo").eq("id", id).maybeSingle()).data;
    const cliente = async (nombre: string) => {
      const { data } = await sb.from("clientes").select("nombre, unifi_hosts");
      return (data || []).find((c: any) => String(c.nombre).trim().toLowerCase() === String(nombre || "").trim().toLowerCase());
    };

    // Hace el reinicio. r = { equipo_id, modo, switch_id, puerto }
    const ejecutar = async (r: any) => {
      const eq = await equipo(r.equipo_id); if (!eq) throw new Error("El equipo ya no existe en el inventario.");
      const c = await cliente(eq.cliente), consolas = hostIds(c);
      if (!consolas.length) throw new Error("Este cliente no tiene consolas UniFi conectadas (botón 🔗 UniFi).");
      // espera mínima entre reinicios del mismo equipo
      const { data: rec } = await sb.from("reinicio_log").select("created_at").eq("equipo_id", eq.id).eq("estado", "ok")
        .gte("created_at", new Date(Date.now() - ESPERA_MIN * 60000).toISOString()).limit(1);
      if (rec?.length) throw Object.assign(new Error(`Ya se reinició hace menos de ${ESPERA_MIN} minutos. Espera un poco.`), { omitido: true });
      if (r.modo === "poe") {
        const sw = await equipo(r.switch_id); if (!sw?.mac) throw new Error("Falta el switch (con su MAC) para el ciclo de PoE.");
        const p = Number(r.puerto); if (!Number.isInteger(p) || p < 1) throw new Error("Falta el número de puerto.");
        const d = await buscar(key, consolas, macN(sw.mac), cache); if (!d) throw new Error(`No encontré el switch ${sw.nombre} en UniFi (revisa su MAC).`);
        const det = await net(key, d.consola, `sites/${d.sitio}/devices/${d.id}`);
        const pt = puertosDe(det).find((x: any) => x.idx === p);
        if (pt && !pt.poe) throw new Error(`El puerto ${p} de ${sw.nombre} no tiene PoE encendido; el ciclo no reiniciaría el equipo.`);
        // nunca apagar un puerto que alimenta a otro equipo UniFi de la red (switch / AP)
        const devs: any[] = cache.get(`d:${d.consola}:${d.sitio}`) || [];
        const colgado = devs.find((x: any) => (x.uplink?.deviceId === d.id || x.uplinkDeviceId === d.id) && Number(x.uplink?.portIdx ?? x.uplinkPortIdx) === p);
        if (colgado) throw new Error(`El puerto ${p} alimenta a ${colgado.name || colgado.model}; no se hace ciclo de PoE ahí (se caería esa parte de la red).`);
        await net(key, d.consola, `sites/${d.sitio}/devices/${d.id}/interfaces/ports/${p}/actions`, "POST", { action: "POWER_CYCLE" });
        return `Ciclo de PoE en ${sw.nombre} · puerto ${p}`;
      }
      if (!eq.mac) throw new Error("Este equipo no tiene MAC en el inventario; sin MAC no lo puedo encontrar en UniFi.");
      const d = await buscar(key, consolas, macN(eq.mac), cache);
      if (!d) throw new Error(/tel/i.test(eq.tipo || "") ? "Los teléfonos de UniFi Talk no se reinician así: usa \"Ciclo de PoE\" con el switch y el puerto." : "No encontré este equipo en UniFi Network (¿está adoptado? ¿la MAC es la correcta?).");
      await net(key, d.consola, `sites/${d.sitio}/devices/${d.id}/actions`, "POST", { action: "RESTART" });
      return `Reinicio enviado a ${d.nombre || eq.nombre}${d.sitioNombre ? " (" + d.sitioNombre + ")" : ""}`;
    };
    const anotar = async (r: any, origen: string, estado: string, mensaje: string, quien = autor) => {
      const eq = await equipo(r.equipo_id);
      await sb.from("reinicio_log").insert({ prog_id: r.prog_id || null, cliente: eq?.cliente || r.cliente || null, equipo_id: r.equipo_id, nombre: eq?.nombre || r.nombre || null,
        modo: r.modo || "reinicio", origen, estado, mensaje: String(mensaje).slice(0, 500), autor: quien });
    };
    // Lista de equipos de una regla (las viejas tienen uno solo)
    const objetivos = (p: any) => (Array.isArray(p?.objetivos) && p.objetivos.length ? p.objetivos
      : p?.equipo_id ? [{ equipo_id: p.equipo_id, modo: p.modo, switch_id: p.switch_id, puerto: p.puerto }] : []);
    // Orden: primero lo normal, después los switches y al final el router (para no tumbar antes lo que cuelga de ellos)
    const esGw = (e: any) => /router|firewall/i.test(e?.tipo || "") || /\b(UDM|UCG|UXG|UDR|USG|DREAM ?MACHINE|GATEWAY)\b/i.test(`${e?.modelo || ""} ${e?.nombre || ""}`);
    const planificar = async (objs: any[], escSeg: number, inicio: number) => {
      const conNivel = [];
      for (const o of objs) { const e = await equipo(o.equipo_id); conNivel.push({ o, n: o.modo === "poe" ? 0 : esGw(e) ? 2 : /switch/i.test(e?.tipo || "") ? 1 : 0 }); }
      conNivel.sort((a, b) => a.n - b.n);
      const hayBase = conNivel.some((x) => x.n === 0);
      return conNivel.map((x, i) => ({ objetivo: x.o, hacer_en: new Date(inicio + (escSeg > 0 ? i * escSeg * 1000 : (hayBase || x.n === 2 ? x.n : 0) * 60000)).toISOString() }));
    };
    const encolar = async (prog: any, objs: any[], escSeg: number, origen: string, quien: string) => {
      const plan = await planificar(objs, escSeg, Date.now());
      const filas = plan.map((x) => ({ prog_id: prog?.id || null, cliente: prog?.cliente || null, objetivo: x.objetivo, origen, autor: quien, hacer_en: x.hacer_en }));
      const { error } = await sb.from("reinicio_cola").insert(filas); if (error) throw new Error(error.message);
      return filas.length;
    };
    // Ejecuta lo que ya toca de la cola → [{prog_id, estado, msg, nombre}]
    const procesarCola = async () => {
      const { data: items, error } = await sb.rpc("reinicio_cola_tomar"); if (error) throw new Error(error.message);
      const res: any[] = [];
      for (const it of items || []) {
        const o = { ...(it.objetivo || {}), prog_id: it.prog_id, cliente: it.cliente };
        let estado = "ok", msg = "";
        try { msg = await ejecutar(o); } catch (e) { estado = (e as any)?.omitido ? "omitido" : "error"; msg = String((e as Error)?.message || e); }
        await anotar(o, it.origen || "programado", estado, msg, it.autor || "⏰ programado");
        await sb.from("reinicio_cola").update({ estado: "hecho" }).eq("id", it.id);
        res.push({ prog_id: it.prog_id, estado, msg, nombre: (await equipo(o.equipo_id))?.nombre || "" });
      }
      return res;
    };
    // resumen en la regla: "ok" si todo salió bien en esta vuelta
    const resumir = async (res: any[]) => {
      const porProg: Record<string, any[]> = {};
      res.filter((x) => x.prog_id).forEach((x) => (porProg[x.prog_id] = porProg[x.prog_id] || []).push(x));
      for (const [id, L] of Object.entries(porProg)) {
        const { data: r } = await sb.from("reinicio_prog").select("proxima").eq("id", id).maybeSingle(); if (!r) continue;
        const est = L.some((x) => x.estado === "error") ? "error" : L.every((x) => x.estado === "omitido") ? "omitido" : "ok";
        const msg = L.length === 1 ? L[0].msg : L.map((x) => `${x.nombre}: ${x.estado === "ok" ? "OK" : x.msg}`).join(" · ");
        await sb.from("reinicio_prog").update({ ultimo_estado: est, ultimo_msg: msg.slice(0, 300), proxima: r.proxima }).eq("id", id);
      }
    };

    // ---------- El reloj: pasa a la cola las reglas que tocan y ejecuta lo que ya toca ----------
    if (b.accion === "tick") {
      const { data: tomados, error } = await sb.rpc("reinicio_tomar");
      if (error) return json({ error: error.message }, 500);
      const omitidos: any[] = [];
      for (const t of tomados || []) {
        const { data: r } = await sb.from("reinicio_prog").select("*").eq("id", t.id).maybeSingle(); if (!r) continue;
        const objs = objetivos(r);
        if (t.tocaba && Date.now() - new Date(t.tocaba).getTime() > TARDE_MIN * 60000) {
          const msg = `Tocaba a las ${t.tocaba} y el reloj llegó tarde; no se reinició fuera de hora.`;
          for (const o of objs) { await anotar({ ...o, prog_id: r.id, cliente: r.cliente }, "programado", "omitido", msg); omitidos.push({ prog_id: r.id, estado: "omitido", msg, nombre: "" }); }
          continue;
        }
        await encolar(r, objs, objs.length > 1 ? Number(r.escalonar_seg ?? 60) : 0, "programado", autor);
      }
      const res = await procesarCola();
      await resumir([...omitidos, ...res]);
      return json({ hechos: res, omitidos: omitidos.length });
    }

    // ---------- Reiniciar ahora (botón en la app): uno o varios ----------
    if (b.accion === "ahora") {
      let objs: any[] = Array.isArray(b.objetivos) ? b.objetivos.filter((o: any) => o?.equipo_id) : [];
      if (!objs.length && b.equipo_id) objs = [{ equipo_id: b.equipo_id, modo: b.modo, switch_id: b.switch_id, puerto: b.puerto }];
      if (!objs.length) return json({ error: "Falta el equipo." }, 400);
      objs = objs.slice(0, 200).map((o: any) => ({ equipo_id: o.equipo_id, modo: o.modo === "poe" ? "poe" : "reinicio", switch_id: o.switch_id || null, puerto: o.puerto ?? null }));
      let prog: any = null;
      if (b.prog_id) prog = (await sb.from("reinicio_prog").select("id, cliente").eq("id", b.prog_id).maybeSingle()).data;
      if (objs.length === 1) {
        const r = { ...objs[0], prog_id: prog?.id || null };
        try { const msg = await ejecutar(r); await anotar(r, "manual", "ok", msg); return json({ ok: true, msg }); }
        catch (e) { const msg = String((e as Error)?.message || e); await anotar(r, "manual", (e as any)?.omitido ? "omitido" : "error", msg); return json({ error: msg }, 400); }
      }
      const eq0 = await equipo(objs[0].equipo_id);
      const n = await encolar(prog || { cliente: eq0?.cliente || null }, objs, Math.max(0, Number(b.escalonar_seg ?? 60)), "manual", autor);
      const res = await procesarCola();
      const ok = res.filter((x) => x.estado === "ok").length, mal = res.filter((x) => x.estado !== "ok");
      const quedan = n - res.length;
      return json({ ok: true, msg: `${n} equipos: ${ok} reiniciados ahora${mal.length ? `, ${mal.length} con problema (${mal.map((x) => x.nombre + ": " + x.msg).join(" · ")})` : ""}${quedan > 0 ? `, ${quedan} en cola (uno por uno, ver Historial)` : ""}.` });
    }

    // ---------- Puertos de un switch (para escoger el puerto del teléfono) ----------
    if (b.accion === "puertos") {
      const sw = await equipo(b.switch_id); if (!sw?.mac) return json({ error: "El switch no tiene MAC en el inventario." }, 400);
      const consolas = hostIds(await cliente(sw.cliente)); if (!consolas.length) return json({ error: "Este cliente no tiene consolas UniFi conectadas." }, 400);
      const d = await buscar(key, consolas, macN(sw.mac), cache); if (!d) return json({ error: `No encontré ${sw.nombre} en UniFi Network.` }, 404);
      const det = await net(key, d.consola, `sites/${d.sitio}/devices/${d.id}`);
      const devs: any[] = cache.get(`d:${d.consola}:${d.sitio}`) || [];
      const puertos = puertosDe(det).map((p: any) => {
        const x = devs.find((v: any) => (v.uplink?.deviceId === d.id || v.uplinkDeviceId === d.id) && Number(v.uplink?.portIdx ?? v.uplinkPortIdx) === p.idx);
        return { ...p, alimenta: x ? (x.name || x.model) : "" };
      });
      return json({ switch: d.nombre || sw.nombre, puertos });
    }

    // ---------- Probar: ¿encuentro este equipo en UniFi? (no reinicia nada) ----------
    if (b.accion === "probar") {
      const eq = await equipo(b.equipo_id); if (!eq?.mac) return json({ error: "Este equipo no tiene MAC en el inventario." }, 400);
      const consolas = hostIds(await cliente(eq.cliente)); if (!consolas.length) return json({ error: "Este cliente no tiene consolas UniFi conectadas." }, 400);
      const d = await buscar(key, consolas, macN(eq.mac), cache);
      return d ? json({ ok: true, msg: `Encontrado: ${d.nombre || eq.nombre}${d.modelo ? " · " + d.modelo : ""}${d.sitioNombre ? " · sitio " + d.sitioNombre : ""}` })
               : json({ error: "No está en UniFi Network (los teléfonos de Talk no salen aquí: usa ciclo de PoE)." }, 404);
    }

    return json({ error: "acción no válida" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
