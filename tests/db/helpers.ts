import { createClient, type SupabaseClient } from "@supabase/supabase-js";

const URL = process.env.SUPABASE_URL!;
const ANON_KEY = process.env.SUPABASE_ANON_KEY!;
const SERVICE_ROLE_KEY = process.env.SUPABASE_SERVICE_ROLE_KEY!;

const opciones = { auth: { persistSession: false, autoRefreshToken: false } };

// Cliente con service role: saltea RLS. Solo para preparar y limpiar datos.
export function adminClient(): SupabaseClient {
  return createClient(URL, SERVICE_ROLE_KEY, opciones);
}

// Crea un usuario en Auth, le asigna rol y lo activa, e inicia sesión
// con un cliente con anon key, que es el que respeta RLS.
export async function crearUsuario(
  rol: "admin" | "encargado" | "vendedor",
  email: string,
) {
  const password = "test-password-123";
  const admin = adminClient();

  const { data, error } = await admin.auth.admin.createUser({
    email,
    password,
    email_confirm: true,
  });
  if (error) throw error;
  const id = data.user.id;

  // El trigger crear_perfil_usuario ya creó el perfil inactivo.
  const { error: errorPerfil } = await admin
    .from("usuarios")
    .update({ rol, activo: true })
    .eq("id", id);
  if (errorPerfil) throw errorPerfil;

  const cliente = createClient(URL, ANON_KEY, opciones);
  const { error: errorLogin } = await cliente.auth.signInWithPassword({
    email,
    password,
  });
  if (errorLogin) throw errorLogin;

  return { id, cliente };
}

export async function borrarUsuario(id: string) {
  await adminClient().auth.admin.deleteUser(id);
}