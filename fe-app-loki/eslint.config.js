// eslint.config.js
import js from '@eslint/js';
import tseslint from 'typescript-eslint';
import prettier from 'eslint-config-prettier';

export default [
    js.configs.recommended,
    ...tseslint.configs.recommended,
    {
        ignores: ['node_modules', 'watch-upload.js'],
    },
    {
        // The tests run in node rather than in a LuCI page, so they reach the
        // platform the views never see.
        files: ['src/**/*.test.js', 'tests/**/*.js'],
        languageOptions: {
            globals: {
                Buffer: 'readonly',
                TextDecoder: 'readonly',
                URL: 'readonly',
                console: 'readonly',
                process: 'readonly',
                setTimeout: 'readonly',
                clearTimeout: 'readonly',
                setInterval: 'readonly',
                clearInterval: 'readonly',
            },
        },
    },
    {
        rules: {
            'no-console': 'off',
            'no-unused-vars': 'off',
            '@typescript-eslint/no-unused-vars': [
                'warn',
                {
                    argsIgnorePattern: '^_',
                    varsIgnorePattern: '^_',
                    caughtErrorsIgnorePattern: '^_',
                },
            ],
        },
    },
    {
        // LuCI's E() puts a lone string in as markup; helpers/element.ts puts
        // it in as text, and is the only place the global is reached.
        files: ['src/**/*.ts'],
        ignores: ['src/helpers/element.ts', 'src/**/tests/**', 'src/**/*.d.ts'],
        rules: {
            'no-restricted-globals': [
                'error',
                {
                    name: 'E',
                    message:
                        "Import E from helpers/element: LuCI's E() takes a lone string as HTML.",
                },
            ],
        },
    },
    prettier,
];
