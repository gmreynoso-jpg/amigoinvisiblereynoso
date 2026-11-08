-- ============================================================
-- V42 - ALTA AUTOMATICA EN EL EVENTO AL RECEPCIONAR REGALO
--
-- Requiere V40/V41 aplicadas.
--
-- Si el Amigo invisible está vinculado a un evento:
-- 1) Si secret_santa_people.participant_id ya existe:
--      -> asistencia = Sí, confirmed_at = now()
-- 2) Si participant_id está vacío:
--      -> crea un participante nuevo en public.participants
--      -> copia nombre, tipo y grupo
--      -> asistencia = Sí
--      -> enlaza secret_santa_people.participant_id con el nuevo registro
--
-- No se intenta enlazar automáticamente por nombre para evitar
-- errores con homónimos.
-- ============================================================

begin;

-- ============================================================
-- 1. GUARDAR TIPO DE PERSONA EN AMIGO INVISIBLE
-- ============================================================

alter table public.secret_santa_people
  add column if not exists person_type text not null default 'Adulto';

-- Backfill desde participante vinculado cuando exista
update public.secret_santa_people sp
set person_type = p.type
from public.participants p
where
  sp.participant_id = p.id
  and p.type is not null
  and sp.person_type is distinct from p.type;


-- ============================================================
-- 2. AÑADIR PERSONA AL AMIGO INVISIBLE
-- Ahora conserva Adulto/Niño.
-- ============================================================

drop function if exists
  public.secret_santa_app_add_person(uuid,text,text,text);

create function public.secret_santa_app_add_person(
  p_exchange_id uuid,
  p_name text,
  p_group_name text default null,
  p_type text default 'Adulto'
)
returns public.secret_santa_people
language plpgsql
security definer
set search_path = public
as $$
declare
  v_exchange public.secret_santa_exchanges;
  v_row public.secret_santa_people;
  v_group text;
  v_type text;
begin

  select *
  into v_exchange
  from public.secret_santa_exchanges
  where id = p_exchange_id;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;

  perform public.secret_santa_v37_assert_not_locked(
    p_exchange_id
  );

  if trim(coalesce(p_name,'')) = '' then
    raise exception 'Indica el nombre';
  end if;

  v_group :=
    nullif(
      trim(coalesce(p_group_name,'')),
      ''
    );

  v_type :=
    case
      when p_type = 'Niño' then 'Niño'
      else 'Adulto'
    end;

  if
    v_exchange.meeting_id is not null
    and v_group is not null
  then

    if not exists (
      select 1
      from public.groups g
      where
        g.meeting_id = v_exchange.meeting_id
        and lower(trim(g.name)) = lower(v_group)
    ) then
      raise exception
        'El grupo indicado no existe en la reunión vinculada';
    end if;

  end if;

  if coalesce(v_exchange.draw_finalized,false) then
    perform public.secret_santa_v37_invalidate_draw(
      p_exchange_id
    );
  end if;

  insert into public.secret_santa_people(
    exchange_id,
    participant_id,
    name,
    group_name,
    person_type,
    brought_gift,
    gift_number,
    assigned_gift_number,
    assigned_person_id,
    delivered_at,
    delivery_order,
    is_active
  )
  values(
    p_exchange_id,
    null,
    trim(p_name),
    v_group,
    v_type,
    false,
    null,
    null,
    null,
    null,
    null,
    true
  )
  returning *
  into v_row;

  return v_row;

end;
$$;


-- ============================================================
-- 3. RECEPCIONAR REGALO + SINCRONIZAR EVENTO
-- ============================================================

drop function if exists
  public.secret_santa_app_set_gift(uuid,uuid,boolean);

create function public.secret_santa_app_set_gift(
  p_exchange_id uuid,
  p_person_id uuid,
  p_brought boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare

  v_exchange public.secret_santa_exchanges;
  v_person public.secret_santa_people;

  v_next integer;

  v_attendance_auto_confirmed boolean := false;
  v_event_participant_created boolean := false;

  v_participant_name text := null;
  v_new_participant_id uuid := null;

begin

  select *
  into v_exchange
  from public.secret_santa_exchanges
  where id = p_exchange_id;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;


  select *
  into v_person
  from public.secret_santa_people
  where
    id = p_person_id
    and exchange_id = p_exchange_id;

  if not found then
    raise exception 'Participante no encontrado';
  end if;


  -- ========================================================
  -- REGISTRAR REGALO
  -- ========================================================

  if coalesce(p_brought,false) then


    -- En Sorteo de regalos, tras primera entrega real
    -- no puede incorporarse un regalo nuevo.

    if
      v_exchange.draw_mode = 'gift_numbers'
      and coalesce(v_exchange.delivery_locked,false)
      and not (
        coalesce(v_person.brought_gift,false)
        and v_person.gift_number is not null
      )
    then

      raise exception
        'La entrega ya ha comenzado. En Sorteo de regalos no pueden incorporarse nuevos participantes.';

    end if;


    -- Si el regalo todavía no estaba registrado,
    -- puede cambiar el pool en gift_numbers.

    if not (
      coalesce(v_person.brought_gift,false)
      and v_person.gift_number is not null
    ) then

      if
        v_exchange.draw_mode = 'gift_numbers'
        and coalesce(v_person.is_active,true)
        and coalesce(v_exchange.draw_finalized,false)
      then

        perform public.secret_santa_v37_invalidate_draw(
          p_exchange_id
        );

        select *
        into v_exchange
        from public.secret_santa_exchanges
        where id = p_exchange_id;

      end if;


      select
        coalesce(max(gift_number),0) + 1
      into v_next
      from public.secret_santa_people
      where exchange_id = p_exchange_id;


      update public.secret_santa_people
      set
        brought_gift = true,
        gift_number = v_next
      where
        id = p_person_id
        and exchange_id = p_exchange_id;

    else

      v_next := v_person.gift_number;

    end if;


    -- ======================================================
    -- SINCRONIZACION CON EVENTO VINCULADO
    -- ======================================================

    if v_exchange.meeting_id is not null then


      -- ------------------------------------------------------
      -- CASO A: ya existe participant_id
      -- ------------------------------------------------------

      if v_person.participant_id is not null then

        update public.participants
        set
          attendance_status = 'Sí',
          confirmed_at = now()
        where
          id = v_person.participant_id
          and meeting_id = v_exchange.meeting_id
          and attendance_status is distinct from 'Sí'
        returning name
        into v_participant_name;

        v_attendance_auto_confirmed := found;


      -- ------------------------------------------------------
      -- CASO B: solo existía en Amigo invisible
      -- Se crea expresamente en el evento.
      -- ------------------------------------------------------

      else

        insert into public.participants(
          meeting_id,
          name,
          type,
          attendance_status,
          group_name,
          confirmed_at
        )
        values(
          v_exchange.meeting_id,
          v_person.name,
          case
            when v_person.person_type = 'Niño' then 'Niño'
            else 'Adulto'
          end,
          'Sí',
          v_person.group_name,
          now()
        )
        returning
          id,
          name
        into
          v_new_participant_id,
          v_participant_name;


        update public.secret_santa_people
        set participant_id = v_new_participant_id
        where
          id = p_person_id
          and exchange_id = p_exchange_id;


        v_event_participant_created := true;
        v_attendance_auto_confirmed := true;

      end if;

    end if;


    return jsonb_build_object(

      'brought_gift', true,

      'gift_number', v_next,

      'attendance_auto_confirmed',
      v_attendance_auto_confirmed,

      'event_participant_created',
      v_event_participant_created,

      'participant_id',
      coalesce(
        v_new_participant_id,
        v_person.participant_id
      ),

      'participant_name',
      coalesce(
        v_participant_name,
        v_person.name
      )

    );


  -- ========================================================
  -- QUITAR REGALO
  -- ========================================================

  else


    if coalesce(v_exchange.delivery_locked,false) then

      raise exception
        'La entrega ya ha comenzado. No se puede quitar un regalo registrado.';

    end if;


    if
      v_exchange.draw_mode = 'gift_numbers'
      and coalesce(v_person.is_active,true)
      and coalesce(v_exchange.draw_finalized,false)
    then

      perform public.secret_santa_v37_invalidate_draw(
        p_exchange_id
      );

    end if;


    update public.secret_santa_people
    set
      brought_gift = false,
      gift_number = null
    where
      id = p_person_id
      and exchange_id = p_exchange_id;


    -- Quitar regalo NO borra el participante del evento
    -- ni revierte su asistencia.

    return jsonb_build_object(

      'brought_gift', false,

      'gift_number', null,

      'attendance_auto_confirmed', false,

      'event_participant_created', false,

      'participant_id',
      v_person.participant_id,

      'participant_name',
      v_person.name

    );

  end if;

end;
$$;


-- ============================================================
-- 4. PERMISOS
-- ============================================================

grant execute
on function public.secret_santa_app_add_person(uuid,text,text,text)
to anon,authenticated;

grant execute
on function public.secret_santa_app_set_gift(uuid,uuid,boolean)
to anon,authenticated;


commit;


select
  'V42 ALTA AUTOMATICA EN EVENTO AL RECEPCIONAR REGALO OK'
  as resultado;
