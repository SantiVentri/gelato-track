-- =============================================================
-- Datos de catálogo para desarrollo local.
-- Se ejecuta con `npx supabase db reset`.
-- NO se ejecuta con `supabase db push`. NO usar en producción.
-- Los ids los genera gen_random_uuid(). Se puede correr varias veces.
-- =============================================================

-- Presentaciones
insert into presentaciones (nombre, litros_equivalentes) values
  ('vasito',    0.120),
  ('cucurucho', 0.080),
  ('cuarto',    0.250),
  ('kilo',      1.000)
on conflict (nombre) do nothing;

-- Sabores
insert into sabores (nombre) values
  ('Dulce de leche'),
  ('Chocolate')
on conflict (nombre) do nothing;

-- Insumos. Cacao y crema están por debajo del mínimo a propósito,
-- para probar las alertas de stock.
insert into insumos (nombre, unidad, stock_actual, stock_minimo) values
  ('Leche entera',             'l',  50, 10),
  ('Crema de leche',           'l',   2,  3),
  ('Azúcar',                   'kg', 15,  5),
  ('Dulce de leche repostero', 'kg',  8,  2),
  ('Cacao amargo',             'kg',  1,  2)
on conflict (nombre) do nothing;

-- Recetas, versión 1 de cada sabor
insert into recetas (sabor_id, version)
select id, 1
  from sabores
 where nombre in ('Dulce de leche', 'Chocolate')
on conflict (sabor_id, version) do nothing;

-- Insumos por receta (cantidad por litro de helado).
-- Se buscan los ids por nombre, no se escriben a mano.
insert into receta_insumos (receta_id, insumo_id, cantidad_por_litro)
select r.id, i.id, v.cantidad
  from (values
    ('Dulce de leche', 'Leche entera',             0.800),
    ('Dulce de leche', 'Crema de leche',           0.200),
    ('Dulce de leche', 'Azúcar',                   0.150),
    ('Dulce de leche', 'Dulce de leche repostero', 0.100),
    ('Chocolate',      'Leche entera',             0.750),
    ('Chocolate',      'Crema de leche',           0.200),
    ('Chocolate',      'Azúcar',                   0.150),
    ('Chocolate',      'Cacao amargo',             0.050)
  ) as v(sabor, insumo, cantidad)
  join sabores s   on s.nombre = v.sabor
  join recetas r   on r.sabor_id = s.id and r.version = 1
  join insumos i   on i.nombre = v.insumo
on conflict (receta_id, insumo_id) do nothing;

-- Precios: mismo precio para todos los sabores.
-- vigente_desde toma current_date por default.
insert into precios (sabor_id, presentacion_id, precio)
select s.id, p.id,
       case p.nombre
         when 'vasito'    then 1500
         when 'cucurucho' then 1800
         when 'cuarto'    then 4500
         when 'kilo'      then 9000
       end
  from sabores s
  cross join presentaciones p
on conflict (sabor_id, presentacion_id, vigente_desde) do nothing;