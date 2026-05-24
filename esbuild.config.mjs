// esbuild build config for the voodu-webui front-end bundle.
//
// We pull in the esbuild-rails plugin so the Stimulus controller index
// can glob-import every `*_controller.js` under app/javascript/ instead
// of a hand-maintained import-and-register list. The plugin is the
// jsbundling-rails equivalent of importmap's `eagerLoadControllersFrom`
// — same ergonomics, but resolved at build time.
//
// Mirrors the `build` script we used to inline in package.json:
//   esbuild app/javascript/*.* --bundle --sourcemap --format=esm
//                              --outdir=app/assets/builds
//                              --public-path=/assets
//
// Use `--watch` (passed via `pnpm run build -- --watch`) for the
// foreman/Procfile.dev rebuild loop.

import * as esbuild from "esbuild"
import rails from "esbuild-rails"
import path from "path"
import { fileURLToPath } from "url"

const __dirname  = path.dirname(fileURLToPath(import.meta.url))
const watchMode  = process.argv.includes("--watch")

const config = {
  entryPoints: ["app/javascript/*.*"],
  bundle:      true,
  sourcemap:   true,
  format:      "esm",
  outdir:      path.join(__dirname, "app/assets/builds"),
  publicPath:  "/assets",
  plugins:     [rails()],
  logLevel:    "info"
}

if (watchMode) {
  const ctx = await esbuild.context(config)
  await ctx.watch()
} else {
  await esbuild.build(config)
}
