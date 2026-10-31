alter table public.equipos
  add column if not exists pc_users    jsonb default '[]'::jsonb,
  add column if not exists pw_history  jsonb default '[]'::jsonb;

notify pgrst, 'reload schema';
