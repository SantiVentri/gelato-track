import { describe, expect, it } from "vitest";
import { adminClient, crearUsuario } from "./helpers";

const admin = adminClient();

// Desde el SDK, cualquier error de PostgREST llega como objeto, no como excepción.
function ok<T>(r: { data: T; error: { message: string } | null }): NonNullable<T> {
  if (r.error) throw new Error(r.error.message);
  return r.data as NonNullable<T>;
}

function unico(prefijo: string) {
  return `${prefijo} ${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

function hoyMas(dias: number) {
  const d = new Date();
  d.setDate(d.getDate() + dias);
  return d.toISOString().slice(0, 10);
}

// Crea sabor, insumo y receta vigente con un único ingrediente.
async function prepararSabor(cantidadPorLitro: number, stockInsumo: number) {
  const sabor = ok(
    await admin.from("sabores").insert({ nombre: unico("Sabor test") }).select("id").single(),
  );
  const insumo = ok(
    await admin
      .from("insumos")
      .insert({ nombre: unico("Insumo test"), unidad: "l", stock_actual: stockInsumo, stock_minimo: 0 })
      .select("id")
      .single(),
  );
  const receta = ok(
    await admin.from("recetas").insert({ sabor_id: sabor.id, version: 1 }).select("id").single(),
  );
  ok(
    await admin
      .from("receta_insumos")
      .insert({ receta_id: receta.id, insumo_id: insumo.id, cantidad_por_litro: cantidadPorLitro }),
  );
  return { saborId: sabor.id, insumoId: insumo.id };
}

describe("registrar_tanda", () => {
  it("no deja filas a medias si falta un insumo", async () => {
    const encargado = await crearUsuario("encargado", `enc-${Date.now()}@test.local`);
    const { saborId, insumoId } = await prepararSabor(0.1, 0.5);

    // Necesita 0.1 × 10 = 1 l y hay 0.5 l.
    const { error } = await encargado.cliente.rpc("registrar_tanda", {
      p_sabor_id: saborId,
      p_litros: 10,
      p_fecha_vencimiento: hoyMas(5),
    });
    expect(error).not.toBeNull();

    const tandas = ok(await admin.from("tandas").select("id").eq("sabor_id", saborId));
    const { data: stock } = await admin.from("insumos").select("stock_actual").eq("id", insumoId).single();

    expect(tandas).toHaveLength(0);
    expect(stock?.stock_actual).toBe(0.5);
  });

  it("descuenta insumos y crea lote y movimientos", async () => {
    const encargado = await crearUsuario("encargado", `enc2-${Date.now()}@test.local`);
    const { saborId, insumoId } = await prepararSabor(0.1, 10);

    const { error } = await encargado.cliente.rpc("registrar_tanda", {
      p_sabor_id: saborId,
      p_litros: 5,
      p_fecha_vencimiento: hoyMas(5),
    });
    expect(error).toBeNull();

    const { data: stock } = await admin.from("insumos").select("stock_actual").eq("id", insumoId).single();
    expect(stock?.stock_actual).toBeCloseTo(9.5);

    const lotes = ok(
      await admin.from("lotes").select("litros_disponibles, tandas!inner(sabor_id)").eq("tandas.sabor_id", saborId),
    );
    expect(lotes).toHaveLength(1);
    expect(lotes[0].litros_disponibles).toBe(5);
  });
});

describe("registrar_venta (FEFO)", () => {
  it("descuenta primero del lote que vence antes", async () => {
    const encargado = await crearUsuario("encargado", `enc3-${Date.now()}@test.local`);
    const vendedor = await crearUsuario("vendedor", `ven-${Date.now()}@test.local`);
    const { saborId } = await prepararSabor(0.1, 100);
    
    // Se insertan al revés a propósito: si la función no ordena por
    // vencimiento, el orden de inserción la lleva al lote equivocado.
    await encargado.cliente.rpc("registrar_tanda", {
      p_sabor_id: saborId, p_litros: 1, p_fecha_vencimiento: hoyMas(10),
    });
    await encargado.cliente.rpc("registrar_tanda", {
      p_sabor_id: saborId, p_litros: 1, p_fecha_vencimiento: hoyMas(5),
    });

    const presentacion = ok(
      await admin
        .from("presentaciones")
        .insert({ nombre: unico("Pres test"), litros_equivalentes: 0.25 })
        .select("id")
        .single(),
    );
    ok(await admin.from("precios").insert({ sabor_id: saborId, presentacion_id: presentacion.id, precio: 1000 }));

    const turno = ok(
      await admin
        .from("turnos_caja")
        .insert({ usuario_id: vendedor.id, estado: "abierto", monto_inicial: 0 })
        .select("id")
        .single(),
    );

    // 2 presentaciones de 0.25 l = 0.5 l.
    const { data: ventaId, error } = await vendedor.cliente.rpc("registrar_venta", {
      p_turno_id: turno.id,
      p_medio_pago: "efectivo",
      p_items: [{ sabor_id: saborId, presentacion_id: presentacion.id, cantidad: 2 }],
    });
    expect(error).toBeNull();

    const movimientos = ok(
      await admin
        .from("movimientos")
        .select("cantidad, lote_id, lotes!inner(fecha_vencimiento)")
        .eq("venta_id", ventaId as string),
    );
    expect(movimientos).toHaveLength(1);
    expect(movimientos[0].cantidad).toBeCloseTo(-0.5);

    // El lote que vence primero quedó con 0.5 l, el otro intacto.
    const lotes = ok(
      await admin
        .from("lotes")
        .select("fecha_vencimiento, litros_disponibles, tandas!inner(sabor_id)")
        .eq("tandas.sabor_id", saborId)
        .order("fecha_vencimiento"),
    );
    expect(lotes[0].litros_disponibles).toBeCloseTo(0.5);
    expect(lotes[1].litros_disponibles).toBe(1);
  });
});

describe("cerrar_turno", () => {
  it("no cierra un turno con ventas pendientes", async () => {
    const vendedor = await crearUsuario("vendedor", `ven2-${Date.now()}@test.local`);
    const turno = ok(
      await admin
        .from("turnos_caja")
        .insert({ usuario_id: vendedor.id, estado: "abierto", monto_inicial: 0 })
        .select("id")
        .single(),
    );
    ok(
      await admin
        .from("ventas")
        .insert({ turno_id: turno.id, usuario_id: vendedor.id, medio_pago: "efectivo", total: 0, estado: "pendiente" }),
    );

    const { error } = await vendedor.cliente.rpc("cerrar_turno", {
      p_turno_id: turno.id,
      p_monto_contado: 0,
    });
    expect(error).not.toBeNull();

    const { data: t } = await admin.from("turnos_caja").select("estado").eq("id", turno.id).single();
    expect(t?.estado).toBe("abierto");
  });
});