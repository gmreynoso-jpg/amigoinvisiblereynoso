-- ============================================================
-- V41 - CONFIRMAR ASISTENCIA AL RECEPCIONAR REGALO
--
-- Si el Amigo invisible está vinculado a un evento y la persona
-- procede de participants mediante participant_id, registrar
-- físicamente su regalo confirma automáticamente su asistencia.
--
-- Aplica tanto a Pendiente como a No, porque la recepción
-- presencial del regalo demuestra que la persona ha asistido.
--
-- No afecta a Amigos invisibles independientes ni a personas
-- añadidas únicamente dentro del Amigo invisible.
-- ============================================================

begin;

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
  v_participant_name text := null;

begin

  select *
  into v_exchange
  from public.secret_santa_exchanges
  where id=p_exchange_id;

  if not found then
    raise exception 'Amigo invisible no encontrado';
  end if;


  select *
  into v_person
  from public.secret_santa_people
  where
    id=p_person_id
    and exchange_id=p_exchange_id;

  if not found then
    raise exception 'Participante no encontrado';
  end if;


  -- ========================================================
  -- REGISTRAR REGALO
  -- ========================================================

  if coalesce(p_brought,false) then


    -- --------------------------------------------------------
    -- Si ya estaba registrado, mantenemos el número.
    -- Aun así comprobamos la asistencia, porque una versión
    -- anterior pudo haber registrado el regalo sin confirmarla.
    -- --------------------------------------------------------

    if
      v_person.brought_gift
      and v_person.gift_number is not null
    then

      if
        v_exchange.meeting_id is not null
        and v_person.participant_id is not null
      then

        update public.participants
        set
          attendance_status='Sí',
          confirmed_at=now()
        where
          id=v_person.participant_id
          and meeting_id=v_exchange.meeting_id
          and attendance_status is distinct from 'Sí'
        returning name
        into v_participant_name;

        v_attendance_auto_confirmed := found;

      end if;


      return jsonb_build_object(

        'brought_gift',true,
        'gift_number',v_person.gift_number,

        'attendance_auto_confirmed',
        v_attendance_auto_confirmed,

        'participant_name',
        coalesce(v_participant_name,v_person.name)

      );

    end if;


    -- --------------------------------------------------------
    -- SORTEO DE REGALOS:
    -- tras la primera entrega real no puede entrar nadie nuevo
    -- al pool mediante un regalo tardío.
    -- --------------------------------------------------------

    if
      v_exchange.draw_mode='gift_numbers'
      and coalesce(v_exchange.delivery_locked,false)
    then

      raise exception
        'La entrega ya ha comenzado. En Sorteo de regalos no pueden incorporarse nuevos participantes.';

    end if;


    -- --------------------------------------------------------
    -- En Sorteo de regalos, si esta persona está activa,
    -- registrar un regalo modifica el pool y obliga a rehacer
    -- un sorteo aún editable.
    -- --------------------------------------------------------

    if
      v_exchange.draw_mode='gift_numbers'
      and coalesce(v_person.is_active,true)
      and coalesce(v_exchange.draw_finalized,false)
    then

      perform public.secret_santa_v37_invalidate_draw(
        p_exchange_id
      );

      -- Recargar estado del exchange tras invalidar.
      select *
      into v_exchange
      from public.secret_santa_exchanges
      where id=p_exchange_id;

    end if;


    -- --------------------------------------------------------
    -- Asignar siguiente número físico disponible.
    -- Los regalos de personas temporalmente inactivas conservan
    -- su número, por lo que también cuentan para obtener el MAX.
    -- --------------------------------------------------------

    select
      coalesce(max(gift_number),0)+1
    into v_next
    from public.secret_santa_people
    where exchange_id=p_exchange_id;


    update public.secret_santa_people
    set
      brought_gift=true,
      gift_number=v_next
    where
      id=p_person_id
      and exchange_id=p_exchange_id;


    -- ========================================================
    -- CONFIRMAR ASISTENCIA DEL EVENTO VINCULADO
    --
    -- Solo si:
    -- - existe meeting_id
    -- - esta persona tiene participant_id real
    --
    -- Si estaba Pendiente o No, pasa a Sí.
    -- ========================================================

    if
      v_exchange.meeting_id is not null
      and v_person.participant_id is not null
    then

      update public.participants
      set
        attendance_status='Sí',
        confirmed_at=now()
      where
        id=v_person.participant_id
        and meeting_id=v_exchange.meeting_id
        and attendance_status is distinct from 'Sí'
      returning name
      into v_participant_name;

      v_attendance_auto_confirmed := found;

    end if;


    return jsonb_build_object(

      'brought_gift',true,
      'gift_number',v_next,

      'attendance_auto_confirmed',
      v_attendance_auto_confirmed,

      'participant_name',
      coalesce(v_participant_name,v_person.name)

    );


  -- ========================================================
  -- QUITAR REGALO
  -- ========================================================

  else


    if coalesce(v_exchange.delivery_locked,false) then

      raise exception
        'La entrega ya ha comenzado. No se puede quitar un regalo registrado.';

    end if;


    -- En Sorteo de regalos, si la persona participa realmente,
    -- quitar su regalo cambia el pool y obliga a rehacer sorteo.

    if
      v_exchange.draw_mode='gift_numbers'
      and coalesce(v_person.is_active,true)
      and coalesce(v_exchange.draw_finalized,false)
    then

      perform public.secret_santa_v37_invalidate_draw(
        p_exchange_id
      );

    end if;


    update public.secret_santa_people
    set
      brought_gift=false,
      gift_number=null
    where
      id=p_person_id
      and exchange_id=p_exchange_id;


    -- Quitar un regalo NO revierte nunca la asistencia.
    -- Una persona que ya estuvo presente sigue constando como asistente.

    return jsonb_build_object(

      'brought_gift',false,
      'gift_number',null,

      'attendance_auto_confirmed',
      false,

      'participant_name',
      v_person.name

    );

  end if;

end;
$$;


grant execute
on function public.secret_santa_app_set_gift(uuid,uuid,boolean)
to anon,authenticated;


commit;


select
  'V41 ASISTENCIA AUTOMATICA AL RECEPCIONAR REGALO OK'
  as resultado;
