import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { adminClient, borrarUsuario, crearUsuario } from "./helpers";

describe("RLS: vendedor", () => {
  const admin = adminClient();
  let vendedor: Awaited<ReturnType<typeof crearUsuario>>;
  let saborId: string;
  let recetaId: string;

  beforeAll(async () => {
    vendedor = await crearUsuario("vendedor", `vendedor-${Date.now()}@test.local`);

    const { data: sabor, error: errorSabor } = await admin
      .from("sabores")
      .insert({ nombre: `Test RLS ${Date.now()}` })
      .select("id")
      .single();
    if (errorSabor) throw errorSabor;
    saborId = sabor.id;

    const { data: receta, error: errorReceta } = await admin
      .from("recetas")
      .insert({ sabor_id: saborId, version: 1 })
      .select("id")
      .single();
    if (errorReceta) throw errorReceta;
    recetaId = receta.id;
  });

  afterAll(async () => {
    if (recetaId) await admin.from("recetas").delete().eq("id", recetaId);
    if (saborId) await admin.from("sabores").delete().eq("id", saborId);
    if (vendedor) await borrarUsuario(vendedor.id);
  });

  it("no puede modificar una receta", async () => {
    const { data, error } = await vendedor.cliente
      .from("recetas")
      .update({ version: 99 })
      .eq("id", recetaId)
      .select();

    expect(error).toBeNull();
    expect(data).toHaveLength(0);

    const { data: fila } = await admin
      .from("recetas")
      .select("version")
      .eq("id", recetaId)
      .single();
    expect(fila?.version).toBe(1);
  });

  it("no puede insertar recetas directamente", async () => {
    const { error } = await vendedor.cliente
      .from("recetas")
      .insert({ sabor_id: saborId, version: 2 });

    expect(error).not.toBeNull();
  });

  it("no ve lotes", async () => {
    const { data, error } = await vendedor.cliente.from("lotes").select("id");

    expect(error).toBeNull();
    expect(data).toHaveLength(0);
  });

  it("no ve insumos", async () => {
    const { data, error } = await vendedor.cliente.from("insumos").select("id");

    expect(error).toBeNull();
    expect(data).toHaveLength(0);
  });

  it("puede consultar el stock por sabor con stock_por_sabor()", async () => {
    const { data, error } = await vendedor.cliente.rpc("stock_por_sabor");

    expect(error).toBeNull();
    expect(Array.isArray(data)).toBe(true);
  });

  it("no puede ejecutar stock_por_sabor() sin sesión", async () => {
    const anonimo = (await import("@supabase/supabase-js")).createClient(
      process.env.SUPABASE_URL!,
      process.env.SUPABASE_ANON_KEY!,
      { auth: { persistSession: false } },
    );
    const { error } = await anonimo.rpc("stock_por_sabor");

    expect(error).not.toBeNull();
  });
});