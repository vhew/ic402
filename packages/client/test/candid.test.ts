import { describe, it, expect } from 'vitest';
import { unwrapOpt, unwrapOptNat, toByteArray, toBytes } from '../src/candid.js';

describe('candid decode helpers', () => {
  describe('unwrapOpt', () => {
    it('returns the element of a Some opt / first of a vec', () => {
      expect(unwrapOpt<number>([42])).toBe(42);
      expect(unwrapOpt<number>([1, 2, 3])).toBe(1);
    });
    it('returns undefined for an empty opt (the bug the old inline code missed)', () => {
      expect(unwrapOpt([])).toBeUndefined();
    });
    it('tolerates a bare (non-array) value', () => {
      expect(unwrapOpt<number>(7)).toBe(7);
      expect(unwrapOpt(undefined)).toBeUndefined();
      expect(unwrapOpt(null)).toBeUndefined();
    });
  });

  describe('unwrapOptNat', () => {
    it('unwraps [bigint] / bare bigint / number / string to bigint', () => {
      expect(unwrapOptNat([500n], 1n)).toBe(500n);
      expect(unwrapOptNat(500n, 1n)).toBe(500n);
      expect(unwrapOptNat([500], 1n)).toBe(500n);
      expect(unwrapOptNat(['500'], 1n)).toBe(500n);
    });
    it('returns the fallback for an empty/missing opt', () => {
      expect(unwrapOptNat([], 1n)).toBe(1n);
      expect(unwrapOptNat(undefined, 1n)).toBe(1n);
    });
  });

  describe('toByteArray', () => {
    it('normalizes Uint8Array / number[] / indexed object to number[]', () => {
      expect(toByteArray(new Uint8Array([1, 2, 3]))).toEqual([1, 2, 3]);
      expect(toByteArray([4, 5])).toEqual([4, 5]);
      expect(toByteArray({ 0: 9, 1: 8 })).toEqual([9, 8]);
    });
  });

  describe('toBytes', () => {
    it('passes a Uint8Array through and wraps a number[] as bytes', () => {
      const u = new Uint8Array([1, 2, 3]);
      expect(toBytes(u)).toBe(u);
      expect(Array.from(toBytes([4, 5, 6]))).toEqual([4, 5, 6]);
    });
  });
});
