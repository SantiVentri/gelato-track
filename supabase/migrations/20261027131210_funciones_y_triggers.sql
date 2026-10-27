-- Rol del usuario logueado. Devuelve null si no tiene perfil o está inactivo.
create or replace function public.rol_actual()
returns text
language sql
stable
security definer
set search_path = public
as $$
  select rol from usuarios where id = auth.uid() and activo
$$;

-- Crea el perfil automáticamente cuando alguien se registra en Auth.
-- Queda inactivo hasta que un admin lo active.
create or replace function public.crear_perfil_usuario()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.usuarios (id, nombre)
  values (new.id, coalesce(new.raw_user_meta_data->>'nombre', new.email));
  return new;
end;
$$;

create trigger trg_crear_perfil
  after insert on auth.users
  for each row execute function public.crear_perfil_usuario();

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create trigger trg_usuarios_updated_at
  before update on usuarios
  for each row execute function public.set_updated_at();

-- Los movimientos son el historial de stock: no se editan ni se borran.
create or replace function public.movimientos_inmutables()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  raise exception 'Los movimientos no se modifican ni se borran: usar una reversa';
end;
$$;

create trigger trg_movimientos_inmutables
  before update or delete on movimientos
  for each row execute function public.movimientos_inmutables();

-- Cada movimiento actualiza el stock del insumo o del lote.
-- Los checks >= 0 de las tablas impiden stock negativo.
create or replace function public.aplicar_movimiento()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.insumo_id is not null then
    update insumos set stock_actual = stock_actual + new.cantidad where id = new.insumo_id;
  end if;
  if new.lote_id is not null then
    update lotes set litros_disponibles = litros_disponibles + new.cantidad where id = new.lote_id;
  end if;
  return new;
end;
$$;

create trigger trg_aplicar_movimiento
  after insert on movimientos
  for each row execute function public.aplicar_movimiento();

-- ============================================================
-- Operaciones de negocio. Son security definer porque las políticas RLS
-- no permiten escribir directamente en estas tablas. Cada función valida
-- el rol o el dueño del registro antes de operar.
-- ============================================================

-- Regla 4: cada cambio de receta crea una versión nueva
create or replace function public.guardar_receta(
  p_sabor_id uuid,
  p_ingredientes jsonb  -- [{"insumo_id": "...", "cantidad_por_litro": 0.8}]
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_receta_id uuid;
  v_version integer;
begin
  if rol_actual() not in ('admin', 'encargado') then
    raise exception 'Sin permiso para editar recetas';
  end if;
  if jsonb_array_length(p_ingredientes) = 0 then
    raise exception 'La receta no tiene insumos';
  end if;

  -- Bloquea el sabor: dos guardados simultáneos no pueden calcular la misma versión
  perform 1 from sabores where id = p_sabor_id for update;
  if not found then
    raise exception 'El sabor no existe';
  end if;

  select coalesce(max(version), 0) + 1 into v_version
    from recetas where sabor_id = p_sabor_id;

  insert into recetas (sabor_id, version, created_by)
  values (p_sabor_id, v_version, auth.uid())
  returning id into v_receta_id;

  insert into receta_insumos (receta_id, insumo_id, cantidad_por_litro)
  select v_receta_id,
         (x->>'insumo_id')::uuid,
         (x->>'cantidad_por_litro')::numeric
    from jsonb_array_elements(p_ingredientes) as x;

  return v_receta_id;
end;
$$;

-- Flujo 5.1: registra la tanda, el lote y el consumo de insumos
create or replace function public.registrar_tanda(
  p_sabor_id uuid,
  p_litros numeric,
  p_fecha_vencimiento date
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario uuid := auth.uid();
  v_rol text := rol_actual();
  v_receta recetas%rowtype;
  v_tanda_id uuid;
  r record;
begin
  if v_rol not in ('admin', 'encargado') then
    raise exception 'Sin permiso para registrar tandas';
  end if;
  if p_litros <= 0 then
    raise exception 'Los litros deben ser mayores a 0';
  end if;
  if p_fecha_vencimiento < current_date then
    raise exception 'La fecha de vencimiento ya pasó';
  end if;

  perform 1 from sabores where id = p_sabor_id and activo for update;
  if not found then
    raise exception 'El sabor no existe o está inactivo';
  end if;

  select * into v_receta from recetas
   where sabor_id = p_sabor_id and vigente_desde <= current_date
   order by vigente_desde desc, version desc
   limit 1;
  if not found then
    raise exception 'El sabor no tiene receta vigente';
  end if;

  -- Verifica stock de todos los insumos antes de escribir nada
  for r in
    select i.nombre, i.stock_actual, ri.cantidad_por_litro * p_litros as necesario
      from receta_insumos ri
      join insumos i on i.id = ri.insumo_id
     where ri.receta_id = v_receta.id
     order by i.nombre
       for update of i
  loop
    if r.stock_actual < r.necesario then
      raise exception 'Falta %: hay % y se necesitan %', r.nombre, r.stock_actual, r.necesario;
    end if;
  end loop;

  insert into tandas (sabor_id, receta_id, usuario_id, litros)
  values (p_sabor_id, v_receta.id, v_usuario, p_litros)
  returning id into v_tanda_id;

  insert into lotes (tanda_id, fecha_vencimiento, litros_disponibles)
  values (v_tanda_id, p_fecha_vencimiento, p_litros);

  insert into movimientos (tipo, insumo_id, cantidad, tanda_id, usuario_id)
  select 'produccion', ri.insumo_id, -(ri.cantidad_por_litro * p_litros), v_tanda_id, v_usuario
    from receta_insumos ri
   where ri.receta_id = v_receta.id;

  return v_tanda_id;
end;
$$;

-- Flujo 5.2: venta con descuento FEFO por lote.
-- p_items: [{"sabor_id": "...", "presentacion_id": "...", "cantidad": 2}]
create or replace function public.registrar_venta(
  p_turno_id uuid,
  p_medio_pago text,
  p_items jsonb
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_usuario uuid := auth.uid();
  v_rol text := rol_actual();
  v_turno turnos_caja%rowtype;
  v_presentacion presentaciones%rowtype;
  v_item jsonb;
  v_lote record;
  v_venta_id uuid;
  v_sabor uuid;
  v_cantidad numeric;
  v_precio numeric;
  v_total numeric := 0;
  v_pendiente numeric;
  v_tomar numeric;
begin
  if v_rol not in ('admin', 'vendedor') then
    raise exception 'Sin permiso para registrar ventas';
  end if;
  if p_medio_pago not in ('efectivo', 'tarjeta', 'transferencia') then
    raise exception 'Medio de pago inválido';
  end if;
  if jsonb_array_length(p_items) = 0 then
    raise exception 'La venta no tiene ítems';
  end if;

  select * into v_turno from turnos_caja where id = p_turno_id;
  if not found or v_turno.estado <> 'abierto' then
    raise exception 'El turno no existe o está cerrado';
  end if;
  if v_turno.usuario_id <> v_usuario then
    raise exception 'El turno pertenece a otro usuario';
  end if;

  insert into ventas (turno_id, usuario_id, medio_pago)
  values (p_turno_id, v_usuario, p_medio_pago)
  returning id into v_venta_id;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_sabor := (v_item->>'sabor_id')::uuid;
    v_cantidad := (v_item->>'cantidad')::numeric;
    if v_cantidad is null or v_cantidad <= 0 then
      raise exception 'Cantidad inválida';
    end if;

    perform 1 from sabores where id = v_sabor and activo;
    if not found then
      raise exception 'Sabor inexistente o inactivo';
    end if;

    select * into v_presentacion from presentaciones
     where id = (v_item->>'presentacion_id')::uuid and activo;
    if not found then
      raise exception 'Presentación inexistente o inactiva';
    end if;

    select p.precio into v_precio from precios p
     where p.sabor_id = v_sabor
       and p.presentacion_id = v_presentacion.id
       and p.vigente_desde <= current_date
     order by p.vigente_desde desc
     limit 1;
    if not found then
      raise exception 'No hay precio vigente para uno de los ítems';
    end if;

    insert into venta_items (venta_id, sabor_id, presentacion_id, cantidad, precio_unitario)
    values (v_venta_id, v_sabor, v_presentacion.id, v_cantidad, v_precio);

    v_total := v_total + v_precio * v_cantidad;

    -- FEFO: se descuenta primero del lote que vence antes
    v_pendiente := v_cantidad * v_presentacion.litros_equivalentes;
    for v_lote in
      select l.id, l.litros_disponibles
        from lotes l
        join tandas t on t.id = l.tanda_id
       where t.sabor_id = v_sabor
         and t.estado = 'activa'
         and l.litros_disponibles > 0
         and l.fecha_vencimiento >= current_date
       order by l.fecha_vencimiento, l.id
         for update of l
    loop
      exit when v_pendiente <= 0;
      v_tomar := least(v_pendiente, v_lote.litros_disponibles);
      insert into movimientos (tipo, lote_id, cantidad, venta_id, usuario_id)
      values ('venta', v_lote.id, -v_tomar, v_venta_id, v_usuario);
      v_pendiente := v_pendiente - v_tomar;
    end loop;

    if v_pendiente > 0 then
      raise exception 'Stock insuficiente: faltan % litros de un sabor', v_pendiente;
    end if;
  end loop;

  update ventas set total = v_total where id = v_venta_id;
  return v_venta_id;
end;
$$;

-- Flujo 5.3: cierre de caja. Devuelve la diferencia.
create or replace function public.cerrar_turno(
  p_turno_id uuid,
  p_monto_contado numeric
)
returns numeric
language plpgsql
security definer
set search_path = public
as $$
declare
  v_turno turnos_caja%rowtype;
  v_efectivo numeric;
  v_diferencia numeric;
begin
  select * into v_turno from turnos_caja where id = p_turno_id for update;
  if not found or v_turno.estado <> 'abierto' then
    raise exception 'El turno no existe o ya está cerrado';
  end if;
  if v_turno.usuario_id <> auth.uid() then
    raise exception 'El turno pertenece a otro usuario';
  end if;
  if p_monto_contado < 0 then
    raise exception 'Monto contado inválido';
  end if;
  if exists (select 1 from ventas where turno_id = p_turno_id and estado = 'pendiente') then
    raise exception 'Hay ventas pendientes en este turno';
  end if;

  select coalesce(sum(total), 0) into v_efectivo
    from ventas
   where turno_id = p_turno_id
     and estado = 'activa'
     and medio_pago = 'efectivo';

  v_diferencia := p_monto_contado - (v_turno.monto_inicial + v_efectivo);

  update turnos_caja
     set estado = 'cerrado',
         monto_contado = p_monto_contado,
         diferencia = v_diferencia,
         cerrado_en = now()
   where id = p_turno_id;

  return v_diferencia;
end;
$$;

-- Flujo 5.4: anulación de venta con movimientos de reversa
create or replace function public.anular_venta(p_venta_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_venta ventas%rowtype;
  m record;
begin
  if rol_actual() not in ('admin', 'encargado') then
    raise exception 'Sin permiso para anular ventas';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'El motivo es obligatorio';
  end if;

  select * into v_venta from ventas where id = p_venta_id for update;
  if not found then
    raise exception 'La venta no existe';
  end if;
  if v_venta.estado <> 'activa' then
    raise exception 'La venta no está activa';
  end if;

  for m in
    select mv.* from movimientos mv
     where mv.venta_id = p_venta_id
       and mv.revierte_id is null
       and not exists (select 1 from movimientos r where r.revierte_id = mv.id)
  loop
    insert into movimientos (tipo, insumo_id, lote_id, cantidad, venta_id, revierte_id, usuario_id)
    values ('reversa', m.insumo_id, m.lote_id, -m.cantidad, p_venta_id, m.id, auth.uid());
  end loop;

  update ventas
     set estado = 'anulada',
         motivo_anulacion = p_motivo,
         anulado_por = auth.uid(),
         anulado_en = now()
   where id = p_venta_id;
end;
$$;

-- Flujo 5.4: anulación de tanda. No se permite si sus lotes tienen ventas activas.
create or replace function public.anular_tanda(p_tanda_id uuid, p_motivo text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tanda tandas%rowtype;
  m record;
  l record;
begin
  if rol_actual() not in ('admin', 'encargado') then
    raise exception 'Sin permiso para anular tandas';
  end if;
  if coalesce(trim(p_motivo), '') = '' then
    raise exception 'El motivo es obligatorio';
  end if;

  select * into v_tanda from tandas where id = p_tanda_id for update;
  if not found then
    raise exception 'La tanda no existe';
  end if;
  if v_tanda.estado <> 'activa' then
    raise exception 'La tanda ya está anulada';
  end if;

  if exists (
    select 1
      from movimientos mv
      join ventas v on v.id = mv.venta_id
     where mv.lote_id in (select id from lotes where tanda_id = p_tanda_id)
       and mv.tipo = 'venta'
       and v.estado = 'activa'
  ) then
    raise exception 'La tanda tiene ventas activas: anulá primero esas ventas';
  end if;

  -- Revierte el consumo de insumos
  for m in
    select mv.* from movimientos mv
     where mv.tanda_id = p_tanda_id
       and mv.revierte_id is null
       and not exists (select 1 from movimientos r where r.revierte_id = mv.id)
  loop
    insert into movimientos (tipo, insumo_id, lote_id, cantidad, tanda_id, revierte_id, usuario_id)
    values ('reversa', m.insumo_id, m.lote_id, -m.cantidad, p_tanda_id, m.id, auth.uid());
  end loop;

  -- Vacía los lotes que quedaron con litros
  for l in
    select id, litros_disponibles from lotes
     where tanda_id = p_tanda_id and litros_disponibles > 0
  loop
    insert into movimientos (tipo, lote_id, cantidad, tanda_id, usuario_id)
    values ('ajuste', l.id, -l.litros_disponibles, p_tanda_id, auth.uid());
  end loop;

  update tandas
     set estado = 'anulada',
         motivo_anulacion = p_motivo,
         anulado_por = auth.uid(),
         anulado_en = now()
   where id = p_tanda_id;
end;
$$;

-- Permisos de funciones de negocio: solo usuarios logueados
revoke execute on function public.rol_actual() from public, anon;
revoke execute on function public.crear_perfil_usuario() from public, anon, authenticated;
revoke execute on function public.guardar_receta(uuid, jsonb) from public, anon;
revoke execute on function public.registrar_tanda(uuid, numeric, date) from public, anon;
revoke execute on function public.registrar_venta(uuid, text, jsonb) from public, anon;
revoke execute on function public.cerrar_turno(uuid, numeric) from public, anon;
revoke execute on function public.anular_venta(uuid, text) from public, anon;
revoke execute on function public.anular_tanda(uuid, text) from public, anon;

grant execute on function public.rol_actual() to authenticated;
grant execute on function public.guardar_receta(uuid, jsonb) to authenticated;
grant execute on function public.registrar_tanda(uuid, numeric, date) to authenticated;
grant execute on function public.registrar_venta(uuid, text, jsonb) to authenticated;
grant execute on function public.cerrar_turno(uuid, numeric) to authenticated;
grant execute on function public.anular_venta(uuid, text) to authenticated;
grant execute on function public.anular_tanda(uuid, text) to authenticated;

-- Funciones de trigger: no se llaman por RPC, nadie necesita EXECUTE
revoke execute on function public.set_updated_at() from public, anon, authenticated;
revoke execute on function public.movimientos_inmutables() from public, anon, authenticated;
revoke execute on function public.aplicar_movimiento() from public, anon, authenticated;