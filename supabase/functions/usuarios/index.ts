// =====================================================================
//  Edge Function "usuarios" — crear, cambiar clave y borrar usuarios
//  desde la app del Inventario (solo el Super admin).
//
//  Cómo instalarla (una sola vez):
//   Supabase → Edge Functions → Deploy a new function → Via Editor
//   Nombre: usuarios   → borra lo que trae, pega TODO este archivo → Deploy
//
//  La llave secreta (service_role) la pone Supabase solo; NUNCA va en el index.html.
// =====================================================================
import { createClient } from "npm:@supabase/supabase-js@2";

const DOMINIO = "inventario.local";            // igual que DOMINIO_USUARIOS en el index.html
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

    // 1) ¿Quién llama? (token de la sesión de la app)
    const token = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: quien, error: errUser } = await sb.auth.getUser(token);
    const yo = quien?.user;
    if (errUser || !yo) return json({ error: "Sesión no válida. Vuelve a entrar." }, 401);

    // 2) Solo el Super admin
    const { data: perfil } = await sb.from("perfiles").select("rol").eq("user_id", yo.id).maybeSingle();
    if (perfil?.rol !== "admin") return json({ error: "Solo el Super admin puede administrar usuarios." }, 403);

    const b = await req.json().catch(() => ({}));
    const quienSoy = (yo.email || "").split("@")[0] || "admin";
    const registrar = async (evento: string, objeto: string, cambios: Record<string, unknown> | null = null) => {
      try {
        await sb.from("actividad").insert({ usuario: quienSoy, user_id: yo.id, categoria: "access", evento, severidad: 3, objeto, cambios });
      } catch (_) { /* el historial es opcional */ }
    };

    // ---------- Crear usuario ----------
    if (b.accion === "crear") {
      const usuario = String(b.usuario || "").trim().toLowerCase();
      const password = String(b.password || "");
      const rol = ["admin", "cliente", "ninguno"].includes(b.rol) ? b.rol : "cliente";
      const clientes: string[] = Array.isArray(b.clientes) ? b.clientes.map((c: unknown) => String(c)).filter(Boolean) : [];
      if (!/^[a-z0-9][a-z0-9._-]{1,39}$/.test(usuario)) return json({ error: "Usuario no válido: usa letras, números, punto o guion (2 a 40)." }, 400);
      if (password.length < 8) return json({ error: "La contraseña debe tener al menos 8 caracteres." }, 400);
      if (rol === "cliente" && !clientes.length) return json({ error: "Escoge al menos una compañía." }, 400);

      const { data: nuevo, error } = await sb.auth.admin.createUser({ email: `${usuario}@${DOMINIO}`, password, email_confirm: true });
      if (error || !nuevo?.user) {
        const ya = /already|registered|exists/i.test(error?.message || "");
        return json({ error: ya ? "Ese usuario ya existe." : (error?.message || "No se pudo crear el usuario.") }, ya ? 409 : 400);
      }
      if (rol !== "ninguno") {
        const { error: e2 } = await sb.from("perfiles").upsert({
          user_id: nuevo.user.id, rol, clientes: rol === "admin" ? [] : clientes,
          puede_editar: rol === "admin" || !!b.editar, ver_claves: rol === "admin" || !!b.claves, updated_at: new Date().toISOString(),
        });
        if (e2) return json({ error: "Usuario creado, pero no se pudo guardar su acceso: " + e2.message, id: nuevo.user.id }, 500);
      }
      await registrar("user_created", usuario, { rol, clientes, editar: !!b.editar, claves: !!b.claves });
      return json({ ok: true, id: nuevo.user.id });
    }

    // ---------- Cambiar contraseña ----------
    if (b.accion === "clave") {
      const password = String(b.password || "");
      if (!b.user_id) return json({ error: "Falta el usuario." }, 400);
      if (password.length < 8) return json({ error: "La contraseña debe tener al menos 8 caracteres." }, 400);
      const { data: u, error } = await sb.auth.admin.updateUserById(String(b.user_id), { password });
      if (error) return json({ error: error.message }, 400);
      await registrar("user_pw_reset", (u?.user?.email || "").split("@")[0]);
      return json({ ok: true });
    }

    // ---------- Borrar usuario ----------
    if (b.accion === "borrar") {
      if (!b.user_id) return json({ error: "Falta el usuario." }, 400);
      if (String(b.user_id) === yo.id) return json({ error: "No puedes borrar tu propio usuario." }, 400);
      const { data: u } = await sb.auth.admin.getUserById(String(b.user_id));
      const { error } = await sb.auth.admin.deleteUser(String(b.user_id));
      if (error) return json({ error: error.message }, 400);
      await registrar("user_deleted", (u?.user?.email || "").split("@")[0]);
      return json({ ok: true });
    }

    return json({ error: "acción no válida" }, 400);
  } catch (e) {
    return json({ error: String((e as Error)?.message || e) }, 500);
  }
});
