import js from '@eslint/js';
import tseslint from 'typescript-eslint';

export default [
  js.configs.recommended,
  ...tseslint.configs.recommended,
  {
    files: ['**/*.ts'],
    rules: {
      '@typescript-eslint/no-unused-vars': ['warn', { argsIgnorePattern: '^_' }],
      // C5: a token amount wrapped in Number() silently truncates uint256 values above
      // 2^53. Carry amounts as bigint / decimal strings, never JS numbers.
      'no-restricted-syntax': [
        'error',
        {
          selector:
            "CallExpression[callee.name='Number'] > Identifier[name=/^(amount|value|deposit|cumulative|atomic|paidAmount|maxAmountRequired|perCallMax|sessionMax)/i]",
          message:
            'Do not wrap a token amount in Number() — it truncates uint256 amounts above 2^53 (audit C5). Use BigInt and carry amounts as decimal strings.',
        },
        {
          selector:
            "CallExpression[callee.name='Number'] > MemberExpression[property.name=/^(amount|value|deposit|cumulative|atomic|paidAmount|maxAmountRequired|perCallMax|sessionMax)/i]",
          message:
            'Do not wrap a token amount in Number() — it truncates uint256 amounts above 2^53 (audit C5). Use BigInt and carry amounts as decimal strings.',
        },
      ],
    },
  },
  {
    ignores: ['**/dist/**', '**/node_modules/**', '.mops/', '.icp/'],
  },
];
