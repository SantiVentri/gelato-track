import { expect, test } from "@playwright/test";

test.fixme("la aplicación responde y muestra la pantalla de login", async ({ page }) => {
  const response = await page.goto("/login");
  expect(response?.ok()).toBeTruthy();
  await expect(page.getByRole("heading", { name: /iniciar sesión/i })).toBeVisible();
});

test.fixme("login con usuario de prueba y consulta de stock", async ({ page }) => {
  test.skip(
    !process.env.SMOKE_USER_EMAIL || !process.env.SMOKE_USER_PASSWORD,
    "requiere SMOKE_USER_EMAIL y SMOKE_USER_PASSWORD",
  );

  await page.goto("/login");
  await page.getByLabel("Email").fill(process.env.SMOKE_USER_EMAIL!);
  await page.getByLabel("Contraseña").fill(process.env.SMOKE_USER_PASSWORD!);
  await page.getByRole("button", { name: /ingresar/i }).click();

  await expect(page).toHaveURL(/\/panel/);
  await expect(page.getByRole("heading", { name: /stock/i })).toBeVisible();
});