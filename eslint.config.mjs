import js from "@eslint/js"
import globals from "globals"

// Flat config for the Stimulus / Turbo JS under app/javascript (vanilla ES
// modules — no React/JSX here, so the JSX rules from the global preference
// set don't apply). The padding-line-between-statements block mirrors the
// stella project: blank lines before `return`, around block-like statements
// (if/for/while/switch/try), after const/let/var blocks, after imports, and
// around function/class/export declarations — all auto-fixable with --fix.
export default [
  {
    ignores: [
      "app/assets/builds/**",
      "node_modules/**",
      "public/**",
      "vendor/**",
      "tmp/**",
      "*.config.mjs"
    ]
  },
  {
    files: ["app/javascript/**/*.js"],
    languageOptions: {
      ecmaVersion: "latest",
      sourceType: "module",
      globals: { ...globals.browser }
    },
    rules: {
      ...js.configs.recommended.rules,
      "no-var": "error",
      "prefer-const": "warn",
      curly: ["warn", "multi-line"],
      "no-console": ["warn", { allow: ["warn", "error"] }],
      "no-inline-comments": "warn",
      // Underscore-prefixed = intentionally unused (catch (_e), (_) etc.).
      "no-unused-vars": [
        "warn",
        { argsIgnorePattern: "^_", varsIgnorePattern: "^_", caughtErrorsIgnorePattern: "^_" }
      ],

      "padding-line-between-statements": [
        "warn",
        { blankLine: "always", prev: "*", next: "return" },
        { blankLine: "always", prev: ["const", "let", "var"], next: "*" },
        { blankLine: "any", prev: ["const", "let", "var"], next: ["const", "let", "var"] },
        { blankLine: "always", prev: "block-like", next: "*" },
        { blankLine: "always", prev: "*", next: "block-like" },
        { blankLine: "always", prev: "import", next: "*" },
        { blankLine: "any", prev: "import", next: "import" },
        { blankLine: "always", prev: "*", next: ["function", "class", "export"] },
        { blankLine: "always", prev: ["function", "class", "export"], next: "*" }
      ]
    }
  }
]
