// =====================================================================
//  Edge Function "upc" — busca en internet qué producto es un código de barras (UPC / EAN)
//  Usa UPCitemdb. Sin llave usa la prueba gratis (pocas búsquedas al día);
//  con llave (plan de pago) usa el plan normal.
//  La pueden usar el Super admin y los operadores (no los usuarios "cliente").
//
//  Instalar (una sola vez):
//   1) Supabase → Edge Functions → Deploy a new function → Via Editor
//        Nombre: upc  → borra el ejemplo, pega TODO este archivo → Deploy
//   2) (Opcional, solo si compras un plan de UPCitemdb)
//        Edge Functions → Secrets → Add new secret
//        Name: UPCITEMDB_KEY     Value: (tu llave de UPCitemdb)
//
//  La llave NUNCA va en el index.html ni en GitHub.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });
  if (req.method !== "POST") return json({ error: "método no permitido" }, 405);
  try {
    const sb = createClient(Deno.env.get("SUPABASE_URL")!, Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    // Solo usuarios con sesión y rol admin u operador
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: quien } = await sb.auth.getUser(token);
    if (!quien?.user) return json({ error: "Sesión no válida. Vuelve a entrar." }, 401);
    const { data: perfil } = await sb.from("perfiles").select("rol").eq("user_id", quien.user.id).maybeSingle();
    if (!["admin", "operador"].includes(perfil?.rol || "")) return json({ error: "Sin permiso para buscar productos." }, 403);

    const b = await req.json().catch(() => ({}));
    const code = String(b.upc || "").replace(/\D/g, "");
    if (!/^\d{8,14}$/.test(code)) return json({ error: "El código debe tener de 8 a 14 números (UPC / EAN)." }, 400);

    const key = Deno.env.get("UPCITEMDB_KEY");
    const url = key ? `https://api.upcitemdb.com/prod/v1/lookup?upc=${code}` : `https://api.upcitemdb.com/prod/trial/lookup?upc=${code}`;
    const headers: Record<string, string> = { Accept: "application/json" };
    if (key) { headers["user_key"] = key; headers["key_type"] = "3scale"; }
    const r = await fetch(url, { headers });
    const restantes = r.headers.get("X-RateLimit-Remaining");
    if (r.status === 429) return json({ error: "Se acabaron las búsquedas gratis de hoy. Prueba mañana (o agrega una llave de UPCitemdb).", restantes }, 429);
    const j: any = await r.json().catch(() => ({}));
    if (!r.ok && j?.code !== "INVALID_UPC") return json({ error: `UPCitemdb respondió ${r.status}${j?.message ? ": " + j.message : ""}`, restantes }, 502);
    const items = (Array.isArray(j?.items) ? j.items : []).slice(0, 3).map((i: any) => ({
      titulo: i.title || "", marca: i.brand || "", modelo: i.model || "", descripcion: String(i.description || "").slice(0, 400),
      categoria: i.category || "", imagenes: (Array.isArray(i.images) ? i.images : []).slice(0, 3), ean: i.ean || "", upc: i.upc || "",
      precio_min: i.lowest_recorded_price ?? null, precio_max: i.highest_recorded_price ?? null,
    }));
    return json({ codigo: code, items, restantes });
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
