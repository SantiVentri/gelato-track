create table presentaciones (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,                       -- vasito, cuarto, kilo, cucurucho
  litros_equivalentes numeric not null check (litros_equivalentes > 0),
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

create table sabores (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

create table precios (
  id uuid primary key default gen_random_uuid(),
  sabor_id uuid not null references sabores(id),
  presentacion_id uuid not null references presentaciones(id),
  precio numeric not null check (precio >= 0),
  vigente_desde date not null default current_date,
  created_at timestamptz not null default now(),
  unique (sabor_id, presentacion_id, vigente_desde)
);

create table insumos (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  unidad text not null,
  stock_actual numeric not null default 0 check (stock_actual >= 0),
  stock_minimo numeric not null default 0 check (stock_minimo >= 0),
  created_at timestamptz not null default now()
);

-- Perfil de la app. El id es el mismo que el de Supabase Auth.
create table usuarios (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  rol text not null default 'vendedor' check (rol in ('admin', 'encargado', 'vendedor')),
  activo boolean not null default false,             -- el admin lo activa
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table recetas (
  id uuid primary key default gen_random_uuid(),
  sabor_id uuid not null references sabores(id),
  version integer not null check (version > 0),
  vigente_desde date not null default current_date,
  created_by uuid references usuarios(id),
  created_at timestamptz not null default now(),
  unique (sabor_id, version)
);

create table receta_insumos (
  id uuid primary key default gen_random_uuid(),
  receta_id uuid not null references recetas(id),
  insumo_id uuid not null references insumos(id),
  cantidad_por_litro numeric not null check (cantidad_por_litro > 0),
  unique (receta_id, insumo_id)
);

create table tandas (
  id uuid primary key default gen_random_uuid(),
  sabor_id uuid not null references sabores(id),
  receta_id uuid not null references recetas(id),
  usuario_id uuid not null references usuarios(id),
  litros numeric not null check (litros > 0),
  fecha date not null default current_date,
  estado text not null default 'activa' check (estado in ('activa', 'anulada')),
  motivo_anulacion text,
  anulado_por uuid references usuarios(id),
  anulado_en timestamptz,
  created_at timestamptz not null default now(),
  constraint tandas_anulacion_completa check (
    (estado = 'activa' and motivo_anulacion is null and anulado_por is null and anulado_en is null)
    or (estado = 'anulada' and motivo_anulacion is not null and anulado_por is not null and anulado_en is not null)
  )
);

create table lotes (
  id uuid primary key default gen_random_uuid(),
  tanda_id uuid not null references tandas(id),
  fecha_vencimiento date not null,
  litros_disponibles numeric not null check (litros_disponibles >= 0),
  created_at timestamptz not null default now()
);

create table turnos_caja (
  id uuid primary key default gen_random_uuid(),
  usuario_id uuid not null references usuarios(id),
  estado text not null default 'abierto' check (estado in ('abierto', 'cerrado')),
  monto_inicial numeric not null check (monto_inicial >= 0),
  monto_contado numeric,
  diferencia numeric,
  abierto_en timestamptz not null default now(),
  cerrado_en timestamptz,
  created_at timestamptz not null default now(),
  constraint turnos_caja_estado_coherente check (
    (estado = 'abierto' and monto_contado is null and diferencia is null and cerrado_en is null)
    or (estado = 'cerrado' and monto_contado is not null and diferencia is not null and cerrado_en is not null)
  )
);

-- Regla 5: un solo turno abierto por usuario
create unique index turnos_caja_un_abierto_por_usuario
  on turnos_caja (usuario_id) where estado = 'abierto';

create table ventas (
  id uuid primary key default gen_random_uuid(),
  turno_id uuid not null references turnos_caja(id),
  usuario_id uuid not null references usuarios(id),
  medio_pago text not null check (medio_pago in ('efectivo', 'tarjeta', 'transferencia')),
  total numeric not null default 0 check (total >= 0),
  estado text not null default 'activa' check (estado in ('pendiente', 'activa', 'anulada')),
  motivo_anulacion text,
  anulado_por uuid references usuarios(id),
  anulado_en timestamptz,
  fecha timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint ventas_anulacion_completa check (
    (estado in ('pendiente', 'activa') and motivo_anulacion is null and anulado_por is null and anulado_en is null)
    or (estado = 'anulada' and motivo_anulacion is not null and anulado_por is not null and anulado_en is not null)
  )
);

create table venta_items (
  id uuid primary key default gen_random_uuid(),
  venta_id uuid not null references ventas(id),
  sabor_id uuid not null references sabores(id),
  presentacion_id uuid not null references presentaciones(id),
  cantidad numeric not null check (cantidad > 0),    -- numeric: permite 0,5 kg
  precio_unitario numeric not null check (precio_unitario >= 0),
  created_at timestamptz not null default now()
);

-- Libro de movimientos: nunca se modifica ni se borra (ver trigger).
-- cantidad es con signo: negativa = sale stock, positiva = entra.
create table movimientos (
  id uuid primary key default gen_random_uuid(),
  tipo text not null check (tipo in ('produccion', 'venta', 'reversa', 'ajuste')),
  insumo_id uuid references insumos(id),
  lote_id uuid references lotes(id),
  cantidad numeric not null check (cantidad <> 0),
  tanda_id uuid references tandas(id),
  venta_id uuid references ventas(id),
  revierte_id uuid references movimientos(id),
  usuario_id uuid not null references usuarios(id),
  fecha timestamptz not null default now(),
  created_at timestamptz not null default now(),
  constraint movimientos_una_referencia check (num_nonnulls(insumo_id, lote_id) = 1),
  constraint movimientos_no_autorreferencia check (revierte_id is null or revierte_id <> id)
);

-- Índices para las consultas de uso frecuente
create index lotes_tanda_id_idx on lotes (tanda_id);
create index lotes_fefo_idx on lotes (fecha_vencimiento) where litros_disponibles > 0;
create index tandas_sabor_fecha_idx on tandas (sabor_id, fecha);
create index ventas_turno_id_idx on ventas (turno_id);
create index venta_items_venta_id_idx on venta_items (venta_id);
create index venta_items_sabor_id_idx on venta_items (sabor_id);
create index movimientos_insumo_id_idx on movimientos (insumo_id);
create index movimientos_lote_id_idx on movimientos (lote_id);
create index movimientos_tanda_id_idx on movimientos (tanda_id);
create index movimientos_venta_id_idx on movimientos (venta_id);
create index movimientos_revierte_id_idx on movimientos (revierte_id);