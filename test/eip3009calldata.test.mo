/// Money-path guard for the EIP-3009 `transferWithAuthorization` on-chain encoding.
///
/// Bug (2.5.3): the payer signature `v` is normalized 27/28 → 0/1 at parse (correct for ic402's
/// internal ecRecover) but was then written RAW into the on-chain calldata, where USDC's ecrecover
/// requires 27/28 — so every inbound EVM x402 settlement reverted on-chain. Invisible to unit
/// tests because it only manifested on a real broadcast.
///
/// This makes it visible without a chain: it builds the actual calldata and recovers the signer
/// from the ENCODED (v, r, s) exactly as the on-chain contract would (recovery id = v − 27, NOT
/// re-normalized). A 0/1 calldata value recovers the wrong signer and fails here. Catches the whole
/// class — wrong v form, swapped r/s, wrong digest — in milliseconds.
import { test; suite } "mo:test";
import EvmSender "../src/ic402/EvmSender";
import EvmUtils "../src/ic402/EvmUtils";
import EvmAddress "../src/ic402/EvmAddress";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";

// calldata layout: selector(4) ++ 9 inline uint256 words. v is the 7th word; its byte is the
// word's last byte. r/s are the 8th/9th words.
let V_BYTE : Nat = 4 + 6 * 32 + 31; // 227
let R_OFF : Nat = 4 + 7 * 32; // 228
let S_OFF : Nat = 4 + 8 * 32; // 260

let addr20 : [Nat8] = Array.tabulate<Nat8>(20, func(_ : Nat) : Nat8 = 0xAB);
let b32 : [Nat8] = Array.tabulate<Nat8>(32, func(_ : Nat) : Nat8 = 0x11);

// Build calldata for a given recovery-id `v` and return the encoded on-chain v byte.
func encodedV(v : Nat8) : Nat8 {
  let cd = EvmSender.buildTransferWithAuthorizationCalldata(addr20, addr20, 1, 0, 1, b32, v, b32, b32);
  cd[V_BYTE];
};

// Fixture: a known EOA signed DIGEST off-chain (secp256k1), producing (v=28, r, s). ic402's
// ecRecover returns the 33-byte COMPRESSED public key (the verify path derives the address from
// it), so recovering to this pubkey is equivalent to "the chain recovers the payer".
let PAYER_PUBKEY : [Nat8] = [3, 185, 128, 139, 39, 214, 99, 51, 17, 31, 156, 144, 167, 90, 103, 155, 126, 70, 105, 87, 169, 176, 161, 51, 139, 56, 131, 40, 180, 219, 230, 25, 154];
let DIGEST : [Nat8] = [196, 53, 60, 76, 137, 182, 103, 103, 223, 227, 68, 248, 26, 3, 47, 245, 92, 96, 165, 138, 77, 124, 89, 4, 94, 192, 73, 226, 68, 157, 204, 173];
let FV : Nat8 = 28;
let FR : [Nat8] = [250, 150, 37, 104, 224, 71, 247, 115, 30, 128, 107, 243, 8, 114, 38, 38, 95, 111, 53, 176, 3, 172, 114, 107, 212, 195, 122, 250, 96, 37, 1, 235];
let FS : [Nat8] = [109, 103, 194, 160, 249, 39, 251, 199, 86, 171, 40, 225, 241, 142, 50, 199, 131, 27, 12, 84, 201, 147, 96, 162, 144, 184, 238, 44, 171, 36, 48, 70];

suite(
  "EIP-3009 transferWithAuthorization calldata — on-chain v",
  func() {
    test(
      "denormalizes the internal 0/1 recovery id to on-chain 27/28",
      func() {
        assert encodedV(0) == 27;
        assert encodedV(1) == 28;
      },
    );

    test(
      "idempotent — an already-27/28 v passes through unchanged",
      func() {
        assert encodedV(27) == 27;
        assert encodedV(28) == 28;
      },
    );

    test(
      "the ENCODED (v, r, s) recover the payer — the chain would accept it",
      func() {
        // Ingress normalizes the as-signed 28 → recovery id 1 (what settle passes down).
        let recId = EvmUtils.recoveryIdFromV(FV);
        let cd = EvmSender.buildTransferWithAuthorizationCalldata(addr20, addr20, 20_000, 0, 1, b32, recId, FR, FS);

        let onChainV = cd[V_BYTE];
        assert onChainV == 27 or onChainV == 28; // on-chain form (guards the subtraction below)

        let rOut = Array.subArray<Nat8>(cd, R_OFF, 32);
        let sOut = Array.subArray<Nat8>(cd, S_OFF, 32);
        // Recover the way the CHAIN does: recovery id = v − 27, taken straight from the calldata.
        switch (EvmAddress.ecRecover(DIGEST, rOut, sOut, onChainV - 27 : Nat8)) {
          case (?recovered) { assert Array.equal<Nat8>(recovered, PAYER_PUBKEY, Nat8.equal) };
          case (null) { assert false };
        };
      },
    );
  },
);
