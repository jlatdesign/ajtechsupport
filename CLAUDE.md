# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Static site for AJ Tech Support, served at `ajtechsupport.net` (`CNAME` is the GitHub Pages custom-domain file, so changes on `main` are effectively production). There is no build step, package manager, linter, or test suite. All HTML, CSS, and JS is inline in two files:

- `index.html`: public marketing site (ES/EN). Its `/inventario/` links open the portal.
- `inventario/index.html`: the technician portal, an ~11,000-line single-page app backed by Supabase.

`sopa` is an empty leftover file, not part of the site.

## Development

To preview, serve the repo root with any static server, for example `python -m http.server 8000`, and open `http://localhost:8000/inventario/`. Serve it rather than opening the file directly, because the site uses root-absolute links.

The portal talks to the live Supabase project configured at the top of its script, so a local preview reads and writes real data.

## Portal architecture (`inventario/index.html`)

The file is ordered as `<style>`, then the static HTML (views and modals, shown and hidden with the `hidden` class), then one `<script>`. Find a feature by searching for its banner comment, such as `/* ---------- Login ---------- */` or `/* ==== 📦 STOCK ... ==== */`. Identifiers and comments are mostly in Spanish, and the JS is global functions and state with no framework or modules.

- **Data:** `loadData()` fills the global arrays (`items`, `clientesDB`, `sedes`, `vpns`, `cloud`, `planos`, ...) and then calls `render()`. Feature modules such as jobs and stock keep their state in objects like `TRB` and `STK`.
- **Backend:** the `db` client uses the publishable key only, so never add a secret or `service_role` key here. Calls use tables, RPCs (`mi_perfil`, `equipos_listar`, `admin_*`, `registrar_actividad`, ...), and the Edge Functions `usuarios`, `upc`, `unifi`, and `reinicios`.
- **Schema:** the `supabase-*.sql` scripts are in `supabase/` and the Edge Function sources are in `supabase/functions/<name>/index.ts`. Nothing deploys them automatically: SQL is run by hand in the Supabase SQL Editor, and functions are pasted into the Supabase dashboard. These files may lag behind production.
- **Missing schema is tolerated:** because the SQL may not have been run yet, code checks for missing tables or columns, still saves what it can, and shows a `*_missing` / `*_sql` message naming the script to run. Follow this pattern for new columns (see `inventario/index.html:7677` and `:9320`).
- **Permissions:** `cargarPerfil()` loads the `PERM` object (`rol`, `admin`, `editar`, `borrar`, `claves`, `exportar`, `clientes`, ...). `PERM.roles` selects the RPC read paths in `loadData()`. UI checks are not the access boundary; enforcement belongs in the backend.
- **Secrets:** `SECRET_FIELDS` lists the stored credentials that the UI masks.
- **Device fields:** the `equipos` columns are declared in `FIELDS`, `PC_FIELDS`, and `PRN_FIELDS`, and `clean()` drops anything not listed there. Add new fields to these lists or they won't be saved.

## Conventions

- **Versioning:** the portal version appears twice and both must always match: the login screen (`inventario/index.html:1121`) and the app header (`:1137`). Small changes bump the last number (9.9.6 → 9.9.7); large changes bump the second number. Do not move to version 10 until the owner says so.
- **Confidential pricing:** operators must never see rates (tarifas) or profit percentages (% de utilidad).
- **Database changes:** every database change goes in its own `supabase/supabase-*.sql` file.
- **Translations:** English is the primary language. Everything is bilingual ES/EN: add every UI string as a flat key to both `I18N.en` and `I18N.es`, use `t('key', {var})` in JS, and use `data-i18n`, `data-i18n-ph`, or `data-i18n-title` in HTML. Stored values such as `tipo` and `estado` stay in Spanish; only their labels are translated, through `tTipo` and `tEstado`.
- **Rendering:** views are built as template strings, so pass all dynamic values through `esc()`.
- **Errors:** use `if (error) return fail(error, t('save_fail'));` for user-facing failures. `fail()` writes to the console and shows an alert.
- **Activity log:** record user actions with `logAct('event_name')`.
- **Long lines:** many lines are very long (up to ~10,000 characters), so use targeted searches and small read ranges.
- **Public site:** `index.html` has its own separate translation table `T` (`es`/`en`, applied through `data-i18n`) and shares no code with the portal.
