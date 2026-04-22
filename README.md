# platform — CI/CD centralizado

Repo central con reusable workflows y composite actions para los proyectos de Refokus.

## Tipos de proyecto soportados

- **custom-code** (sitios Webflow) — 3 ambientes: preview, stage, production.
- **service** (backends en Vercel) — 2 ambientes: preview, production.
- **library** (paquetes a GitHub Packages con scope `@refokus-agency`) — ci + release.

## Qué contiene

```
.github/
├── actions/
│   └── setup/             # Composite action: detecta pm, instala deps, cache
└── workflows/
    ├── ci.yml             # Reusable: lint + typecheck + test + build
    ├── deploy.yml         # Reusable: deploy a Vercel (preview | stage | production)
    └── release.yml        # Reusable: semantic-release a GH Packages
```

## Cómo usarlo en un repo

Copiá el caller que corresponda desde `examples/` al repo y adaptalo:

- Custom-code → `examples/custom-code-caller.yml`
- Service → `examples/service-caller.yml`
- Library → `examples/library-caller.yml`

Renombralo a `.github/workflows/ci-cd.yml` (o como prefieras) en el repo target.

## Secrets requeridos

Los reusables asumen `secrets: inherit` desde el caller. El repo target tiene que tener disponibles:

| Secret | Requerido por | Nivel esperado |
|---|---|---|
| `GH_PAT_TOKEN` | todos | organización |
| `VERCEL_TOKEN` | deploy.yml | organización |
| `VERCEL_ORG_ID` | deploy.yml | organización |
| `VERCEL_PROJECT_ID` | deploy.yml | repo |

El `GH_PAT_TOKEN` necesita:
- `read:packages` para consumir del registry (`ci.yml`, `deploy.yml`).
- `write:packages` + `contents:write` para publicar (`release.yml`).

## Package managers

Los reusables auto-detectan el pm del caller por lockfile (pnpm / npm / bun). Si el auto-detect confunde o hay mezcla, pasá el input `package-manager` explícito:

```yaml
ci:
  uses: refokus-agency/platform/.github/workflows/ci.yml@main
  with:
    package-manager: bun
  secrets: inherit
```

## Inputs comunes

| Input | Default | Dónde |
|---|---|---|
| `node-version` | `24` | todos |
| `package-manager` | auto-detect | todos |
| `platform-ref` | `main` | todos |
| `environment` | **requerido** | `deploy.yml` |
| `run-lint` / `run-typecheck` / `run-test` / `run-build` | `true` | `ci.yml` |

## Scripts esperados en el caller

`ci.yml` corre los siguientes scripts si existen en `package.json` (no falla si faltan):

- `lint`
- `typecheck`
- `test`
- `build`

## Versionado

Por ahora los callers apuntan a `@main` — iteramos rápido mientras migran los primeros repos. Cuando se estabilice (2-3 meses sin cambios rotos) migramos a tags `@v1`.

## Migración de un repo existente

1. Borrar workflows viejos (`preview.yml`, `stage.yml`, `production.yml`, `ci.yml`, `release-package-version.yml`, etc.).
2. Copiar el caller de ejemplo correspondiente a `.github/workflows/`.
3. Verificar que los secrets estén configurados (org o repo).
4. Verificar que `package.json` tenga los scripts `lint` / `typecheck` / `test` / `build` si el repo los necesita (si faltan, se skipean — no falla).
5. Hacer un push a un branch de prueba y verificar que corra.
