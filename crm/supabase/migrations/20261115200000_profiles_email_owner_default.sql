-- S1 · profiles.email (para exibir o time em listas de dono) e dono padrão = quem cria.

alter table public.profiles add column email text;

update public.profiles p
set email = lower(u.email)
from auth.users u
where u.id = p.id;

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email, full_name, avatar_url)
  values (
    new.id,
    lower(new.email),
    coalesce(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name'),
    new.raw_user_meta_data ->> 'avatar_url'
  )
  on conflict (id) do update set email = excluded.email;
  return new;
end;
$$;

alter table public.companies alter column owner_id set default auth.uid();
alter table public.contacts alter column owner_id set default auth.uid();
alter table public.deals alter column owner_id set default auth.uid();
