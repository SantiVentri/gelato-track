# GelatoTrack

Sistema de gestión de producción, stock y ventas para heladerías: tandas con descuento de insumos por receta, lotes con control de vencimiento (FEFO), caja por turno y reportes.

Stack: Next.js (App Router) con TypeScript, Supabase (Postgres, Auth y RLS), Vercel y GitHub Actions.

Documentación técnica completa en `docs/` y en el documento de arquitectura (versión 0.2.0).

## Requisitos

- Node.js 22 o superior
- Docker (para Supabase local)
- Supabase CLI: `npm install -g supabase` o uso con `npx supabase`

## Puesta en marcha local

```bash
npm ci
cp .env.example .env.local   # completar con los valores de la base local
npx supabase start           # levanta Postgres, Auth y Studio en Docker
npx supabase db reset        # aplica migraciones y carga supabase/seed.sql
npm run dev
```

La aplicación queda en [http://localhost:3000](http://localhost:3000).

Supabase Studio local: [http://localhost:54323](http://localhost:54323).

## Scripts

| Comando | Qué hace |
| --- | --- |
| `npm run dev` | Servidor de desarrollo |
| `npm run build` | Build de producción |
| `npm run lint` | ESLint |
| `npm run typecheck` | Chequeo de tipos con `tsc --noEmit` |
| `npm run test` | Tests unitarios (Vitest) sobre `lib/` |
| `npm run test:db` | Tests de funciones de Postgres y RLS contra Supabase local |
| `npm run test:e2e` | Tests de flujos con Playwright |

## Base de datos

- Las migraciones están en `supabase/migrations/` y son la única fuente de verdad del esquema.
- Las funciones de negocio (`registrar_tanda`, `registrar_venta`, `cerrar_turno`, `anular_venta`, `anular_tanda`, `guardar_receta`) viven en las migraciones.
- `supabase/seed.sql` carga datos de catálogo para desarrollo local. No se ejecuta en `db push`, así que nunca llega a staging ni a producción.
- Las migraciones aplicadas en producción no se editan. Cualquier cambio es una migración nueva (ADR-014).

## Entornos

| Entorno | Base de datos | Disparador | URL |
| --- | --- | --- | --- |
| Local | Supabase en Docker | Manual | `localhost:3000` |
| Preview | `gelato-track-staging` | Cada pull request | URL generada por Vercel |
| Staging | `gelato-track-staging` | Merge a `development` | `gelato-track-staging.vercel.app` |
| Producción | `gelato-track-prod` | Merge a `main` + aprobación manual | `gelato-track.vercel.app` |

## Flujo de ramas

- `development`: integración. Cada merge despliega a staging.
- `main`: producción. Solo recibe cambios desde `development` por pull request de promoción.
- `release`: rama que Vercel usa como Production Branch. La mantiene el pipeline: después de aprobar el deploy, `main` se publica en `release`. No se commitea a mano.
- Ramas de tarea: `feat/`, `fix/`, `chore/`, `ci/`, `test/`, `docs/`. Salen de `development` y vuelven a `development` por pull request con *Squash and merge*.

Convención de commits: Conventional Commits, con el número de PR al final, por ejemplo `feat(db): esquema base (#3)`.

## Despliegue a producción

1. Se mergea un PR de `development` a `main`.
2. El job `production` de GitHub Actions queda esperando aprobación en el environment `production`.
3. Al aprobarlo, se aplican las migraciones pendientes en `gelato-track-prod`, se publica `main` en `release` y Vercel despliega esa versión.
4. Se ejecuta el smoke test contra `gelato-track.vercel.app`.

Las credenciales de Supabase viven en GitHub (secrets por environment). En Vercel solo hay variables públicas (`NEXT_PUBLIC_SUPABASE_URL` y la clave publicable).

## Documentación

- `docs/` contiene los ADR (decisiones de arquitectura), la guía de despliegue y la guía de contribución.
- ADR-015 describe el modelo de ramas.
- ADR-009 describe la aprobación manual de producción.