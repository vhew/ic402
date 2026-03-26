/// Motoko unit tests for Eip712 (EIP-712 typed data hashing).
import Eip712 "../src/ic402/Eip712";
import EvmUtils "../src/ic402/EvmUtils";
import { test; suite } "mo:test";

suite("Eip712", func() {

  // ── Test vectors generated with viem/cast ──
  // USDC on Base Sepolia: 0x036CbD53842c5426634e7929541eC2318f3dCF7e, chainId=84532

  let baseSepUsdcAddr = EvmUtils.hexToBytes("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
  let baseSepChainId : Nat = 84532;

  suite("transferWithAuthorizationTypeHash", func() {
    test("matches keccak256 of canonical string", func() {
      let th = Eip712.transferWithAuthorizationTypeHash();
      assert(th.size() == 32);
      assert(th[0] == 0x7c);
      assert(th[1] == 0x7c);
      assert(th[2] == 0x6c);
      assert(th[3] == 0xdb);
    });
  });

  suite("usdcDomainSeparator", func() {
    test("Base Sepolia matches viem output", func() {
      let ds = Eip712.usdcDomainSeparator(baseSepChainId, baseSepUsdcAddr);
      // Expected: 0x2f5ab5eec6c6d261a8ad2b303ae4ef05c8509de2250e072c3a2df0ad7f9f068b
      let expected = EvmUtils.hexToBytes("0x2f5ab5eec6c6d261a8ad2b303ae4ef05c8509de2250e072c3a2df0ad7f9f068b");
      assert(ds == expected);
    });
  });

  suite("hashTransferWithAuthorization", func() {
    test("known inputs produce expected struct hash", func() {
      let from = EvmUtils.hexToBytes("0xD2d6dC98E2fB707b74e0c3d453392a50a087790b");
      let to = EvmUtils.hexToBytes("0x167fa1c5fa0bc0bd005867f2a6df9cb4aac89e03");
      let value : Nat = 1000;
      let validAfter : Nat = 0;
      let validBefore : Nat = 1800000000;
      let nonce = EvmUtils.natToBytes(1, 32);

      let sh = Eip712.hashTransferWithAuthorization(from, to, value, validAfter, validBefore, nonce);
      // Expected: 0x3138e30595ca681b90a91c16dabad07f35b65dbbe64f5dc3f488dfe5b2e3a1be
      let expected = EvmUtils.hexToBytes("0x3138e30595ca681b90a91c16dabad07f35b65dbbe64f5dc3f488dfe5b2e3a1be");
      assert(sh == expected);
    });
  });

  suite("digest", func() {
    test("full EIP-712 digest matches viem output", func() {
      let domSep = EvmUtils.hexToBytes("0x2f5ab5eec6c6d261a8ad2b303ae4ef05c8509de2250e072c3a2df0ad7f9f068b");
      let structHash = EvmUtils.hexToBytes("0x3138e30595ca681b90a91c16dabad07f35b65dbbe64f5dc3f488dfe5b2e3a1be");

      let d = Eip712.digest(domSep, structHash);
      // Expected: 0x0ddbd8c5275ad4a8ae82da88329f4af26cedfa33eaf602d5d7f6021160cffd80
      let expected = EvmUtils.hexToBytes("0x0ddbd8c5275ad4a8ae82da88329f4af26cedfa33eaf602d5d7f6021160cffd80");
      assert(d == expected);
    });

    test("digest is 32 bytes", func() {
      let domSep = EvmUtils.natToBytes(0, 32);
      let structHash = EvmUtils.natToBytes(0, 32);
      let d = Eip712.digest(domSep, structHash);
      assert(d.size() == 32);
    });
  });

  suite("transferWithAuthorizationSelector", func() {
    test("matches 0xe3ee160e", func() {
      let sel = Eip712.transferWithAuthorizationSelector();
      assert(sel[0] == 0xe3);
      assert(sel[1] == 0xee);
      assert(sel[2] == 0x16);
      assert(sel[3] == 0x0e);
    });
  });

  suite("integration", func() {
    test("full flow: domain + struct + digest is deterministic", func() {
      let from = EvmUtils.hexToBytes("0xD2d6dC98E2fB707b74e0c3d453392a50a087790b");
      let to = EvmUtils.hexToBytes("0x167fa1c5fa0bc0bd005867f2a6df9cb4aac89e03");

      let domSep = Eip712.usdcDomainSeparator(baseSepChainId, baseSepUsdcAddr);
      let sh = Eip712.hashTransferWithAuthorization(from, to, 1000, 0, 1800000000, EvmUtils.natToBytes(1, 32));
      let d1 = Eip712.digest(domSep, sh);
      let d2 = Eip712.digest(domSep, sh);
      assert(d1 == d2);
    });

    test("different values produce different digests", func() {
      let from = EvmUtils.hexToBytes("0xD2d6dC98E2fB707b74e0c3d453392a50a087790b");
      let to = EvmUtils.hexToBytes("0x167fa1c5fa0bc0bd005867f2a6df9cb4aac89e03");
      let nonce = EvmUtils.natToBytes(1, 32);

      let domSep = Eip712.usdcDomainSeparator(baseSepChainId, baseSepUsdcAddr);
      let sh1 = Eip712.hashTransferWithAuthorization(from, to, 1000, 0, 1800000000, nonce);
      let sh2 = Eip712.hashTransferWithAuthorization(from, to, 2000, 0, 1800000000, nonce);
      assert(sh1 != sh2);

      let d1 = Eip712.digest(domSep, sh1);
      let d2 = Eip712.digest(domSep, sh2);
      assert(d1 != d2);
    });
  });

  suite("domainSeparator custom name", func() {
    test("USDC name matches on-chain DOMAIN_SEPARATOR for Base Sepolia", func() {
      let ds = Eip712.domainSeparator("USDC", "2", baseSepChainId, baseSepUsdcAddr);
      let expected = EvmUtils.hexToBytes("0x71f17a3b2ff373b803d70a5a07c046c1a2bc8e89c09ef722fcb047abe94c9818");
      assert(ds == expected);
    });
  });
});
