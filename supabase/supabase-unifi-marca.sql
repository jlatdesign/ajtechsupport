-- =====================================================
--  🔗 UniFi: poner la marca "UniFi" a los equipos que ya se importaron
--  Ej.: "U6+" → "UniFi U6+", "U7 Long-Range" → "UniFi U7 Long-Range"
--  Supabase > SQL Editor > New query > pega todo > Run
--  Solo toca equipos importados de UniFi (los que tienen unifi_id). Se puede correr más de una vez.
-- =====================================================
update public.equipos
   set modelo = case when coalesce(trim(modelo), '') = '' then 'UniFi' else 'UniFi ' || trim(modelo) end
 where unifi_id is not null
   and coalesce(modelo, '') !~* '(unifi|ubiquiti|ubnt)';

-- Para ver cómo quedaron:
select cliente, tipo, nombre, modelo from public.equipos where unifi_id is not null order by cliente, tipo, nombre;
