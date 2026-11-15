-- S3.5 · Qualificar usa as quadras/modalidades do mapa (OSM) quando o dossiê não estimou.
create or replace function public.qualify_prospect(
  p_prospect_id uuid,
  p_pipeline_id uuid,
  p_company_id uuid default null,
  p_company_type public.company_type default null
)
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_p public.prospects;
  v_r public.prospect_research;
  v_company uuid := p_company_id;
  v_location uuid;
  v_stage uuid;
  v_deal uuid;
  v_courts integer;
  v_note text;
begin
  select * into v_p from public.prospects where id = p_prospect_id for update;
  if v_p.id is null then
    raise exception 'Lead não encontrado';
  end if;
  if v_p.status = 'qualified' then
    raise exception 'Este lead já foi qualificado';
  end if;

  select * into v_r from public.prospect_research
  where prospect_id = p_prospect_id order by created_at desc limit 1;

  v_courts := coalesce(v_r.estimated_courts, v_p.mapped_courts);

  if v_company is null then
    insert into public.companies (name, type, website)
    values (v_p.name, coalesce(p_company_type, v_p.company_type, 'club'), v_p.website)
    returning id into v_company;
  end if;

  insert into public.locations (company_id, name, address, city, state, court_count, surfaces, custom)
  values (
    v_company, v_p.name, v_p.address, v_p.city, v_p.state, v_courts,
    case when coalesce(array_length(v_r.court_types, 1), 0) > 0 then v_r.court_types else coalesce(v_p.mapped_sports, '{}') end,
    jsonb_strip_nulls(jsonb_build_object(
      'google_place_id', v_p.google_place_id, 'osm_id', v_p.osm_id,
      'map_url', v_p.google_maps_uri, 'instagram', v_p.instagram, 'prospect_id', v_p.id
    ))
  )
  returning id into v_location;

  select s.id into v_stage from public.stages s where s.pipeline_id = p_pipeline_id order by s.sort_order limit 1;
  if v_stage is null then
    raise exception 'Funil sem etapas';
  end if;

  insert into public.deals (pipeline_id, stage_id, title, company_id, court_count)
  values (p_pipeline_id, v_stage, v_p.name, v_company, v_courts)
  returning id into v_deal;

  insert into public.deal_locations (deal_id, location_id) values (v_deal, v_location);

  if v_r.id is not null then
    v_note := concat_ws(E'\n\n',
      'Dossiê da prospecção (IA)',
      v_r.summary,
      case when jsonb_array_length(v_r.hooks) > 0 then
        'Ganchos:' || E'\n' || (select string_agg('• ' || (h ->> 'title') || coalesce(': ' || (h ->> 'detail'), ''), E'\n') from jsonb_array_elements(v_r.hooks) h)
      end,
      case when jsonb_array_length(v_r.opportunities) > 0 then
        'Oportunidades:' || E'\n' || (select string_agg('• ' || (o ->> 'title') || coalesce(': ' || (o ->> 'detail'), ''), E'\n') from jsonb_array_elements(v_r.opportunities) o)
      end,
      case when v_r.suggested_message is not null then 'Mensagem sugerida:' || E'\n' || v_r.suggested_message end
    );
    insert into public.notes (body, deal_id, company_id) values (v_note, v_deal, v_company);
  end if;

  update public.prospects
  set status = 'qualified', company_id = v_company, deal_id = v_deal, last_error = null
  where id = p_prospect_id;

  return v_deal;
end;
$$;
