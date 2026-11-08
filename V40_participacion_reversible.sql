-- ============================================================
-- V40 - PARTICIPACION REVERSIBLE
-- "No participa" ya no borra personas.
-- Ejecutar completa en Supabase SQL Editor
-- Requiere V39 aplicada.
-- ============================================================

begin;

-- 1) Estado reversible de participacion
alter table public.secret_santa_people
  add column if not exists is_active boolean not null default true;

-- Compatibilidad: todo lo existente sigue participando
update public.secret_santa_people
set is_active=true
where is_active is null;

-- 2) Compatibilidad con el antiguo RPC "remove_person":
-- desde ahora NO elimina, solo marca No participa.
drop function if exists public.secret_santa_app_remove_person(uuid,uuid);

create function public.secret_santa_app_remove_person(
  p_exchange_id uuid,
  p_person_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.secret_santa_app_set_participation(
    p_exchange_id,
    p_person_id,
    false
  );
end;
$$;

-- 3) Activar / desactivar participacion
drop function if exists public.secret_santa_app_set_participation(uuid,uuid,boolean);

create function public.secret_santa_app_set_participation(
  p_exchange_id uuid,
  p_person_id uuid,
  p_participates boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_current boolean;
begin
  select *
  into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;

  perform public.secret_santa_v37_assert_not_locked(p_exchange_id);

  select is_active
  into v_current
  from public.secret_santa_people
  where id=p_person_id
    and exchange_id=p_exchange_id;

  if not found then
    raise exception 'Participante no encontrado';
  end if;

  if coalesce(v_current,true)=coalesce(p_participates,false) then
    return;
  end if;

  -- Si había sorteo editable, cualquier cambio de participación
  -- lo invalida y elimina también la preparación de entrega.
  if coalesce(v_exchange.draw_finalized,false) then
    perform public.secret_santa_v37_invalidate_draw(p_exchange_id);
  end if;

  update public.secret_santa_people
  set is_active=coalesce(p_participates,false)
  where id=p_person_id
    and exchange_id=p_exchange_id;

  -- No se borra regalo, número, grupo, token ni exclusiones.
end;
$$;

-- 4) SORTEO: solo personas activas
drop function if exists public.secret_santa_app_finalize_v2(uuid,jsonb,integer);

create function public.secret_santa_app_finalize_v2(
  p_exchange_id uuid,
  p_assignments jsonb,
  p_same_group_conflicts integer default 0
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_expected_count integer;
  v_assignment_count integer;
  v_unique_people integer;
  v_unique_recipients integer;
  v_bad integer;
begin
  select *
  into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;

  perform public.secret_santa_v37_assert_not_locked(p_exchange_id);

  if v_exchange.draw_mode='gift_numbers' then
    select count(*)
    into v_expected_count
    from public.secret_santa_people
    where exchange_id=p_exchange_id
      and is_active=true
      and brought_gift=true
      and gift_number is not null;
  else
    select count(*)
    into v_expected_count
    from public.secret_santa_people
    where exchange_id=p_exchange_id
      and is_active=true;
  end if;

  if v_expected_count<2 then
    if v_exchange.draw_mode='gift_numbers' then
      raise exception 'Se necesitan al menos 2 participantes activos que hayan entregado regalo';
    else
      raise exception 'Se necesitan al menos 2 participantes activos';
    end if;
  end if;

  if p_assignments is null
     or jsonb_typeof(p_assignments)<>'array' then
    raise exception 'Asignaciones no válidas';
  end if;

  select
    count(*),
    count(distinct (x->>'person_id')),
    count(distinct (x->>'assigned_person_id'))
  into
    v_assignment_count,
    v_unique_people,
    v_unique_recipients
  from jsonb_array_elements(p_assignments) x;

  if v_assignment_count<>v_expected_count
     or v_unique_people<>v_expected_count
     or v_unique_recipients<>v_expected_count then
    raise exception 'El sorteo no contiene exactamente todos los participantes válidos';
  end if;

  if v_exchange.draw_mode='gift_numbers' then
    select count(*)
    into v_bad
    from jsonb_array_elements(p_assignments) x

    left join public.secret_santa_people p
      on p.id=(x->>'person_id')::uuid
     and p.exchange_id=p_exchange_id
     and p.is_active=true
     and p.brought_gift=true
     and p.gift_number is not null

    left join public.secret_santa_people r
      on r.id=(x->>'assigned_person_id')::uuid
     and r.exchange_id=p_exchange_id
     and r.is_active=true
     and r.brought_gift=true
     and r.gift_number is not null

    where p.id is null
       or r.id is null
       or p.id=r.id;
  else
    select count(*)
    into v_bad
    from jsonb_array_elements(p_assignments) x

    left join public.secret_santa_people p
      on p.id=(x->>'person_id')::uuid
     and p.exchange_id=p_exchange_id
     and p.is_active=true

    left join public.secret_santa_people r
      on r.id=(x->>'assigned_person_id')::uuid
     and r.exchange_id=p_exchange_id
     and r.is_active=true

    where p.id is null
       or r.id is null
       or p.id=r.id;
  end if;

  if v_bad>0 then
    raise exception 'El sorteo contiene participantes no válidos, inactivos o un autorregalo';
  end if;

  select count(*)
  into v_bad
  from jsonb_array_elements(p_assignments) x
  join public.secret_santa_exclusions ex
    on ex.exchange_id=p_exchange_id
   and (
      (
        ex.person_a_id=(x->>'person_id')::uuid
        and ex.person_b_id=(x->>'assigned_person_id')::uuid
      )
      or
      (
        ex.person_b_id=(x->>'person_id')::uuid
        and ex.person_a_id=(x->>'assigned_person_id')::uuid
      )
   );

  if v_bad>0 then
    raise exception 'El sorteo incumple una exclusión configurada';
  end if;

  update public.secret_santa_people
  set
    assigned_person_id=null,
    assigned_gift_number=null,
    delivered_at=null,
    delivery_order=null
  where exchange_id=p_exchange_id;

  update public.secret_santa_people p
  set assigned_person_id=x.assigned_person_id
  from (
    select
      (j->>'person_id')::uuid as person_id,
      (j->>'assigned_person_id')::uuid as assigned_person_id
    from jsonb_array_elements(p_assignments) j
  ) x
  where p.id=x.person_id
    and p.exchange_id=p_exchange_id
    and p.is_active=true;

  update public.secret_santa_exchanges
  set
    draw_finalized=true,
    drawn_at=now(),
    same_group_conflicts=greatest(coalesce(p_same_group_conflicts,0),0),
    delivery_locked=false,
    delivery_started_at=null,
    delivery_paused=false,
    delivery_closed_at=null,
    delivery_prepared_at=null,
    current_delivery_person_id=null,
    delivery_revealed=false
  where id=p_exchange_id;
end;
$$;

-- 5) PREPARAR ENTREGA: solo personas activas
drop function if exists public.secret_santa_app_start_delivery(uuid,uuid[]);

create function public.secret_santa_app_start_delivery(
  p_exchange_id uuid,
  p_order uuid[]
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_expected integer;
  v_received integer;
  v_valid integer;
  v_first uuid;
begin
  select *
  into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;

  if not coalesce(v_exchange.draw_finalized,false) then
    raise exception 'Primero debes realizar el sorteo';
  end if;

  if v_exchange.delivery_closed_at is not null then
    raise exception 'El Amigo invisible ya está finalizado';
  end if;

  -- Nunca regenerar una cola ya preparada.
  if v_exchange.delivery_prepared_at is not null then
    return;
  end if;

  if v_exchange.draw_mode='classic' then
    select count(*)
    into v_expected
    from public.secret_santa_people
    where exchange_id=p_exchange_id
      and is_active=true;
  else
    select count(*)
    into v_expected
    from public.secret_santa_people
    where exchange_id=p_exchange_id
      and is_active=true
      and brought_gift=true
      and gift_number is not null
      and assigned_person_id is not null;
  end if;

  v_received:=coalesce(cardinality(p_order),0);

  if v_received<>v_expected then
    raise exception 'El orden de entrega no contiene exactamente todos los participantes incluidos';
  end if;

  select count(distinct x.id)
  into v_valid
  from unnest(p_order) as x(id);

  if v_valid<>v_expected then
    raise exception 'El orden de entrega contiene participantes duplicados';
  end if;

  if v_exchange.draw_mode='classic' then
    select count(*)
    into v_valid
    from unnest(p_order) x(id)
    join public.secret_santa_people p
      on p.id=x.id
     and p.exchange_id=p_exchange_id
     and p.is_active=true;
  else
    select count(*)
    into v_valid
    from unnest(p_order) x(id)
    join public.secret_santa_people p
      on p.id=x.id
     and p.exchange_id=p_exchange_id
     and p.is_active=true
     and p.brought_gift=true
     and p.gift_number is not null
     and p.assigned_person_id is not null;
  end if;

  if v_valid<>v_expected then
    raise exception 'El orden contiene participantes que no forman parte del sorteo';
  end if;

  update public.secret_santa_people
  set delivery_order=null
  where exchange_id=p_exchange_id;

  update public.secret_santa_people p
  set delivery_order=q.ord::integer
  from (
    select u.id,u.ord
    from unnest(p_order) with ordinality as u(id,ord)
  ) q
  where p.id=q.id
    and p.exchange_id=p_exchange_id
    and p.is_active=true;

  v_first:=case
    when cardinality(p_order)>0 then p_order[1]
    else null
  end;

  update public.secret_santa_exchanges
  set
    delivery_prepared_at=now(),
    delivery_paused=false,
    current_delivery_person_id=v_first,
    delivery_revealed=false
  where id=p_exchange_id;
end;
$$;

-- 6) ENTREGA: no mostrar personas No participa
drop function if exists public.secret_santa_app_delivery(uuid);

create function public.secret_santa_app_delivery(
  p_exchange_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_people jsonb;
begin
  select *
  into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;

  if not coalesce(v_exchange.draw_finalized,false) then
    raise exception 'Primero debes realizar el sorteo';
  end if;

  if v_exchange.draw_mode='classic' then
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'person_id',recipient.id,
          'person_name',recipient.name,
          'delivered_at',recipient.delivered_at,
          'delivery_order',recipient.delivery_order,
          'gift_number',giver.gift_number,
          'has_gift',
            coalesce(giver.brought_gift,false)
            and giver.gift_number is not null,
          'gift_owner_id',giver.id,
          'gift_owner_name',giver.name
        )
        order by recipient.delivery_order nulls last,recipient.name
      ),
      '[]'::jsonb
    )
    into v_people
    from public.secret_santa_people recipient

    left join public.secret_santa_people giver
      on giver.exchange_id=p_exchange_id
     and giver.assigned_person_id=recipient.id
     and giver.is_active=true

    where recipient.exchange_id=p_exchange_id
      and recipient.is_active=true
      and recipient.assigned_person_id is not null;

  else
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'person_id',receiver.id,
          'person_name',receiver.name,
          'delivered_at',receiver.delivered_at,
          'delivery_order',receiver.delivery_order,
          'gift_number',gift_owner.gift_number,
          'has_gift',true,
          'gift_owner_id',gift_owner.id,
          'gift_owner_name',gift_owner.name
        )
        order by receiver.delivery_order nulls last,receiver.name
      ),
      '[]'::jsonb
    )
    into v_people
    from public.secret_santa_people receiver

    join public.secret_santa_people gift_owner
      on gift_owner.id=receiver.assigned_person_id
     and gift_owner.exchange_id=p_exchange_id
     and gift_owner.is_active=true
     and gift_owner.brought_gift=true
     and gift_owner.gift_number is not null

    where receiver.exchange_id=p_exchange_id
      and receiver.is_active=true
      and receiver.brought_gift=true
      and receiver.gift_number is not null
      and receiver.assigned_person_id is not null;
  end if;

  return jsonb_build_object(
    'exchange',
    jsonb_build_object(
      'id',v_exchange.id,
      'name',v_exchange.name,
      'event_date',v_exchange.event_date,
      'draw_mode',v_exchange.draw_mode,
      'draw_finalized',v_exchange.draw_finalized,
      'delivery_locked',v_exchange.delivery_locked,
      'delivery_started_at',v_exchange.delivery_started_at,
      'delivery_paused',v_exchange.delivery_paused,
      'delivery_closed_at',v_exchange.delivery_closed_at,
      'delivery_prepared_at',v_exchange.delivery_prepared_at,
      'current_delivery_person_id',v_exchange.current_delivery_person_id,
      'delivery_revealed',v_exchange.delivery_revealed
    ),
    'people',v_people
  );
end;
$$;

-- 7) MARCAR ENTREGA: exigir participante activo
drop function if exists public.secret_santa_app_set_delivered(uuid,uuid,boolean);

create function public.secret_santa_app_set_delivered(
  p_exchange_id uuid,
  p_person_id uuid,
  p_delivered boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_has_gift boolean:=false;
  v_next uuid;
begin
  select *
  into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;

  if not coalesce(v_exchange.draw_finalized,false) then
    raise exception 'Primero debes realizar el sorteo';
  end if;

  if v_exchange.delivery_closed_at is not null then
    raise exception 'El Amigo invisible ya está finalizado';
  end if;

  if v_exchange.draw_mode='classic' then
    select exists(
      select 1
      from public.secret_santa_people recipient
      join public.secret_santa_people giver
        on giver.exchange_id=p_exchange_id
       and giver.assigned_person_id=recipient.id
       and giver.is_active=true
       and giver.brought_gift=true
       and giver.gift_number is not null
      where recipient.id=p_person_id
        and recipient.exchange_id=p_exchange_id
        and recipient.is_active=true
        and recipient.assigned_person_id is not null
    )
    into v_has_gift;
  else
    select exists(
      select 1
      from public.secret_santa_people receiver
      join public.secret_santa_people gift_owner
        on gift_owner.id=receiver.assigned_person_id
       and gift_owner.exchange_id=p_exchange_id
       and gift_owner.is_active=true
       and gift_owner.brought_gift=true
       and gift_owner.gift_number is not null
      where receiver.id=p_person_id
        and receiver.exchange_id=p_exchange_id
        and receiver.is_active=true
        and receiver.brought_gift=true
        and receiver.gift_number is not null
    )
    into v_has_gift;
  end if;

  if coalesce(p_delivered,false) then
    if not v_has_gift then
      raise exception 'El regalo físico todavía no está disponible para esta persona';
    end if;

    if not coalesce(v_exchange.delivery_locked,false) then
      update public.secret_santa_exchanges
      set
        delivery_locked=true,
        delivery_started_at=coalesce(delivery_started_at,now()),
        delivery_paused=false
      where id=p_exchange_id;
    end if;

    update public.secret_santa_people
    set delivered_at=coalesce(delivered_at,now())
    where id=p_person_id
      and exchange_id=p_exchange_id
      and is_active=true;
  else
    update public.secret_santa_people
    set delivered_at=null
    where id=p_person_id
      and exchange_id=p_exchange_id
      and is_active=true;
  end if;

  select p.id
  into v_next
  from public.secret_santa_people p
  where p.exchange_id=p_exchange_id
    and p.is_active=true
    and p.delivered_at is null
    and p.delivery_order is not null
  order by p.delivery_order,p.created_at
  limit 1;

  update public.secret_santa_exchanges
  set
    current_delivery_person_id=v_next,
    delivery_revealed=false
  where id=p_exchange_id;
end;
$$;

-- 8) CIERRE: solo los participantes activos incluidos
drop function if exists public.secret_santa_app_close_delivery(uuid);

create function public.secret_santa_app_close_delivery(
  p_exchange_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_total integer;
  v_delivered integer;
begin
  select *
  into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;

  if not coalesce(v_exchange.draw_finalized,false) then
    raise exception 'Primero debes realizar el sorteo';
  end if;

  if v_exchange.delivery_closed_at is not null then
    return;
  end if;

  if v_exchange.draw_mode='classic' then
    select
      count(*),
      count(*) filter(where delivered_at is not null)
    into v_total,v_delivered
    from public.secret_santa_people
    where exchange_id=p_exchange_id
      and is_active=true
      and assigned_person_id is not null;
  else
    select
      count(*),
      count(*) filter(where delivered_at is not null)
    into v_total,v_delivered
    from public.secret_santa_people
    where exchange_id=p_exchange_id
      and is_active=true
      and brought_gift=true
      and gift_number is not null
      and assigned_person_id is not null;
  end if;

  if v_total=0 then
    raise exception 'No hay participantes incluidos en la entrega';
  end if;

  if v_delivered<>v_total then
    raise exception 'Todavía existen participantes pendientes de recibir su regalo';
  end if;

  update public.secret_santa_exchanges
  set
    delivery_locked=true,
    delivery_paused=false,
    delivery_closed_at=now(),
    delivery_started_at=coalesce(delivery_started_at,now()),
    current_delivery_person_id=null,
    delivery_revealed=false
  where id=p_exchange_id;
end;
$$;

-- 9) PARTICIPANTE ACTUAL: exigir activo
drop function if exists public.secret_santa_app_set_delivery_current(uuid,uuid,boolean);

create function public.secret_santa_app_set_delivery_current(
  p_exchange_id uuid,
  p_person_id uuid,
  p_revealed boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.secret_santa_exchanges;
begin
  select *
  into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;

  if v_exchange.delivery_closed_at is not null then
    raise exception 'El Amigo invisible ya está finalizado';
  end if;

  if v_exchange.delivery_prepared_at is null then
    raise exception 'La entrega todavía no está preparada';
  end if;

  if not exists(
    select 1
    from public.secret_santa_people p
    where p.id=p_person_id
      and p.exchange_id=p_exchange_id
      and p.is_active=true
      and p.delivery_order is not null
      and p.delivered_at is null
  ) then
    raise exception 'Participante pendiente no válido';
  end if;

  update public.secret_santa_exchanges
  set
    current_delivery_person_id=p_person_id,
    delivery_revealed=coalesce(p_revealed,false)
  where id=p_exchange_id;
end;
$$;

-- 10) SALTAR: exigir activo
drop function if exists public.secret_santa_app_skip_delivery(uuid,uuid);

create function public.secret_santa_app_skip_delivery(
  p_exchange_id uuid,
  p_person_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_max integer;
  v_next uuid;
begin
  select *
  into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;

  if v_exchange.delivery_closed_at is not null then
    raise exception 'El Amigo invisible ya está finalizado';
  end if;

  if not exists(
    select 1
    from public.secret_santa_people p
    where p.id=p_person_id
      and p.exchange_id=p_exchange_id
      and p.is_active=true
      and p.delivered_at is null
      and p.delivery_order is not null
  ) then
    raise exception 'Participante pendiente no válido';
  end if;

  select coalesce(max(delivery_order),0)
  into v_max
  from public.secret_santa_people
  where exchange_id=p_exchange_id
    and is_active=true;

  update public.secret_santa_people
  set delivery_order=v_max+1
  where id=p_person_id
    and exchange_id=p_exchange_id
    and is_active=true;

  select p.id
  into v_next
  from public.secret_santa_people p
  where p.exchange_id=p_exchange_id
    and p.is_active=true
    and p.delivered_at is null
    and p.delivery_order is not null
  order by p.delivery_order,p.created_at
  limit 1;

  update public.secret_santa_exchanges
  set
    current_delivery_person_id=v_next,
    delivery_revealed=false
  where id=p_exchange_id;
end;
$$;

-- 11) Permisos
grant execute
on function public.secret_santa_app_set_participation(uuid,uuid,boolean)
to anon,authenticated;

grant execute
on function public.secret_santa_app_remove_person(uuid,uuid)
to anon,authenticated;

grant execute
on function public.secret_santa_app_finalize_v2(uuid,jsonb,integer)
to anon,authenticated;

grant execute
on function public.secret_santa_app_start_delivery(uuid,uuid[])
to anon,authenticated;

grant execute
on function public.secret_santa_app_delivery(uuid)
to anon,authenticated;

grant execute
on function public.secret_santa_app_set_delivered(uuid,uuid,boolean)
to anon,authenticated;

grant execute
on function public.secret_santa_app_close_delivery(uuid)
to anon,authenticated;

grant execute
on function public.secret_santa_app_set_delivery_current(uuid,uuid,boolean)
to anon,authenticated;

grant execute
on function public.secret_santa_app_skip_delivery(uuid,uuid)
to anon,authenticated;

commit;

select 'V40 PARTICIPACION REVERSIBLE OK' as resultado;
