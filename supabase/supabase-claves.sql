-- =====================================================================
--  🔑 Usuarios y contraseñas de cada cliente (portal v9.13.0)
--  Se guardan en cloud_items con clase 'clave'. Usan la misma protección
--  que las claves de Cloud Server (supabase-cloud.sql):
--    · la columna claves no se lee directo; solo con cloud_listar() y si el
--      usuario tiene permiso para ver contraseñas
--    · quien no puede verlas tampoco puede cambiarlas (trigger cloud_proteger)
--    · el historial registra el cambio, nunca la contraseña
--  Requiere haber corrido antes supabase-cloud.sql. Se puede correr varias veces.
-- =====================================================================
alter table public.cloud_items drop constraint if exists cloud_items_clase_check;
alter table public.cloud_items add constraint cloud_items_clase_check
  check (clase in ('server','usuario','printer','software','carpeta','firewall','contacto','clave'));
