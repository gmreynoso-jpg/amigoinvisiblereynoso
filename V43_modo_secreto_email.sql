-- ============================================================
-- V43 - MODO SECRETO/CIEGO + EMAIL OBLIGATORIO + NOTIFICACIONES
-- Requiere V42 aplicada.
-- ============================================================

begin;

-- 1. Permitir tercer modo
do $$
declare r record;
begin
  for r in
    select conname
    from pg_constraint
    where conrelid='public.secret_santa_exchanges'::regclass
      and contype='c'
      and pg_get_constraintdef(oid) ilike '%draw_mode%'
  loop
    execute format('alter table public.secret_santa_exchanges drop constraint %I',r.conname);
  end loop;
end $$;

alter table public.secret_santa_exchanges
  add constraint secret_santa_exchanges_draw_mode_v43_check
  check (draw_mode in ('gift_numbers','classic','blind'));

alter table public.secret_santa_exchanges
  add column if not exists notifications_sent_at timestamptz null;

alter table public.secret_santa_people
  add column if not exists email text null;
alter table public.secret_santa_people
  add column if not exists clothing_size text null;
alter table public.secret_santa_people
  add column if not exists shoe_size text null;
alter table public.secret_santa_people
  add column if not exists likes text null;
alter table public.secret_santa_people
  add column if not exists dislikes text null;
alter table public.secret_santa_people
  add column if not exists wishlist text null;
alter table public.secret_santa_people
  add column if not exists profile_notes text null;
alter table public.secret_santa_people
  add column if not exists notification_sent_at timestamptz null;
alter table public.secret_santa_people
  add column if not exists notification_error text null;

-- Cada cambio real de asignación obliga a reenviar el correo.
create or replace function public.secret_santa_v43_reset_notification()
returns trigger
language plpgsql
set search_path=public
as $$
begin
  if new.assigned_person_id is distinct from old.assigned_person_id then
    new.notification_sent_at:=null;
    new.notification_error:=null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_secret_santa_reset_notification
on public.secret_santa_people;

create trigger trg_secret_santa_reset_notification
before update of assigned_person_id
on public.secret_santa_people
for each row
execute function public.secret_santa_v43_reset_notification();


-- 2. CREAR AMIGO INVISIBLE V3
drop function if exists
  public.secret_santa_app_create_v3(uuid,text,date,numeric,text);

create function public.secret_santa_app_create_v3(
  p_meeting_id uuid,
  p_name text,
  p_event_date date,
  p_max_amount numeric,
  p_draw_mode text
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_id uuid;
  v_name text;
  v_date date;
begin
  if p_draw_mode not in ('gift_numbers','classic','blind') then
    raise exception 'Modalidad no válida';
  end if;

  if p_meeting_id is not null then
    select
      coalesce(nullif(trim(p_name),''),
        case
          when p_draw_mode='classic' then 'Amigo invisible - '||m.name
          when p_draw_mode='blind' then 'Amigo invisible secreto - '||m.name
          else 'Sorteo de regalos - '||m.name
        end),
      m.meeting_date
    into v_name,v_date
    from public.meetings m
    where m.id=p_meeting_id;

    if not found then
      raise exception 'Reunión no encontrada';
    end if;

    if exists(
      select 1 from public.secret_santa_exchanges
      where meeting_id=p_meeting_id
    ) then
      raise exception 'Esta reunión ya tiene un Amigo invisible vinculado';
    end if;
  else
    v_name:=nullif(trim(coalesce(p_name,'')),'');
    v_date:=p_event_date;
    if v_name is null then
      raise exception 'Indica un nombre';
    end if;
  end if;

  insert into public.secret_santa_exchanges(
    meeting_id,name,event_date,max_amount,draw_mode
  )
  values(
    p_meeting_id,
    v_name,
    v_date,
    greatest(coalesce(p_max_amount,0),0),
    p_draw_mode
  )
  returning id into v_id;

  if p_meeting_id is not null then
    insert into public.secret_santa_people(
      exchange_id,
      participant_id,
      name,
      group_name,
      person_type,
      email,
      is_active,
      brought_gift
    )
    select
      v_id,
      p.id,
      p.name,
      p.group_name,
      case when p.type='Niño' then 'Niño' else 'Adulto' end,
      null,
      true,
      false
    from public.participants p
    where p.meeting_id=p_meeting_id
    order by p.created_at;
  end if;

  return jsonb_build_object('id',v_id);
end;
$$;


-- 3. AÑADIR PERSONA V2 CON EMAIL
drop function if exists
  public.secret_santa_app_add_person_v2(uuid,text,text,text,text);

create function public.secret_santa_app_add_person_v2(
  p_exchange_id uuid,
  p_name text,
  p_group_name text,
  p_type text,
  p_email text
)
returns public.secret_santa_people
language plpgsql
security definer
set search_path=public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_row public.secret_santa_people;
  v_group text;
  v_email text;
begin
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  perform public.secret_santa_v37_assert_not_locked(p_exchange_id);

  if trim(coalesce(p_name,''))='' then
    raise exception 'Indica el nombre';
  end if;

  v_group:=nullif(trim(coalesce(p_group_name,'')),'');
  v_email:=nullif(lower(trim(coalesce(p_email,''))),'');
  if v_exchange.draw_mode in ('classic','blind') and v_email is null then
    raise exception 'El correo electrónico es obligatorio en esta modalidad';
  end if;

  if v_exchange.meeting_id is not null and v_group is not null and not exists(
    select 1 from public.groups g
    where g.meeting_id=v_exchange.meeting_id
      and lower(trim(g.name))=lower(v_group)
  ) then
    raise exception 'El grupo indicado no existe en la reunión vinculada';
  end if;

  if coalesce(v_exchange.draw_finalized,false) then
    perform public.secret_santa_v37_invalidate_draw(p_exchange_id);
  end if;

  insert into public.secret_santa_people(
    exchange_id,participant_id,name,group_name,person_type,email,
    brought_gift,is_active
  )
  values(
    p_exchange_id,null,trim(p_name),v_group,
    case when p_type='Niño' then 'Niño' else 'Adulto' end,
    v_email,false,true
  )
  returning * into v_row;

  return v_row;
end;
$$;


-- 4. ACTUALIZAR EMAIL Y FICHA
drop function if exists public.secret_santa_app_update_person_details(
  uuid,uuid,text,text,text,text,text,text,text
);

create function public.secret_santa_app_update_person_details(
  p_exchange_id uuid,
  p_person_id uuid,
  p_email text,
  p_clothing_size text,
  p_shoe_size text,
  p_likes text,
  p_dislikes text,
  p_wishlist text,
  p_profile_notes text
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_email text;
begin
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  perform public.secret_santa_v37_assert_not_locked(p_exchange_id);

  v_email:=nullif(lower(trim(coalesce(p_email,''))),'');
  if v_exchange.draw_mode in ('classic','blind') and v_email is null then
    raise exception 'El correo electrónico es obligatorio en esta modalidad';
  end if;

  if v_exchange.draw_mode='blind'
     and coalesce(nullif(trim(p_clothing_size),''),
                  nullif(trim(p_shoe_size),''),
                  nullif(trim(p_likes),''),
                  nullif(trim(p_dislikes),''),
                  nullif(trim(p_wishlist),''),
                  nullif(trim(p_profile_notes),'')) is null then
    raise exception 'La ficha anónima debe contener al menos un dato';
  end if;

  update public.secret_santa_people
  set
    email=v_email,
    clothing_size=nullif(trim(coalesce(p_clothing_size,'')),''),
    shoe_size=nullif(trim(coalesce(p_shoe_size,'')),''),
    likes=nullif(trim(coalesce(p_likes,'')),''),
    dislikes=nullif(trim(coalesce(p_dislikes,'')),''),
    wishlist=nullif(trim(coalesce(p_wishlist,'')),''),
    profile_notes=nullif(trim(coalesce(p_profile_notes,'')),'')
  where id=p_person_id and exchange_id=p_exchange_id;

  if not found then raise exception 'Participante no encontrado'; end if;
end;
$$;


-- 5. GET SEGURO: EN BLIND NO DEVOLVER ASIGNACIONES
drop function if exists public.secret_santa_app_get(uuid);

create function public.secret_santa_app_get(p_exchange_id uuid)
returns jsonb
language sql
security definer
set search_path=public
as $$
select jsonb_build_object(
  'exchange',to_jsonb(e),
  'meeting',case when m.id is null then null else to_jsonb(m) end,
  'people',
    coalesce((
      select jsonb_agg(
        case
          when e.draw_mode='blind'
          then to_jsonb(p)-'assigned_person_id'-'assigned_gift_number'
          else to_jsonb(p)
        end
        order by p.created_at,p.name
      )
      from public.secret_santa_people p
      where p.exchange_id=e.id
    ),'[]'::jsonb),
  'groups',
    coalesce((
      select jsonb_agg(jsonb_build_object('id',g.id,'name',g.name) order by g.name)
      from public.groups g
      where g.meeting_id=e.meeting_id
    ),'[]'::jsonb),
  'exclusions',
    coalesce((
      select jsonb_agg(to_jsonb(x) order by x.created_at)
      from public.secret_santa_exclusions x
      where x.exchange_id=e.id
    ),'[]'::jsonb)
)
from public.secret_santa_exchanges e
left join public.meetings m on m.id=e.meeting_id
where e.id=p_exchange_id;
$$;


-- 6. HELPER PRIVADO PARA MATCHING CIEGO
create or replace function public.secret_santa_v43_find_blind_assignment(
  p_exchange_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_givers uuid[];
  v_recips uuid[];
  v_best uuid[];
  v_n integer;
  v_attempt integer;
  i integer;
  v_valid boolean;
  v_score integer;
  v_best_score integer:=2147483647;
  v_g_group text;
  v_r_group text;
begin
  select array_agg(id order by id)
  into v_givers
  from public.secret_santa_people
  where exchange_id=p_exchange_id and is_active=true;

  v_n:=coalesce(cardinality(v_givers),0);
  if v_n<2 then raise exception 'Se necesitan al menos 2 participantes activos'; end if;

  for v_attempt in 1..5000 loop
    select array_agg(id order by random())
    into v_recips
    from public.secret_santa_people
    where exchange_id=p_exchange_id and is_active=true;

    v_valid:=true;
    v_score:=0;

    for i in 1..v_n loop
      if v_givers[i]=v_recips[i] then
        v_valid:=false; exit;
      end if;

      if exists(
        select 1
        from public.secret_santa_exclusions x
        where x.exchange_id=p_exchange_id
          and (
            (x.person_a_id=v_givers[i] and x.person_b_id=v_recips[i])
            or
            (x.person_b_id=v_givers[i] and x.person_a_id=v_recips[i])
          )
      ) then
        v_valid:=false; exit;
      end if;

      select group_name into v_g_group
      from public.secret_santa_people where id=v_givers[i];
      select group_name into v_r_group
      from public.secret_santa_people where id=v_recips[i];

      if v_g_group is not null and v_r_group is not null and v_g_group=v_r_group then
        v_score:=v_score+1;
      end if;
    end loop;

    if v_valid and v_score<v_best_score then
      v_best:=v_recips;
      v_best_score:=v_score;
      if v_score=0 then exit; end if;
    end if;
  end loop;

  if v_best is null then
    raise exception 'No existe una combinación válida con las exclusiones actuales';
  end if;

  return jsonb_build_object(
    'givers',to_jsonb(v_givers),
    'recipients',to_jsonb(v_best),
    'same_group_conflicts',v_best_score,
    'participant_count',v_n
  );
end;
$$;

revoke all on function public.secret_santa_v43_find_blind_assignment(uuid)
from public,anon,authenticated;


-- 7. SIMULAR BLIND SIN DEVOLVER PAREJAS
drop function if exists public.secret_santa_app_simulate_blind(uuid);

create function public.secret_santa_app_simulate_blind(p_exchange_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_r jsonb;
  v_missing text;
begin
  select * into v_exchange from public.secret_santa_exchanges where id=p_exchange_id;
  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  if v_exchange.draw_mode<>'blind' then raise exception 'Esta función solo aplica al modo secreto'; end if;
  perform public.secret_santa_v37_assert_not_locked(p_exchange_id);

  select string_agg(name,', ' order by name)
  into v_missing
  from public.secret_santa_people
  where exchange_id=p_exchange_id and is_active=true
    and (
      email is null
      or coalesce(clothing_size,shoe_size,likes,dislikes,wishlist,profile_notes) is null
    );
  if v_missing is not null then
    raise exception 'Faltan email o ficha anónima en: %',v_missing;
  end if;

  v_r:=public.secret_santa_v43_find_blind_assignment(p_exchange_id);

  return jsonb_build_object(
    'participant_count',(v_r->>'participant_count')::integer,
    'same_group_conflicts',(v_r->>'same_group_conflicts')::integer
  );
end;
$$;


-- 8. FINALIZAR BLIND EN BACKEND
drop function if exists public.secret_santa_app_finalize_blind(uuid);

create function public.secret_santa_app_finalize_blind(p_exchange_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_r jsonb;
  v_givers uuid[];
  v_recips uuid[];
  v_n integer;
  i integer;
  v_missing text;
begin
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id
  for update;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  if v_exchange.draw_mode<>'blind' then raise exception 'Esta función solo aplica al modo secreto'; end if;
  perform public.secret_santa_v37_assert_not_locked(p_exchange_id);

  select string_agg(name,', ' order by name)
  into v_missing
  from public.secret_santa_people
  where exchange_id=p_exchange_id and is_active=true
    and (
      email is null
      or coalesce(clothing_size,shoe_size,likes,dislikes,wishlist,profile_notes) is null
    );
  if v_missing is not null then
    raise exception 'Faltan email o ficha anónima en: %',v_missing;
  end if;

  v_r:=public.secret_santa_v43_find_blind_assignment(p_exchange_id);

  select array_agg(value::uuid order by ord)
  into v_givers
  from jsonb_array_elements_text(v_r->'givers') with ordinality t(value,ord);

  select array_agg(value::uuid order by ord)
  into v_recips
  from jsonb_array_elements_text(v_r->'recipients') with ordinality t(value,ord);

  v_n:=cardinality(v_givers);

  update public.secret_santa_people
  set assigned_person_id=null,assigned_gift_number=null,
      delivered_at=null,delivery_order=null
  where exchange_id=p_exchange_id;

  for i in 1..v_n loop
    update public.secret_santa_people
    set assigned_person_id=v_recips[i]
    where id=v_givers[i] and exchange_id=p_exchange_id;
  end loop;

  update public.secret_santa_exchanges
  set
    draw_finalized=true,
    drawn_at=now(),
    same_group_conflicts=(v_r->>'same_group_conflicts')::integer,
    delivery_locked=false,
    delivery_started_at=null,
    delivery_paused=false,
    delivery_closed_at=null,
    delivery_prepared_at=null,
    current_delivery_person_id=null,
    delivery_revealed=false,
    notifications_sent_at=null
  where id=p_exchange_id;

  return jsonb_build_object(
    'participant_count',v_n,
    'same_group_conflicts',(v_r->>'same_group_conflicts')::integer
  );
end;
$$;


-- 9. DELIVERY: BLIND SE COMPORTA COMO CLÁSICO PERO SIN EXPONER AL GIVER
drop function if exists public.secret_santa_app_delivery(uuid);

create function public.secret_santa_app_delivery(p_exchange_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_people jsonb;
  v_missing_gifts jsonb;
begin
  select * into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  if not coalesce(v_exchange.draw_finalized,false) then raise exception 'Primero debes realizar el sorteo'; end if;

  if v_exchange.draw_mode in ('classic','blind') then
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'person_id',recipient.id,
        'person_name',recipient.name,
        'delivered_at',recipient.delivered_at,
        'delivery_order',recipient.delivery_order,
        'gift_number',giver.gift_number,
        'has_gift',coalesce(giver.brought_gift,false) and giver.gift_number is not null,
        'gift_owner_id',case when v_exchange.draw_mode='classic' then giver.id else null end,
        'gift_owner_name',case when v_exchange.draw_mode='classic' then giver.name else null end
      )
      order by recipient.delivery_order nulls last,recipient.name
    ),'[]'::jsonb)
    into v_people
    from public.secret_santa_people recipient
    left join public.secret_santa_people giver
      on giver.exchange_id=p_exchange_id
     and giver.assigned_person_id=recipient.id
     and giver.is_active=true
    where recipient.exchange_id=p_exchange_id
      and recipient.is_active=true
      and recipient.assigned_person_id is not null;

    select coalesce(jsonb_agg(
      jsonb_build_object('person_id',p.id,'person_name',p.name)
      order by p.name
    ),'[]'::jsonb)
    into v_missing_gifts
    from public.secret_santa_people p
    where p.exchange_id=p_exchange_id
      and p.is_active=true
      and (not coalesce(p.brought_gift,false) or p.gift_number is null);
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
     and gift_owner.is_active=true
     and gift_owner.brought_gift=true
     and gift_owner.gift_number is not null
    where receiver.exchange_id=p_exchange_id
      and receiver.is_active=true
      and receiver.brought_gift=true
      and receiver.gift_number is not null
      and receiver.assigned_person_id is not null;

    v_missing_gifts:='[]'::jsonb;
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
    'people',v_people,
    'missing_gifts',v_missing_gifts
  );
end;
$$;


-- 10. START/CLOSE DELIVERY: BLIND COMO CLASSIC
-- Reemplazamos solo condiciones de pool.

drop function if exists public.secret_santa_app_start_delivery(uuid,uuid[]);

create function public.secret_santa_app_start_delivery(
  p_exchange_id uuid,p_order uuid[]
)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_expected integer;
  v_received integer;
  v_valid integer;
  v_first uuid;
begin
  select * into v_exchange
  from public.secret_santa_exchanges where id=p_exchange_id for update;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  if not coalesce(v_exchange.draw_finalized,false) then raise exception 'Primero debes realizar el sorteo'; end if;
  if v_exchange.delivery_closed_at is not null then raise exception 'El Amigo invisible ya está finalizado'; end if;
  if v_exchange.delivery_prepared_at is not null then return; end if;

  if v_exchange.draw_mode in ('classic','blind') then
    select count(*) into v_expected
    from public.secret_santa_people
    where exchange_id=p_exchange_id and is_active=true and assigned_person_id is not null;
  else
    select count(*) into v_expected
    from public.secret_santa_people
    where exchange_id=p_exchange_id and is_active=true
      and brought_gift=true and gift_number is not null
      and assigned_person_id is not null;
  end if;

  v_received:=coalesce(cardinality(p_order),0);
  if v_received<>v_expected then raise exception 'El orden de entrega no contiene exactamente todos los participantes incluidos'; end if;

  select count(distinct x.id) into v_valid from unnest(p_order)x(id);
  if v_valid<>v_expected then raise exception 'El orden de entrega contiene participantes duplicados'; end if;

  select count(*) into v_valid
  from unnest(p_order)x(id)
  join public.secret_santa_people p
    on p.id=x.id and p.exchange_id=p_exchange_id and p.is_active=true
   and p.assigned_person_id is not null
  where v_exchange.draw_mode in ('classic','blind')
     or (p.brought_gift=true and p.gift_number is not null);

  if v_valid<>v_expected then raise exception 'El orden contiene participantes que no forman parte del sorteo'; end if;

  update public.secret_santa_people set delivery_order=null where exchange_id=p_exchange_id;

  update public.secret_santa_people p
  set delivery_order=q.ord::integer
  from (select u.id,u.ord from unnest(p_order) with ordinality u(id,ord))q
  where p.id=q.id and p.exchange_id=p_exchange_id and p.is_active=true;

  v_first:=case when cardinality(p_order)>0 then p_order[1] else null end;

  update public.secret_santa_exchanges
  set delivery_prepared_at=now(),delivery_paused=false,
      current_delivery_person_id=v_first,delivery_revealed=false
  where id=p_exchange_id;
end;
$$;


drop function if exists public.secret_santa_app_close_delivery(uuid);

create function public.secret_santa_app_close_delivery(p_exchange_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_total integer;
  v_delivered integer;
begin
  select * into v_exchange
  from public.secret_santa_exchanges where id=p_exchange_id for update;

  if not found then raise exception 'Amigo invisible no encontrado'; end if;
  if not coalesce(v_exchange.draw_finalized,false) then raise exception 'Primero debes realizar el sorteo'; end if;
  if v_exchange.delivery_closed_at is not null then return; end if;

  if v_exchange.draw_mode in ('classic','blind') then
    select count(*),count(*) filter(where delivered_at is not null)
    into v_total,v_delivered
    from public.secret_santa_people
    where exchange_id=p_exchange_id and is_active=true and assigned_person_id is not null;
  else
    select count(*),count(*) filter(where delivered_at is not null)
    into v_total,v_delivered
    from public.secret_santa_people
    where exchange_id=p_exchange_id and is_active=true
      and brought_gift=true and gift_number is not null
      and assigned_person_id is not null;
  end if;

  if v_total=0 then raise exception 'No hay participantes incluidos en la entrega'; end if;
  if v_delivered<>v_total then raise exception 'Todavía existen participantes pendientes de recibir su regalo'; end if;

  update public.secret_santa_exchanges
  set delivery_locked=true,delivery_paused=false,
      delivery_closed_at=now(),
      delivery_started_at=coalesce(delivery_started_at,now()),
      current_delivery_person_id=null,delivery_revealed=false
  where id=p_exchange_id;
end;
$$;


-- 11. PERSONAL RESULT: BLIND NUNCA DEVUELVE IDENTIDAD
drop function if exists public.secret_santa_app_personal_result(uuid);

create function public.secret_santa_app_personal_result(p_token uuid)
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare
  v_person public.secret_santa_people;
  v_exchange public.secret_santa_exchanges;
  v_recipient public.secret_santa_people;
begin
  select * into v_person
  from public.secret_santa_people
  where result_token=p_token;
  if not found then raise exception 'Enlace personal no válido'; end if;

  select * into v_exchange
  from public.secret_santa_exchanges
  where id=v_person.exchange_id;

  if not coalesce(v_exchange.draw_finalized,false) then raise exception 'El sorteo todavía no se ha realizado'; end if;

  if v_person.assigned_person_id is not null then
    select * into v_recipient
    from public.secret_santa_people
    where id=v_person.assigned_person_id and exchange_id=v_exchange.id;
  end if;

  if v_exchange.draw_mode='blind' then
    return jsonb_build_object(
      'exchange_name',v_exchange.name,
      'event_date',v_exchange.event_date,
      'max_amount',v_exchange.max_amount,
      'draw_mode','blind',
      'person_name',v_person.name,
      'clothing_size',v_recipient.clothing_size,
      'shoe_size',v_recipient.shoe_size,
      'likes',v_recipient.likes,
      'dislikes',v_recipient.dislikes,
      'wishlist',v_recipient.wishlist,
      'profile_notes',v_recipient.profile_notes
    );
  elsif v_exchange.draw_mode='classic' then
    return jsonb_build_object(
      'exchange_name',v_exchange.name,'event_date',v_exchange.event_date,
      'max_amount',v_exchange.max_amount,'draw_mode','classic',
      'person_name',v_person.name,'recipient_name',v_recipient.name
    );
  else
    return jsonb_build_object(
      'exchange_name',v_exchange.name,'event_date',v_exchange.event_date,
      'max_amount',v_exchange.max_amount,'draw_mode','gift_numbers',
      'person_name',v_person.name,
      'assigned_gift_number',v_recipient.gift_number
    );
  end if;
end;
$$;


-- 12. PERMISOS
grant execute on function public.secret_santa_app_create_v3(uuid,text,date,numeric,text) to anon,authenticated;
grant execute on function public.secret_santa_app_add_person_v2(uuid,text,text,text,text) to anon,authenticated;
grant execute on function public.secret_santa_app_update_person_details(uuid,uuid,text,text,text,text,text,text,text) to anon,authenticated;
grant execute on function public.secret_santa_app_get(uuid) to anon,authenticated;
grant execute on function public.secret_santa_app_simulate_blind(uuid) to anon,authenticated;
grant execute on function public.secret_santa_app_finalize_blind(uuid) to anon,authenticated;
grant execute on function public.secret_santa_app_delivery(uuid) to anon,authenticated;
grant execute on function public.secret_santa_app_start_delivery(uuid,uuid[]) to anon,authenticated;
grant execute on function public.secret_santa_app_close_delivery(uuid) to anon,authenticated;
grant execute on function public.secret_santa_app_personal_result(uuid) to anon,authenticated;

commit;

select 'V43 MODO SECRETO + EMAIL OBLIGATORIO OK' as resultado;
