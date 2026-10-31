-- SOLO si necesitas usar la versión vieja (v4.6) mientras subes la v5.0.
-- Devuelve el permiso de leer la tabla completa. Tu usuario (Super admin) vuelve a ver todo.
-- Cuando ya esté la v5.0 en el sitio, corre otra vez supabase-roles.sql para volver a proteger las contraseñas.
grant select on public.equipos to authenticated;
notify pgrst, 'reload schema';
