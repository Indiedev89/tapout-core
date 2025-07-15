// .eslintrc.js

module.exports = {
    env: {
      browser: false,
      es2021: true,
      mocha: true,
      node: true,
    },
    plugins: ["@typescript-eslint/eslint-plugin"],
    extends: [
      "plugin:@typescript-eslint/recommended",
      "prettier"
    ],
    parser: "@typescript-eslint/parser",
    parserOptions: {
      ecmaVersion: 12,
      sourceType: "module",
    },
    rules: {
      "@typescript-eslint/explicit-module-boundary-types": "off",
    },
  };