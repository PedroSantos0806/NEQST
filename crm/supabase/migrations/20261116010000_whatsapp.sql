-- S5 · WhatsApp (Evolution API): mensagens → linha do tempo do contato; envio pela ficha.

-- Uma mensagem do WhatsApp vira no máximo uma linha na timeline (webhook repetido ou eco do envio).
create unique index timeline_events_whatsapp_wa_id_key
  on public.timeline_events ((payload ->> 'wa_id'))
  where type in ('whatsapp_in', 'whatsapp_out') and payload ? 'wa_id';

-- Conversa ao vivo na ficha.
alter publication supabase_realtime add table public.timeline_events;

-- ---------------------------------------------------------------------------
-- Variações de telefone BR: celular com e sem o 9 (o WhatsApp às vezes usa 55 + DDD + 8 dígitos).
-- ---------------------------------------------------------------------------
create or replace function public.br_phone_variants(p_phone text)
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array_remove(array[
    p_phone,
    case when p_phone ~ '^\+55\d{2}9\d{8}$' then substr(p_phone, 1, 5) || substr(p_phone, 7) end,
    case when p_phone ~ '^\+55\d{2}[6-9]\d{7}$' then substr(p_phone, 1, 5) || '9' || substr(p_phone, 6) end
  ], null);
$$;

-- ---------------------------------------------------------------------------
-- Grava mensagem na timeline do contato (idempotente por wa_id). Usado pelo webhook e pelo envio.
-- ---------------------------------------------------------------------------
create or replace function public.log_whatsapp(p_contact uuid, p_direction text, p_payload jsonb, p_actor uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid;
  v_type public.timeline_event_type := case when p_direction = 'out' then 'whatsapp_out' else 'whatsapp_in' end;
begin
  insert into public.timeline_events (entity, entity_id, type, payload, actor_id, occurred_at)
  values (
    'contact', p_contact, v_type, p_payload, p_actor,
    coalesce(to_timestamp(nullif(p_payload ->> 'ts', '')::double precision), now())
  )
  on conflict ((payload ->> 'wa_id')) where type in ('whatsapp_in', 'whatsapp_out') and payload ? 'wa_id'
  do update set
    payload = public.timeline_events.payload || excluded.payload,
    actor_id = coalesce(excluded.actor_id, public.timeline_events.actor_id)
  returning id into v_id;
  return v_id;
end;
$$;
revoke execute on function public.log_whatsapp(uuid, text, jsonb, uuid) from public, anon, authenticated;
grant execute on function public.log_whatsapp(uuid, text, jsonb, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Processa mensagem recebida pela Evolution (inbound_events.source = 'evolution').
-- normalized: phone (E.164), text, from_me, wa_id, push_name, type, ts
-- Número que não é contato do CRM → 'ignored' (conversas pessoais não entram).
-- ---------------------------------------------------------------------------
create or replace function public.process_whatsapp_event(p_event_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  e public.inbound_events;
  n jsonb;
  v_contact uuid;
begin
  select * into e from public.inbound_events where id = p_event_id for update;
  if e.id is null then
    raise exception 'Evento % não encontrado', p_event_id;
  end if;
  if e.status = 'processed' then
    return e.contact_id;
  end if;
  n := e.normalized;

  begin
    if coalesce(n ->> 'phone', '') = '' then
      raise exception 'Mensagem sem telefone identificável';
    end if;

    select c.id into v_contact
    from public.contacts c
    where c.phone = any(public.br_phone_variants(n ->> 'phone'))
    order by c.created_at
    limit 1;

    if v_contact is null then
      update public.inbound_events
      set status = 'ignored', attempts = attempts + 1, error = 'Número não é contato do CRM', processed_at = now()
      where id = e.id;
      return null;
    end if;

    perform public.log_whatsapp(
      v_contact,
      case when (n ->> 'from_me')::boolean then 'out' else 'in' end,
      jsonb_strip_nulls(jsonb_build_object(
        'wa_id', n ->> 'wa_id', 'text', n ->> 'text', 'type', n ->> 'type', 'push_name', n ->> 'push_name',
        'phone', n ->> 'phone', 'ts', n ->> 'ts', 'sent_via', case when (n ->> 'from_me')::boolean then 'phone' end
      ))
    );

    update public.inbound_events
    set status = 'processed', contact_id = v_contact, processed_at = now(), attempts = attempts + 1, error = null
    where id = e.id;
    return v_contact;
  exception when others then
    update public.inbound_events set status = 'failed', attempts = attempts + 1, error = sqlerrm where id = e.id;
    return null;
  end;
end;
$$;
revoke execute on function public.process_whatsapp_event(uuid) from public, anon;
grant execute on function public.process_whatsapp_event(uuid) to authenticated, service_role;

-- O "Reprocessar" da tela usa process_inbound_event: encaminha mensagens do WhatsApp.
-- (Também permite reprocessar uma mensagem ignorada depois de cadastrar o contato.)
create or replace function public.reprocess_inbound_event(p_event_id uuid)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_source public.inbound_source;
begin
  select source into v_source from public.inbound_events where id = p_event_id;
  if v_source = 'evolution' then
    update public.inbound_events set status = 'pending' where id = p_event_id and status = 'ignored';
    return public.process_whatsapp_event(p_event_id);
  end if;
  return public.process_inbound_event(p_event_id);
end;
$$;
revoke execute on function public.reprocess_inbound_event(uuid) from public, anon;
grant execute on function public.reprocess_inbound_event(uuid) to authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Token do webhook da Evolution (vai na URL: ?token=...), no Vault; aparece para admin.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from vault.secrets where name = 'inbound_evolution_token') then
    perform vault.create_secret(encode(extensions.gen_random_bytes(24), 'hex'), 'inbound_evolution_token',
      'Token do webhook da Evolution API (parâmetro ?token= na URL)');
  end if;
end;
$$;

create or replace function public.inbound_settings()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.profiles p where p.id = auth.uid() and p.role = 'admin') then
    raise exception 'Só administradores veem os tokens de integração' using errcode = '42501';
  end if;
  return jsonb_build_object(
    'site_token', public.inbound_secret('site_token'),
    'google_key', public.inbound_secret('google_key'),
    'meta_verify_token', public.inbound_secret('meta_verify_token'),
    'evolution_token', public.inbound_secret('evolution_token')
  );
end;
$$;
