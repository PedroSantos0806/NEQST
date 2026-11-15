-- S2 · Kanban: Realtime no quadro e campos obrigatórios por etapa.

-- ---------------------------------------------------------------------------
-- Realtime: mudanças de negócios (e do que aparece no card) chegam aos outros usuários.
-- RLS continua valendo para as mensagens do Realtime.
-- ---------------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    create publication supabase_realtime;
  end if;
end;
$$;

alter publication supabase_realtime add table public.deals, public.deal_locations, public.activities;

-- ---------------------------------------------------------------------------
-- Campos obrigatórios por etapa
-- stages.required_fields = array de chaves. Chaves aceitas:
--   colunas de deals: company_id, court_count, price_per_court, value, expected_close_date, owner_id
--   relações:         locations (≥1 local), contacts (≥1 contato), decision_maker (contato com papel decisor)
--   campos custom:    custom.<chave>
-- Regra: ao AVANÇAR para uma etapa (ordem maior no mesmo funil, ou entrar num funil),
-- o negócio precisa ter todos os campos exigidos pela etapa de destino.
-- ---------------------------------------------------------------------------
-- p_check_relations = false na criação: locais/contatos são gravados depois do negócio.
create or replace function public.deal_missing_fields(p_deal public.deals, p_stage_id uuid, p_check_relations boolean default true)
returns text[]
language plpgsql
stable
set search_path = ''
as $$
declare
  v_required jsonb;
  v_key text;
  v_missing text[] := '{}';
  v_row jsonb := to_jsonb(p_deal);
begin
  select s.required_fields into v_required from public.stages s where s.id = p_stage_id;
  if v_required is null then
    return v_missing;
  end if;

  for v_key in select jsonb_array_elements_text(v_required) loop
    if not p_check_relations and v_key in ('locations', 'contacts', 'decision_maker') then
      continue;
    end if;
    if v_key = 'locations' then
      if not exists (select 1 from public.deal_locations dl where dl.deal_id = p_deal.id) then
        v_missing := v_missing || v_key;
      end if;
    elsif v_key = 'contacts' then
      if not exists (select 1 from public.deal_contacts dc where dc.deal_id = p_deal.id) then
        v_missing := v_missing || v_key;
      end if;
    elsif v_key = 'decision_maker' then
      if not exists (select 1 from public.deal_contacts dc where dc.deal_id = p_deal.id and dc.role = 'decision_maker') then
        v_missing := v_missing || v_key;
      end if;
    elsif v_key like 'custom.%' then
      if nullif(trim(p_deal.custom ->> substr(v_key, 8)), '') is null then
        v_missing := v_missing || v_key;
      end if;
    elsif v_row ? v_key then
      if nullif(trim(v_row ->> v_key), '') is null then
        v_missing := v_missing || v_key;
      end if;
    end if;
  end loop;

  return v_missing;
end;
$$;

create or replace function public.deals_check_required_fields()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  v_old_order integer;
  v_new_order integer;
  v_missing text[];
begin
  if tg_op = 'UPDATE' and new.stage_id is not distinct from old.stage_id then
    return new;
  end if;

  select s.sort_order into v_new_order from public.stages s where s.id = new.stage_id;
  if tg_op = 'UPDATE' and new.pipeline_id = old.pipeline_id then
    select s.sort_order into v_old_order from public.stages s where s.id = old.stage_id;
    if v_new_order <= v_old_order then
      return new; -- voltar etapa nunca é bloqueado
    end if;
  end if;

  v_missing := public.deal_missing_fields(new, new.stage_id, tg_op = 'UPDATE');
  if cardinality(v_missing) > 0 then
    raise exception 'Campos obrigatórios para esta etapa: %', array_to_string(v_missing, ', ')
      using errcode = 'P0422', detail = array_to_string(v_missing, ','), hint = 'required_fields';
  end if;
  return new;
end;
$$;

-- Roda depois do deals_before_write (ordem alfabética dos triggers BEFORE), já com o valor calculado.
create trigger deals_zz_check_required_fields
  before insert or update of stage_id on public.deals
  for each row execute function public.deals_check_required_fields();
