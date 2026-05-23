import js from "@eslint/js"
import globals from "globals"

export default [
    js.configs.recommended,
    {
        ignores: ["web/vendor/**", "target/**", "node_modules/**"]
    },
    {
        files: ["**/*.{js,mjs,cjs}"],
        languageOptions: { globals: { ...globals.browser, Hls: "readonly" } },
        rules: {
            "no-unused-vars": [
                "error",
                {
                    argsIgnorePattern: "^_",
                    varsIgnorePattern: "^_",
                    caughtErrorsIgnorePattern: "^_"
                }
            ]
        }
    }
]
