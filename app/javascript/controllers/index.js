// Auto-registered Stimulus controllers.
//
// The `import controllers from "./**/*_controller.js"` glob is handled
// by the esbuild-rails plugin (see esbuild.config.mjs) — equivalent of
// `eagerLoadControllersFrom` from importmap-rails. Adding a new
// `*_controller.js` under app/javascript/controllers/ is enough; no
// manual import + register line to maintain.
//
// Naming contract: filename `foo_bar_controller.js` registers as
// `foo-bar` (esbuild-rails kebabs the snake_case stem). Use
// `data-controller="foo-bar"` to bind.

import { application } from "./application"

import controllers from "./**/*_controller.js"

controllers.forEach((controller) => {
  application.register(controller.name, controller.module.default)
})
