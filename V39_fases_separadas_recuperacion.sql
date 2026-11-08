-- ============================================================
-- V39 - FASES SEPARADAS + RECUPERACION EXACTA DE ENTREGA
-- Ejecutar completa en Supabase SQL Editor
-- ============================================================

begin;

-- 1) Columnas acumulativas de entrega
alter table public.secret_santa_exchanges
  add column if not exists delivery_locked boolean not null default false;
alter table public.secret_santa_exchanges
  add column if not exists delivery_started_at timestamptz null;
alter table public.secret_santa_exchanges
  add column if not exists delivery_paused boolean not null default false;
alter table public.secret_santa_exchanges
  add column if not exists delivery_closed_at timestamptz null;
alter table public.secret_santa_exchanges
  add column if not exists delivery_prepared_at timestamptz null;
alter table public.secret_santa_exchanges
  add column if not exists current_delivery_person_id uuid null;
alter table public.secret_santa_exchanges
  add column if not exists delivery_revealed boolean not null default false;

alter table public.secret_santa_people
  add column if not exists delivered_at timestamptz null;
alter table public.secret_santa_people
  add column if not exists delivery_order integer null;

-- 2) Helpers compatibles con V37/V38
create or replace function public.secret_santa_v37_assert_not_locked(p_exchange_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_locked boolean;
  v_closed timestamptz;
begin
  select delivery_locked, delivery_closed_at
    into v_locked, v_closed
  from public.secret_santa_exchanges
  where id = p_exchange_id;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;

  if v_closed is not null then
    raise exception 'El Amigo invisible ya está finalizado.';
  end if;

  if coalesce(v_locked,false) then
    raise exception 'La entrega ya ha comenzado. El sorteo está bloqueado definitivamente.';
  end if;
end;
$$;

create or replace function public.secret_santa_v37_invalidate_draw(p_exchange_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.secret_santa_v37_assert_not_locked(p_exchange_id);

  update public.secret_santa_people
  set
    assigned_person_id = null,
    assigned_gift_number = null,
    delivered_at = null,
    delivery_order = null
  where exchange_id = p_exchange_id;

  update public.secret_santa_exchanges
  set
    draw_finalized = false,
    drawn_at = null,
    same_group_conflicts = 0,
    delivery_paused = false,
    delivery_prepared_at = null,
    current_delivery_person_id = null,
    delivery_revealed = false,
    delivery_started_at = null,
    delivery_closed_at = null
  where id = p_exchange_id;
end;
$$;

-- Si existían helpers V38, mantenerlos alineados
create or replace function public.secret_santa_v38_assert_not_locked(p_exchange_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.secret_santa_v37_assert_not_locked(p_exchange_id);
end;
$$;

create or replace function public.secret_santa_v38_invalidate_draw(p_exchange_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public.secret_santa_v37_invalidate_draw(p_exchange_id);
end;
$$;

-- 3) HOME: incluye el estado suficiente para reanudar desde portada
drop function if exists public.secret_santa_app_home();

create function public.secret_santa_app_home()
returns jsonb
language sql
security definer
set search_path = public
as $$
select jsonb_build_object(
  'exchanges',
  coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id',e.id,
        'meeting_id',e.meeting_id,
        'name',e.name,
        'event_date',e.event_date,
        'min_amount',e.min_amount,
        'max_amount',e.max_amount,
        'draw_finalized',e.draw_finalized,
        'drawn_at',e.drawn_at,
        'draw_mode',e.draw_mode,
        'same_group_conflicts',e.same_group_conflicts,
        'delivery_locked',e.delivery_locked,
        'delivery_started_at',e.delivery_started_at,
        'delivery_paused',e.delivery_paused,
        'delivery_closed_at',e.delivery_closed_at,
        'delivery_prepared_at',e.delivery_prepared_at,
        'current_delivery_person_id',e.current_delivery_person_id,
        'delivery_revealed',e.delivery_revealed,
        'created_at',e.created_at,
        'meeting_name',m.name,
        'meeting_date',m.meeting_date
      )
      order by coalesce(e.event_date,m.meeting_date) desc nulls last, e.created_at desc
    )
    from public.secret_santa_exchanges e
    left join public.meetings m on m.id=e.meeting_id
  ),'[]'::jsonb),

  'available_meetings',
  coalesce((
    select jsonb_agg(
      jsonb_build_object(
        'id',m.id,
        'name',m.name,
        'meeting_date',m.meeting_date
      )
      order by m.meeting_date
    )
    from public.meetings m
    where lower(trim(coalesce(m.status,'')))='activa'
      and not exists(
        select 1
        from public.secret_santa_exchanges e
        where e.meeting_id=m.id
      )
  ),'[]'::jsonb)
);
$$;

-- 4) FINALIZAR / REHACER SORTEO
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
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  perform public.secret_santa_v37_assert_not_locked(p_exchange_id);

  if v_exchange.draw_mode='gift_numbers' then
    select count(*) into v_expected_count
    from public.secret_santa_people
    where exchange_id=p_exchange_id
      and brought_gift=true
      and gift_number is not null;
  else
    select count(*) into v_expected_count
    from public.secret_santa_people
    where exchange_id=p_exchange_id;
  end if;

  if v_expected_count<2 then
    if v_exchange.draw_mode='gift_numbers' then
      raise exception 'Se necesitan al menos 2 participantes que hayan entregado regalo';
    else
      raise exception 'Se necesitan al menos 2 participantes';
    end if;
  end if;

  if p_assignments is null or jsonb_typeof(p_assignments)<>'array' then
    raise exception 'Asignaciones no válidas';
  end if;

  select
    count(*),
    count(distinct (x->>'person_id')),
    count(distinct (x->>'assigned_person_id'))
  into v_assignment_count,v_unique_people,v_unique_recipients
  from jsonb_array_elements(p_assignments) x;

  if v_assignment_count<>v_expected_count
     or v_unique_people<>v_expected_count
     or v_unique_recipients<>v_expected_count then
    raise exception 'El sorteo no contiene exactamente todos los participantes válidos';
  end if;

  if v_exchange.draw_mode='gift_numbers' then
    select count(*) into v_bad
    from jsonb_array_elements(p_assignments) x
    left join public.secret_santa_people p
      on p.id=(x->>'person_id')::uuid
     and p.exchange_id=p_exchange_id
     and p.brought_gift=true
     and p.gift_number is not null
    left join public.secret_santa_people r
      on r.id=(x->>'assigned_person_id')::uuid
     and r.exchange_id=p_exchange_id
     and r.brought_gift=true
     and r.gift_number is not null
    where p.id is null or r.id is null or p.id=r.id;
  else
    select count(*) into v_bad
    from jsonb_array_elements(p_assignments) x
    left join public.secret_santa_people p
      on p.id=(x->>'person_id')::uuid
     and p.exchange_id=p_exchange_id
    left join public.secret_santa_people r
      on r.id=(x->>'assigned_person_id')::uuid
     and r.exchange_id=p_exchange_id
    where p.id is null or r.id is null or p.id=r.id;
  end if;

  if v_bad>0 then
    raise exception 'El sorteo contiene participantes no válidos o un autorregalo';
  end if;

  select count(*) into v_bad
  from jsonb_array_elements(p_assignments) x
  join public.secret_santa_exclusions ex
    on ex.exchange_id=p_exchange_id
   and (
      (ex.person_a_id=(x->>'person_id')::uuid and ex.person_b_id=(x->>'assigned_person_id')::uuid)
      or
      (ex.person_b_id=(x->>'person_id')::uuid and ex.person_a_id=(x->>'assigned_person_id')::uuid)
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
      (j->>'person_id')::uuid person_id,
      (j->>'assigned_person_id')::uuid assigned_person_id
    from jsonb_array_elements(p_assignments) j
  ) x
  where p.id=x.person_id
    and p.exchange_id=p_exchange_id;

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

-- 5) PREPARAR ENTREGA: crea la cola una sola vez
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
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  if not coalesce(v_exchange.draw_finalized,false) then
    raise exception 'Primero debes realizar el sorteo';
  end if;
  if v_exchange.delivery_closed_at is not null then
    raise exception 'El Amigo invisible ya está finalizado';
  end if;

  -- Si ya estaba preparada, jamás regenerar la cola al volver a entrar.
  if v_exchange.delivery_prepared_at is not null then
    return;
  end if;

  if v_exchange.draw_mode='classic' then
    select count(*) into v_expected
    from public.secret_santa_people
    where exchange_id=p_exchange_id;
  else
    select count(*) into v_expected
    from public.secret_santa_people
    where exchange_id=p_exchange_id
      and brought_gift=true
      and gift_number is not null
      and assigned_person_id is not null;
  end if;

  v_received:=coalesce(cardinality(p_order),0);
  if v_received<>v_expected then
    raise exception 'El orden de entrega no contiene exactamente todos los participantes incluidos';
  end if;

  select count(distinct x.id) into v_valid
  from unnest(p_order) as x(id);

  if v_valid<>v_expected then
    raise exception 'El orden de entrega contiene participantes duplicados';
  end if;

  if v_exchange.draw_mode='classic' then
    select count(*) into v_valid
    from unnest(p_order) x(id)
    join public.secret_santa_people p
      on p.id=x.id and p.exchange_id=p_exchange_id;
  else
    select count(*) into v_valid
    from unnest(p_order) x(id)
    join public.secret_santa_people p
      on p.id=x.id
     and p.exchange_id=p_exchange_id
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
    and p.exchange_id=p_exchange_id;

  v_first:=case when cardinality(p_order)>0 then p_order[1] else null end;

  update public.secret_santa_exchanges
  set
    delivery_prepared_at=now(),
    delivery_paused=false,
    current_delivery_person_id=v_first,
    delivery_revealed=false
  where id=p_exchange_id;
end;
$$;

-- 6) GUARDAR EXACTAMENTE QUIEN ESTA EN PANTALLA Y SI YA SE REVELO
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
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
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

-- 7) PAUSA / REANUDACION
drop function if exists public.secret_santa_app_set_delivery_paused(uuid,boolean);

create function public.secret_santa_app_set_delivery_paused(
  p_exchange_id uuid,
  p_paused boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.secret_santa_exchanges;
begin
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  if not coalesce(v_exchange.draw_finalized,false) then
    raise exception 'Primero debes realizar el sorteo';
  end if;
  if v_exchange.delivery_closed_at is not null then
    raise exception 'El Amigo invisible ya está finalizado';
  end if;

  update public.secret_santa_exchanges
  set delivery_paused=coalesce(p_paused,false)
  where id=p_exchange_id;
end;
$$;

-- 8) SALTAR: mueve al final y persiste el siguiente
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
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  if v_exchange.delivery_closed_at is not null then
    raise exception 'El Amigo invisible ya está finalizado';
  end if;

  if not exists(
    select 1
    from public.secret_santa_people p
    where p.id=p_person_id
      and p.exchange_id=p_exchange_id
      and p.delivered_at is null
      and p.delivery_order is not null
  ) then
    raise exception 'Participante pendiente no válido';
  end if;

  select coalesce(max(delivery_order),0)
    into v_max
  from public.secret_santa_people
  where exchange_id=p_exchange_id;

  update public.secret_santa_people
  set delivery_order=v_max+1
  where id=p_person_id
    and exchange_id=p_exchange_id;

  select p.id into v_next
  from public.secret_santa_people p
  where p.exchange_id=p_exchange_id
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

-- 9) CONSULTA DE ENTREGA
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
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  if not coalesce(v_exchange.draw_finalized,false) then
    raise exception 'Primero debes realizar el sorteo';
  end if;

  if v_exchange.draw_mode='classic' then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'person_id',recipient.id,
        'person_name',recipient.name,
        'delivered_at',recipient.delivered_at,
        'delivery_order',recipient.delivery_order,
        'gift_number',giver.gift_number,
        'has_gift',coalesce(giver.brought_gift,false) and giver.gift_number is not null,
        'gift_owner_id',giver.id,
        'gift_owner_name',giver.name
      )
      order by recipient.delivery_order nulls last,recipient.name
    ),'[]'::jsonb)
    into v_people
    from public.secret_santa_people recipient
    left join public.secret_santa_people giver
      on giver.exchange_id=p_exchange_id
     and giver.assigned_person_id=recipient.id
    where recipient.exchange_id=p_exchange_id;
  else
    select coalesce(jsonb_agg(
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
    ),'[]'::jsonb)
    into v_people
    from public.secret_santa_people receiver
    join public.secret_santa_people gift_owner
      on gift_owner.id=receiver.assigned_person_id
     and gift_owner.exchange_id=p_exchange_id
     and gift_owner.brought_gift=true
     and gift_owner.gift_number is not null
    where receiver.exchange_id=p_exchange_id
      and receiver.brought_gift=true
      and receiver.gift_number is not null
      and receiver.assigned_person_id is not null;
  end if;

  return jsonb_build_object(
    'exchange',jsonb_build_object(
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

-- 10) MARCAR ENTREGA Y AVANZAR AL SIGUIENTE PERSISTENTEMENTE
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
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
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
       and giver.brought_gift=true
       and giver.gift_number is not null
      where recipient.id=p_person_id
        and recipient.exchange_id=p_exchange_id
    ) into v_has_gift;
  else
    select exists(
      select 1
      from public.secret_santa_people receiver
      join public.secret_santa_people gift_owner
        on gift_owner.id=receiver.assigned_person_id
       and gift_owner.exchange_id=p_exchange_id
       and gift_owner.brought_gift=true
       and gift_owner.gift_number is not null
      where receiver.id=p_person_id
        and receiver.exchange_id=p_exchange_id
        and receiver.brought_gift=true
        and receiver.gift_number is not null
    ) into v_has_gift;
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
      and exchange_id=p_exchange_id;
  else
    update public.secret_santa_people
    set delivered_at=null
    where id=p_person_id
      and exchange_id=p_exchange_id;
  end if;

  select p.id into v_next
  from public.secret_santa_people p
  where p.exchange_id=p_exchange_id
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

-- 11) CIERRE DEFINITIVO
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
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  if not coalesce(v_exchange.draw_finalized,false) then
    raise exception 'Primero debes realizar el sorteo';
  end if;
  if v_exchange.delivery_closed_at is not null then return; end if;

  if v_exchange.draw_mode='classic' then
    select count(*),count(*) filter(where delivered_at is not null)
    into v_total,v_delivered
    from public.secret_santa_people
    where exchange_id=p_exchange_id;
  else
    select count(*),count(*) filter(where delivered_at is not null)
    into v_total,v_delivered
    from public.secret_santa_people
    where exchange_id=p_exchange_id
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

-- 12) BORRADO: no permitir borrar una entrega que ya fue preparada
drop function if exists public.secret_santa_app_delete(uuid);

create function public.secret_santa_app_delete(p_exchange_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_locked boolean;
  v_closed timestamptz;
  v_prepared timestamptz;
begin
  select delivery_locked,delivery_closed_at,delivery_prepared_at
    into v_locked,v_closed,v_prepared
  from public.secret_santa_exchanges
  where id=p_exchange_id;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;

  if coalesce(v_locked,false) or v_closed is not null or v_prepared is not null then
    raise exception 'La entrega ya se ha iniciado o el Amigo invisible está finalizado. No se puede eliminar.';
  end if;

  delete from public.secret_santa_exchanges
  where id=p_exchange_id;
end;
$$;

-- 13) Permisos
grant execute on function public.secret_santa_app_home() to anon,authenticated;
grant execute on function public.secret_santa_app_finalize_v2(uuid,jsonb,integer) to anon,authenticated;
grant execute on function public.secret_santa_app_start_delivery(uuid,uuid[]) to anon,authenticated;
grant execute on function public.secret_santa_app_set_delivery_current(uuid,uuid,boolean) to anon,authenticated;
grant execute on function public.secret_santa_app_set_delivery_paused(uuid,boolean) to anon,authenticated;
grant execute on function public.secret_santa_app_skip_delivery(uuid,uuid) to anon,authenticated;
grant execute on function public.secret_santa_app_delivery(uuid) to anon,authenticated;
grant execute on function public.secret_santa_app_set_delivered(uuid,uuid,boolean) to anon,authenticated;
grant execute on function public.secret_santa_app_close_delivery(uuid) to anon,authenticated;
grant execute on function public.secret_santa_app_delete(uuid) to anon,authenticated;

commit;

select 'V39 FASES SEPARADAS + RECUPERACION EXACTA OK' as resultado;
