alter table presentaciones enable row level security;
alter table sabores enable row level security;
alter table precios enable row level security;
alter table insumos enable row level security;
alter table usuarios enable row level security;
alter table recetas enable row level security;
alter table receta_insumos enable row level security;
alter table tandas enable row level security;
alter table lotes enable row level security;
alter table turnos_caja enable row level security;
alter table ventas enable row level security;
alter table venta_items enable row level security;
alter table movimientos enable row level security;

-- Catálogo: todos los logueados leen; solo admin escribe
create policy presentaciones_select on presentaciones for select to authenticated using (true);
create policy presentaciones_admin on presentaciones for all to authenticated
  using (rol_actual() = 'admin') with check (rol_actual() = 'admin');

create policy sabores_select on sabores for select to authenticated using (true);
create policy sabores_admin on sabores for all to authenticated
  using (rol_actual() = 'admin') with check (rol_actual() = 'admin');

create policy precios_select on precios for select to authenticated using (true);
create policy precios_admin on precios for all to authenticated
  using (rol_actual() = 'admin') with check (rol_actual() = 'admin');

-- Insumos: solo admin y encargado los ven. El vendedor consulta stock por sabor.
create policy insumos_select on insumos for select to authenticated
  using (rol_actual() in ('admin', 'encargado'));
create policy insumos_admin on insumos for all to authenticated
  using (rol_actual() = 'admin') with check (rol_actual() = 'admin');

-- Recetas: todos leen. No hay políticas de escritura: se escribe solo con guardar_receta.
create policy recetas_select on recetas for select to authenticated using (true);
create policy receta_insumos_select on receta_insumos for select to authenticated using (true);

-- Usuarios: cada uno ve su perfil; el admin ve y activa a todos
create policy usuarios_select on usuarios for select to authenticated
  using (id = auth.uid() or rol_actual() = 'admin');
create policy usuarios_admin_update on usuarios for update to authenticated
  using (rol_actual() = 'admin') with check (rol_actual() = 'admin');

-- Producción: solo admin y encargado
create policy tandas_select on tandas for select to authenticated
  using (rol_actual() in ('admin', 'encargado'));
create policy lotes_select on lotes for select to authenticated
  using (rol_actual() in ('admin', 'encargado'));
create policy movimientos_select on movimientos for select to authenticated
  using (rol_actual() in ('admin', 'encargado'));

-- Caja: el admin ve todo; el vendedor ve solo sus turnos y ventas.
-- El encargado no ve caja.
create policy turnos_caja_select on turnos_caja for select to authenticated
  using (rol_actual() = 'admin' or (rol_actual() = 'vendedor' and usuario_id = auth.uid()));

create policy ventas_select on ventas for select to authenticated
  using (rol_actual() = 'admin' or (rol_actual() = 'vendedor' and usuario_id = auth.uid()));

create policy venta_items_select on venta_items for select to authenticated
  using (exists (
    select 1 from ventas v
     where v.id = venta_items.venta_id
       and (rol_actual() = 'admin' or (rol_actual() = 'vendedor' and v.usuario_id = auth.uid()))
  ));

-- Stock por sabor: función en lugar de vista, para que no saltee RLS.
-- Devuelve solo totales por sabor a usuarios logueados y activos.
create or replace function public.stock_por_sabor()
returns table (sabor_id uuid, nombre text, litros_disponibles numeric)
language sql
stable
security definer
set search_path = public
as $$
  select s.id, s.nombre, coalesce(sum(l.litros_disponibles), 0)
    from sabores s
    left join tandas t on t.sabor_id = s.id and t.estado = 'activa'
    left join lotes l on l.tanda_id = t.id
                     and l.litros_disponibles > 0
                     and l.fecha_vencimiento >= current_date
   where s.activo
     and rol_actual() is not null
   group by s.id, s.nombre
$$;

revoke execute on function public.stock_por_sabor() from public, anon;
grant execute on function public.stock_por_sabor() to authenticated;

-- Alertas de stock mínimo: respeta RLS (solo admin y encargado ven insumos)
create view alertas_stock with (security_invoker = true) as
select id as insumo_id, nombre, unidad, stock_actual, stock_minimo
  from insumos
 where stock_actual < stock_minimo;

grant select on alertas_stock to authenticated;
revoke all on public.alertas_stock from anon;