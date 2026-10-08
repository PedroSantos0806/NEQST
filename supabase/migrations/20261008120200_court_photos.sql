-- =====================================================================
-- NEQST — Sprint 2
-- 12. Upload de fotos da quadra
--
-- O arquivo vai para o Supabase Storage; o banco guarda o metadado e o
-- estado de moderação. Fotos entram como 'pending' e só aparecem no app
-- depois de aprovadas — conteúdo enviado por usuário em app de loja
-- precisa de um caminho de moderação.
-- =====================================================================

do $$ begin
  create type public.photo_status as enum ('pending', 'approved', 'rejected');
exception when duplicate_object then null; end $$;

create table if not exists public.court_photos (
  id            uuid primary key default gen_random_uuid(),
  court_id      uuid not null references public.courts (id) on delete cascade,
  user_id       uuid not null references auth.users (id) on delete cascade,
  storage_path  text not null unique,
  status        public.photo_status not null default 'pending',
  caption       text,
  content_type  text not null default 'image/jpeg',
  size_bytes    integer,
  width         integer,
  height        integer,
  is_uploaded   boolean not null default false,
  is_primary    boolean not null default false,
  moderated_by  uuid references auth.users (id) on delete set null,
  moderated_at  timestamptz,
  reject_reason text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),

  constraint court_photos_caption_length
    check (caption is null or char_length(caption) <= 300),
  constraint court_photos_content_type
    check (content_type in ('image/jpeg', 'image/png', 'image/webp')),
  constraint court_photos_size
    check (size_bytes is null or size_bytes between 1 and 10485760)
);

comment on table public.court_photos is
  'Fotos enviadas pelos jogadores. Só status=approved e is_uploaded chegam ao app.';
comment on column public.court_photos.is_uploaded is
  'A linha nasce antes do upload (para gerar a URL assinada) e é confirmada depois.';

create index if not exists court_photos_court_idx
  on public.court_photos (court_id, created_at desc);

create index if not exists court_photos_approved_idx
  on public.court_photos (court_id, created_at desc)
  where status = 'approved' and is_uploaded;

create index if not exists court_photos_moderation_idx
  on public.court_photos (created_at)
  where status = 'pending' and is_uploaded;

-- Uma foto principal por quadra.
create unique index if not exists court_photos_one_primary_per_court
  on public.court_photos (court_id)
  where is_primary;

drop trigger if exists court_photos_set_updated_at on public.court_photos;
create trigger court_photos_set_updated_at
  before update on public.court_photos
  for each row execute function public.set_updated_at();

-- Limite de fotos pendentes por jogador por quadra, para conter flood.
create or replace function public.enforce_photo_quota()
returns trigger
language plpgsql
set search_path = ''
as $$
declare v_pending integer;
begin
  select count(*) into v_pending
  from public.court_photos p
  where p.user_id = new.user_id
    and p.court_id = new.court_id
    and p.status = 'pending';

  if v_pending >= 5 then
    raise exception 'Você já tem 5 fotos aguardando moderação nesta quadra'
      using errcode = 'NQ012';
  end if;

  return new;
end;
$$;

drop trigger if exists court_photos_quota on public.court_photos;
create trigger court_photos_quota
  before insert on public.court_photos
  for each row execute function public.enforce_photo_quota();

-- ---------------------------------------------------------------------
-- Foto principal aprovada alimenta courts.cover_photo_path
--
-- Coluna separada de courts.photo_url de propósito: aqui vai o CAMINHO
-- no Storage (bucket privado), que o cliente troca por uma URL assinada.
-- photo_url continua sendo uma URL pública externa, quando houver.
-- ---------------------------------------------------------------------
alter table public.courts add column if not exists cover_photo_path text;

comment on column public.courts.cover_photo_path is
  'Caminho no bucket court-photos da foto de capa aprovada. Precisa de URL assinada.';
create or replace function public.sync_court_primary_photo()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_court uuid := coalesce(new.court_id, old.court_id);
  v_path  text;
begin
  select p.storage_path into v_path
  from public.court_photos p
  where p.court_id = v_court
    and p.status = 'approved'
    and p.is_uploaded
  order by p.is_primary desc, p.created_at
  limit 1;

  update public.courts
     set cover_photo_path = v_path
   where id = v_court
     and cover_photo_path is distinct from v_path;

  return coalesce(new, old);
end;
$$;

drop trigger if exists court_photos_sync_primary on public.court_photos;
create trigger court_photos_sync_primary
  after insert or update or delete on public.court_photos
  for each row execute function public.sync_court_primary_photo();

comment on function public.sync_court_primary_photo() is
  'Mantém courts.cover_photo_path no caminho da foto de capa aprovada (ou nulo).';

-- ---------------------------------------------------------------------
-- Fotos aprovadas de uma quadra (consumo público)
-- ---------------------------------------------------------------------
create or replace function public.court_photos_page(
  p_court_id uuid,
  p_limit    integer default 20
)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'photo_id',     s.id,
      'storage_path', s.storage_path,
      'caption',      s.caption,
      'width',        s.width,
      'height',       s.height,
      'is_primary',   s.is_primary,
      'created_at',   s.created_at,
      'author', jsonb_build_object(
        'user_id',  s.user_id,
        'username', s.username
      )
    ) order by s.is_primary desc, s.created_at desc),
    '[]'::jsonb
  )
  from (
    select p.id, p.storage_path, p.caption, p.width, p.height, p.is_primary,
           p.created_at, p.user_id, pr.username
    from public.court_photos p
    left join public.profiles pr on pr.id = p.user_id
    where p.court_id = p_court_id
      and p.status = 'approved'
      and p.is_uploaded
    order by p.is_primary desc, p.created_at desc
    limit least(greatest(coalesce(p_limit, 20), 1), 100)
  ) s;
$$;

-- ---------------------------------------------------------------------
-- Moderação (staff/admin)
-- ---------------------------------------------------------------------
create or replace function public.moderate_court_photo(
  p_photo_id uuid,
  p_approve  boolean,
  p_reason   text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_photo public.court_photos%rowtype;
begin
  if not public.is_staff() then
    raise exception 'Ação restrita à operação' using errcode = 'NQ008';
  end if;

  update public.court_photos
     set status        = case when p_approve then 'approved'::public.photo_status
                                             else 'rejected'::public.photo_status end,
         moderated_by  = auth.uid(),
         moderated_at  = now(),
         reject_reason = case when p_approve then null else p_reason end
   where id = p_photo_id
  returning * into v_photo;

  if not found then
    raise exception 'Foto não encontrada' using errcode = 'NQ013';
  end if;

  return jsonb_build_object(
    'photo_id', v_photo.id,
    'court_id', v_photo.court_id,
    'status',   v_photo.status
  );
end;
$$;

create or replace function public.set_primary_court_photo(p_photo_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_photo public.court_photos%rowtype;
begin
  if not public.is_staff() then
    raise exception 'Ação restrita à operação' using errcode = 'NQ008';
  end if;

  select * into v_photo from public.court_photos where id = p_photo_id;
  if not found then
    raise exception 'Foto não encontrada' using errcode = 'NQ013';
  end if;

  if v_photo.status <> 'approved' or not v_photo.is_uploaded then
    raise exception 'Só uma foto aprovada pode ser a principal' using errcode = 'NQ009';
  end if;

  update public.court_photos set is_primary = false
   where court_id = v_photo.court_id and is_primary and id <> p_photo_id;

  update public.court_photos set is_primary = true where id = p_photo_id;

  return jsonb_build_object('photo_id', p_photo_id, 'court_id', v_photo.court_id, 'is_primary', true);
end;
$$;

-- Fila de moderação
create or replace function public.pending_court_photos(p_limit integer default 50)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when public.is_staff() then coalesce(
    (select jsonb_agg(jsonb_build_object(
        'photo_id',     p.id,
        'court_id',     p.court_id,
        'court_name',   c.name,
        'storage_path', p.storage_path,
        'caption',      p.caption,
        'created_at',   p.created_at,
        'author',       jsonb_build_object('user_id', p.user_id, 'username', pr.username)
      ) order by p.created_at)
     from public.court_photos p
     join public.courts c on c.id = p.court_id
     left join public.profiles pr on pr.id = p.user_id
     where p.status = 'pending' and p.is_uploaded
     limit least(greatest(coalesce(p_limit, 50), 1), 200)),
    '[]'::jsonb
  ) else '[]'::jsonb end;
$$;

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.court_photos enable row level security;

drop policy if exists "fotos: aprovadas são públicas" on public.court_photos;
create policy "fotos: aprovadas são públicas"
  on public.court_photos for select
  to anon, authenticated
  using ((status = 'approved' and is_uploaded) or user_id = auth.uid() or public.is_staff());

drop policy if exists "fotos: dono remove a própria" on public.court_photos;
create policy "fotos: dono remove a própria"
  on public.court_photos for delete
  to authenticated
  using (user_id = auth.uid() or public.is_staff());

revoke all on public.court_photos from anon, authenticated;
grant select on public.court_photos to anon, authenticated;
grant delete on public.court_photos to authenticated;

revoke all on function public.moderate_court_photo(uuid, boolean, text) from public;
revoke all on function public.set_primary_court_photo(uuid)             from public;

grant execute on function public.court_photos_page(uuid, integer)             to anon, authenticated;
grant execute on function public.moderate_court_photo(uuid, boolean, text)    to authenticated;
grant execute on function public.set_primary_court_photo(uuid)                to authenticated;
grant execute on function public.pending_court_photos(integer)                to authenticated;

-- ---------------------------------------------------------------------
-- Bucket do Storage
--
-- Privado: o app recebe URLs assinadas. Assim uma foto rejeitada deixa
-- de ser acessível, o que um bucket público não permitiria.
-- Em Postgres puro (CI) o schema storage não existe — daí o guard.
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema = 'storage' and table_name = 'buckets') then

    insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
    values ('court-photos', 'court-photos', false, 10485760,
            array['image/jpeg', 'image/png', 'image/webp'])
    on conflict (id) do update
      set file_size_limit    = excluded.file_size_limit,
          allowed_mime_types = excluded.allowed_mime_types;

    -- Leitura apenas de objetos cuja linha correspondente está aprovada.
    execute $pol$
      drop policy if exists "court-photos: leitura de aprovadas" on storage.objects;
      create policy "court-photos: leitura de aprovadas"
        on storage.objects for select
        to authenticated
        using (
          bucket_id = 'court-photos'
          and exists (
            select 1 from public.court_photos p
            where p.storage_path = storage.objects.name
              and ((p.status = 'approved' and p.is_uploaded)
                   or p.user_id = auth.uid()
                   or public.is_staff())
          )
        );
    $pol$;

    -- O upload em si acontece por URL assinada emitida pela Edge
    -- Function, que usa service_role. O cliente não escreve direto.
    execute $pol$
      drop policy if exists "court-photos: sem escrita direta" on storage.objects;
    $pol$;
  end if;
end $$;
