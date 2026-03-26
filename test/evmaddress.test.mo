/// Test EVM address derivation against well-known Ethereum test vectors.
/// All expected values verified via `cast wallet address` (foundry).
import EvmAddress "../src/ic402/EvmAddress";
import EvmUtils "../src/ic402/EvmUtils";
import EcdsaCurve "mo:ecdsa/Curve";
import EcdsaLib "mo:ecdsa";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import { test; suite } "mo:test";

suite("EvmAddress", func() {

  // ── keccak256 ──

  test("keccak256 of empty input", func() {
    // Universal constant: keccak256("") from every Ethereum implementation
    let hex = EvmAddress.toHex(EvmAddress.keccak256([]));
    assert(hex == "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470");
  });

  test("keccak256 of Transfer event signature", func() {
    // keccak256("Transfer(address,address,uint256)") — ERC-20 Transfer topic
    // Verified: cast keccak "Transfer(address,address,uint256)"
    let hex = EvmAddress.toHex(EvmAddress.keccak256Text("Transfer(address,address,uint256)"));
    assert(hex == "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef");
  });

  // ── Address derivation: even parity (0x02 prefix) ──

  test("private key 1 → secp256k1 generator point G (0x02 prefix)", func() {
    // G = 02 79BE667E F9DCBBAC 55A06295 CE870B07 029BFCDB 2DCE28D9 59F2815B 16F81798
    // Address: 0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf
    // Verified: cast wallet address --private-key 0x01
    let g : [Nat8] = [
      0x02,0x79,0xbe,0x66,0x7e,0xf9,0xdc,0xbb,0xac,0x55,0xa0,0x62,
      0x95,0xce,0x87,0x0b,0x07,0x02,0x9b,0xfc,0xdb,0x2d,0xce,0x28,
      0xd9,0x59,0xf2,0x81,0x5b,0x16,0xf8,0x17,0x98,
    ];
    switch (EvmAddress.fromCompressedPublicKey(g)) {
      case (#ok(addr)) { assert(addr == "0x7e5f4552091a69125d5dfcb7b8c2659029395bdf") };
      case (#err(_)) { assert(false) };
    };
  });

  test("private key 2 (0x02 prefix)", func() {
    // 2*G = 02 C6047F94 41ED7D6D 3045406E 95C07CD8 5C778E4B 8CEF3CA7 ABAC09B9 5C709EE5
    // Address: 0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF
    // Verified: cast wallet address --private-key 0x02
    let pk2 : [Nat8] = [
      0x02,0xc6,0x04,0x7f,0x94,0x41,0xed,0x7d,0x6d,0x30,0x45,0x40,
      0x6e,0x95,0xc0,0x7c,0xd8,0x5c,0x77,0x8e,0x4b,0x8c,0xef,0x3c,
      0xa7,0xab,0xac,0x09,0xb9,0x5c,0x70,0x9e,0xe5,
    ];
    switch (EvmAddress.fromCompressedPublicKey(pk2)) {
      case (#ok(addr)) { assert(addr == "0x2b5ad5c4795c026514f8317c7a215e218dccd6cf") };
      case (#err(_)) { assert(false) };
    };
  });

  // ── Address derivation: odd parity (0x03 prefix) ──

  test("private key 6 (0x03 prefix — odd parity)", func() {
    // 6*G = 03 FFF97BD5 755EEEA4 20453A14 355235D3 82F6472F 8568A18B 2F057A14 60297556
    // Address: 0xE57bFE9F44b819898F47BF37E5AF72a0783e1141
    // Verified: cast wallet address --private-key 0x06
    let pk6 : [Nat8] = [
      0x03,0xff,0xf9,0x7b,0xd5,0x75,0x5e,0xee,0xa4,0x20,0x45,0x3a,
      0x14,0x35,0x52,0x35,0xd3,0x82,0xf6,0x47,0x2f,0x85,0x68,0xa1,
      0x8b,0x2f,0x05,0x7a,0x14,0x60,0x29,0x75,0x56,
    ];
    switch (EvmAddress.fromCompressedPublicKey(pk6)) {
      case (#ok(addr)) { assert(addr == "0xe57bfe9f44b819898f47bf37e5af72a0783e1141") };
      case (#err(_)) { assert(false) };
    };
  });

  // ── Error cases ──

  test("rejects invalid key length", func() {
    switch (EvmAddress.fromCompressedPublicKey([0x02, 0x01])) {
      case (#err(_)) {};
      case (#ok(_)) { assert(false) };
    };
  });

  test("rejects invalid prefix byte", func() {
    // 0x04 is uncompressed, not compressed
    let bad : [Nat8] = [
      0x04,0x79,0xbe,0x66,0x7e,0xf9,0xdc,0xbb,0xac,0x55,0xa0,0x62,
      0x95,0xce,0x87,0x0b,0x07,0x02,0x9b,0xfc,0xdb,0x2d,0xce,0x28,
      0xd9,0x59,0xf2,0x81,0x5b,0x16,0xf8,0x17,0x98,
    ];
    switch (EvmAddress.fromCompressedPublicKey(bad)) {
      case (#err(_)) {};
      case (#ok(_)) { assert(false) };
    };
  });

  // ── ecRecover ──

  test("ecRecover with Hardhat account #0 signature", func() {
    // Private key: ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
    // Compressed pubkey: 038318535b54105d4a7aae60c08fc45f9687181b4fdfc625bd1a753fa7397fed75
    // Address: 0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266
    // Message: 32 zero bytes
    // Signature (lowS, recovery=0):
    //   r: 00b8823364c90ea0d2700d5ad0fe39d16778bc07ce7df4779ff35e4b2660d043
    //   s: cb74a002439225d1d518f9f1cf3db005f5e143196543fd5146a34bf63f0b810a

    let msgHash : [Nat8] = [
      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
      0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00,
    ];
    let r : [Nat8] = [
      0x00,0xb8,0x82,0x33,0x64,0xc9,0x0e,0xa0,0xd2,0x70,0x0d,0x5a,0xd0,0xfe,0x39,0xd1,
      0x67,0x78,0xbc,0x07,0xce,0x7d,0xf4,0x77,0x9f,0xf3,0x5e,0x4b,0x26,0x60,0xd0,0x43,
    ];
    let s : [Nat8] = [
      0xcb,0x74,0xa0,0x02,0x43,0x92,0x25,0xd1,0xd5,0x18,0xf9,0xf1,0xcf,0x3d,0xb0,0x05,
      0xf5,0xe1,0x43,0x19,0x65,0x43,0xfd,0x51,0x46,0xa3,0x4b,0xf6,0x3f,0x0b,0x81,0x0a,
    ];

    let expectedPubkey : [Nat8] = [
      0x03,0x83,0x18,0x53,0x5b,0x54,0x10,0x5d,0x4a,0x7a,0xae,0x60,0xc0,0x8f,0xc4,0x5f,
      0x96,0x87,0x18,0x1b,0x4f,0xdf,0xc6,0x25,0xbd,0x1a,0x75,0x3f,0xa7,0x39,0x7f,0xed,0x75,
    ];

    // ecRecover test: sign with herumi, recover, verify address
    do {
      let ecdsaCurve = EcdsaCurve.Curve(#secp256k1);

      // Hardhat #0 private key
      let privKey : Nat = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

      // Derive public key using herumi: pubkey = privKey * G
      let pubJac = ecdsaCurve.mul_base(#fr(privKey));
      switch (ecdsaCurve.fromJacobi(pubJac)) {
        case (#affine(#fp(px), #fp(py))) {
          // Compress and derive address
          let prefix : Nat8 = if (py % 2 == 0) 0x02 else 0x03;
          let pubCompressed = Array.append<Nat8>([prefix], EvmUtils.natToBytes(px, 32));
          switch (EvmAddress.fromCompressedPublicKey(pubCompressed)) {
            case (#ok(addr)) {
              assert(addr == "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266");
            };
            case (#err(_)) { assert(false) };
          };
        };
        case (_) { assert(false) };
      };
    };

    // ecRecover test using herumi's own signing
    do {
      let ecdsaCurve = EcdsaCurve.Curve(#secp256k1);
      let privKey : Nat = 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80;

      // Sign using herumi
      let curve2 = EcdsaLib.secp256k1Curve();
      let sec = EcdsaLib.PrivateKey(privKey, curve2);
      let msg : [Nat8] = [0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0];
      // Use 32 random bytes for k derivation
      let rand : [Nat8] = [1,2,3,4,5,6,7,8,9,10,11,12,13,14,15,16,17,18,19,20,21,22,23,24,25,26,27,28,29,30,31,32];
      let #ok(sig) = sec.signHashed(msg.vals(), rand.vals()) else { assert(false); return };
      let sigR = EvmUtils.natToBytes(sig.r, 32);
      let sigS = EvmUtils.natToBytes(sig.s, 32);

      // Try recovering
      var found2 = false;
      for (vv in [0, 1].vals()) {
        switch (EvmAddress.ecRecover(msg, sigR, sigS, Nat8.fromNat(vv))) {
          case (?recovered) {
            switch (EvmAddress.fromCompressedPublicKey(recovered)) {
              case (#ok(addr)) {
                if (addr == "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266") {
                  found2 := true;
                };
              };
              case (#err(_)) {};
            };
          };
          case (null) {};
        };
      };
      assert(found2);
    };
  });
});
