/// Motoko unit tests for EvmUtils (RLP, ABI, EIP-1559, hex).
///
/// Includes EXTERNAL golden vectors (same discipline as test/sessions.test.mo and
/// test/selfauth.test.mo): the EIP-1559 serializer is pinned byte-for-byte against
/// viem@2.55.0 (independently re-derived with ethers v6.17.0), and the hex codec
/// against Node's Buffer hex reference — expectations come from OUTSIDE this
/// codebase, never from running the Motoko code itself.
import EvmUtils "../src/ic402/EvmUtils";
import EvmAddress "../src/ic402/EvmAddress";
import Array "mo:base/Array";
import Nat8 "mo:base/Nat8";
import { test; suite } "mo:test";

suite("EvmUtils", func() {

  // ═══════════════════════════════════════════════════════════════════════
  // Hex Utilities
  // ═══════════════════════════════════════════════════════════════════════

  suite("bytesToHex", func() {
    test("empty -> 0x", func() {
      assert(EvmUtils.bytesToHex([]) == "0x");
    });
    test("[0xde, 0xad] -> 0xdead", func() {
      assert(EvmUtils.bytesToHex([0xde, 0xad]) == "0xdead");
    });
    test("[0x00] -> 0x00", func() {
      assert(EvmUtils.bytesToHex([0x00]) == "0x00");
    });
  });

  suite("hexToBytes", func() {
    test("0xdead -> [0xde, 0xad]", func() {
      assert(EvmUtils.hexToBytes("0xdead") == [0xde : Nat8, 0xad]);
    });
    test("dead (no prefix) -> [0xde, 0xad]", func() {
      assert(EvmUtils.hexToBytes("dead") == [0xde : Nat8, 0xad]);
    });
    test("odd length -> empty", func() {
      assert(EvmUtils.hexToBytes("0xabc") == []);
    });
    test("empty -> empty", func() {
      assert(EvmUtils.hexToBytes("0x") == []);
    });
    test("roundtrip", func() {
      let orig : [Nat8] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef];
      assert(EvmUtils.hexToBytes(EvmUtils.bytesToHex(orig)) == orig);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // Byte <-> Nat Conversion
  // ═══════════════════════════════════════════════════════════════════════

  suite("natToMinBytes", func() {
    test("0 -> empty", func() {
      assert(EvmUtils.natToMinBytes(0) == []);
    });
    test("1 -> [0x01]", func() {
      assert(EvmUtils.natToMinBytes(1) == [0x01 : Nat8]);
    });
    test("127 -> [0x7f]", func() {
      assert(EvmUtils.natToMinBytes(127) == [0x7f : Nat8]);
    });
    test("128 -> [0x80]", func() {
      assert(EvmUtils.natToMinBytes(128) == [0x80 : Nat8]);
    });
    test("1024 -> [0x04, 0x00]", func() {
      assert(EvmUtils.natToMinBytes(1024) == [0x04 : Nat8, 0x00]);
    });
  });

  suite("natToBytes", func() {
    test("0 in 32 bytes -> 32 zeros", func() {
      let bytes = EvmUtils.natToBytes(0, 32);
      assert(bytes.size() == 32);
      for (b in bytes.vals()) { assert(b == 0) };
    });
    test("1 in 32 bytes -> 31 zeros + 0x01", func() {
      let bytes = EvmUtils.natToBytes(1, 32);
      assert(bytes[31] == 1);
      assert(bytes[30] == 0);
    });
  });

  suite("bytesToNat", func() {
    test("empty -> 0", func() {
      assert(EvmUtils.bytesToNat([]) == 0);
    });
    test("[0x01] -> 1", func() {
      assert(EvmUtils.bytesToNat([0x01]) == 1);
    });
    test("[0x04, 0x00] -> 1024", func() {
      assert(EvmUtils.bytesToNat([0x04, 0x00]) == 1024);
    });
    test("roundtrip", func() {
      assert(EvmUtils.bytesToNat(EvmUtils.natToMinBytes(123456789)) == 123456789);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // RLP Encoding (Ethereum Yellow Paper Appendix B test vectors)
  // ═══════════════════════════════════════════════════════════════════════

  suite("rlpEncodeBytes", func() {
    test("empty bytes -> [0x80]", func() {
      assert(EvmUtils.rlpEncodeBytes([]) == [0x80 : Nat8]);
    });
    test("single byte 0x00 -> [0x00]", func() {
      assert(EvmUtils.rlpEncodeBytes([0x00]) == [0x00 : Nat8]);
    });
    test("single byte 0x7f -> [0x7f]", func() {
      assert(EvmUtils.rlpEncodeBytes([0x7f]) == [0x7f : Nat8]);
    });
    test("single byte 0x80 -> [0x81, 0x80]", func() {
      assert(EvmUtils.rlpEncodeBytes([0x80]) == [0x81 : Nat8, 0x80]);
    });
    // "dog" = [0x64, 0x6f, 0x67]
    test("'dog' -> [0x83, 0x64, 0x6f, 0x67]", func() {
      assert(EvmUtils.rlpEncodeBytes([0x64, 0x6f, 0x67]) == [0x83 : Nat8, 0x64, 0x6f, 0x67]);
    });
  });

  suite("rlpEncodeNat", func() {
    test("0 -> [0x80] (empty string encoding)", func() {
      assert(EvmUtils.rlpEncodeNat(0) == [0x80 : Nat8]);
    });
    test("1 -> [0x01]", func() {
      assert(EvmUtils.rlpEncodeNat(1) == [0x01 : Nat8]);
    });
    test("15 -> [0x0f]", func() {
      assert(EvmUtils.rlpEncodeNat(15) == [0x0f : Nat8]);
    });
    test("127 -> [0x7f]", func() {
      assert(EvmUtils.rlpEncodeNat(127) == [0x7f : Nat8]);
    });
    test("128 -> [0x81, 0x80]", func() {
      assert(EvmUtils.rlpEncodeNat(128) == [0x81 : Nat8, 0x80]);
    });
    test("1024 -> [0x82, 0x04, 0x00]", func() {
      assert(EvmUtils.rlpEncodeNat(1024) == [0x82 : Nat8, 0x04, 0x00]);
    });
  });

  suite("rlpEncodeList", func() {
    test("empty list -> [0xc0]", func() {
      assert(EvmUtils.rlpEncodeList([]) == [0xc0 : Nat8]);
    });
    // ["cat", "dog"] where cat=[0x63,0x61,0x74], dog=[0x64,0x6f,0x67]
    // rlp(cat) = [0x83, 0x63, 0x61, 0x74] (4 bytes)
    // rlp(dog) = [0x83, 0x64, 0x6f, 0x67] (4 bytes)
    // total payload = 8 bytes -> 0xc8 prefix
    test("[cat, dog] -> 0xc88363617483646f67", func() {
      let cat = EvmUtils.rlpEncodeBytes([0x63, 0x61, 0x74]);
      let dog = EvmUtils.rlpEncodeBytes([0x64, 0x6f, 0x67]);
      let result = EvmUtils.rlpEncodeList([cat, dog]);
      assert(result == [0xc8 : Nat8, 0x83, 0x63, 0x61, 0x74, 0x83, 0x64, 0x6f, 0x67]);
    });
    // Nested: set theoretical representation of 3 = [ [], [[]], [[], [[]]] ]
    test("nested lists: [ [], [[]], [[], [[]]] ]", func() {
      let empty = EvmUtils.rlpEncodeList([]);             // 0xc0
      let nested1 = EvmUtils.rlpEncodeList([empty]);      // 0xc1, 0xc0
      let nested2 = EvmUtils.rlpEncodeList([empty, nested1]); // 0xc3, 0xc0, 0xc1, 0xc0
      let result = EvmUtils.rlpEncodeList([empty, nested1, nested2]);
      // Expected: 0xc7 0xc0 0xc1c0 0xc3c0c1c0
      assert(result == [0xc7 : Nat8, 0xc0, 0xc1, 0xc0, 0xc3, 0xc0, 0xc1, 0xc0]);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // ABI Encoding
  // ═══════════════════════════════════════════════════════════════════════

  suite("abiEncodeUint256", func() {
    test("0 -> 32 zero bytes", func() {
      let result = EvmUtils.abiEncodeUint256(0);
      assert(result.size() == 32);
      for (b in result.vals()) { assert(b == 0) };
    });
    test("1 -> 31 zeros + 0x01", func() {
      let result = EvmUtils.abiEncodeUint256(1);
      assert(result.size() == 32);
      assert(result[31] == 1);
      assert(result[0] == 0);
    });
  });

  suite("abiEncodeBool", func() {
    test("true -> uint256(1)", func() {
      let result = EvmUtils.abiEncodeBool(true);
      assert(result.size() == 32);
      assert(result[31] == 1);
    });
    test("false -> uint256(0)", func() {
      let result = EvmUtils.abiEncodeBool(false);
      assert(result.size() == 32);
      assert(result[31] == 0);
    });
  });

  suite("abiEncodeString", func() {
    test("empty string", func() {
      let result = EvmUtils.abiEncodeString("");
      // [uint256(0)] [32 bytes of padding] -- wait, empty string has 0 bytes, padded to 32
      assert(result.size() == 64); // 32 (length=0) + 32 (padding to boundary)
      assert(result[31] == 0); // length = 0
    });
    test("'Test' -> length 4 + padded data", func() {
      let result = EvmUtils.abiEncodeString("Test");
      assert(result.size() == 64); // 32 (length) + 32 (4 bytes padded to 32)
      assert(result[31] == 4); // length = 4
      assert(result[32] == 0x54); // 'T'
      assert(result[33] == 0x65); // 'e'
      assert(result[34] == 0x73); // 's'
      assert(result[35] == 0x74); // 't'
      assert(result[36] == 0);    // padding
    });
  });

  suite("functionSelector", func() {
    test("transfer(address,uint256) -> 0xa9059cbb", func() {
      let sel = EvmUtils.functionSelector("transfer(address,uint256)");
      assert(sel.size() == 4);
      assert(sel[0] == 0xa9);
      assert(sel[1] == 0x05);
      assert(sel[2] == 0x9c);
      assert(sel[3] == 0xbb);
    });
    test("register(string,string,string,string[],string[],bool) -> 0x8c8662c7", func() {
      let sel = EvmUtils.functionSelector("register(string,string,string,string[],string[],bool)");
      assert(sel.size() == 4);
      assert(sel[0] == 0x8c);
      assert(sel[1] == 0x86);
      assert(sel[2] == 0x62);
      assert(sel[3] == 0xc7);
    });
  });

  // Full register() calldata test against cast output
  suite("abiEncodeFunctionCall", func() {
    test("register('Test','A test agent','https://example.com',['search'],['knowledge'],true) matches cast", func() {
      let selector = EvmUtils.functionSelector("register(string,string,string,string[],string[],bool)");
      let calldata = EvmUtils.abiEncodeFunctionCall(
        selector,
        [
          #dynamic(EvmUtils.abiEncodeString("Test")),
          #dynamic(EvmUtils.abiEncodeString("A test agent")),
          #dynamic(EvmUtils.abiEncodeString("https://example.com")),
          #dynamic(EvmUtils.abiEncodeStringArray(["search"])),
          #dynamic(EvmUtils.abiEncodeStringArray(["knowledge"])),
          #static_(EvmUtils.abiEncodeBool(true)),
        ],
      );

      // Verify against `cast abi-encode` output (with selector prepended)
      let expected = EvmUtils.hexToBytes(
        "8c8662c7" #
        "00000000000000000000000000000000000000000000000000000000000000c0" # // offset to "Test"
        "0000000000000000000000000000000000000000000000000000000000000100" # // offset to "A test agent"
        "0000000000000000000000000000000000000000000000000000000000000140" # // offset to endpoint
        "0000000000000000000000000000000000000000000000000000000000000180" # // offset to skills
        "0000000000000000000000000000000000000000000000000000000000000200" # // offset to domains
        "0000000000000000000000000000000000000000000000000000000000000001" # // true
        "0000000000000000000000000000000000000000000000000000000000000004" # // len("Test")
        "5465737400000000000000000000000000000000000000000000000000000000" # // "Test" padded
        "000000000000000000000000000000000000000000000000000000000000000c" # // len("A test agent")
        "412074657374206167656e740000000000000000000000000000000000000000" # // padded
        "0000000000000000000000000000000000000000000000000000000000000013" # // len(endpoint)
        "68747470733a2f2f6578616d706c652e636f6d00000000000000000000000000" # // padded
        "0000000000000000000000000000000000000000000000000000000000000001" # // skills count
        "0000000000000000000000000000000000000000000000000000000000000020" # // offset to skills[0]
        "0000000000000000000000000000000000000000000000000000000000000006" # // len("search")
        "7365617263680000000000000000000000000000000000000000000000000000" # // padded
        "0000000000000000000000000000000000000000000000000000000000000001" # // domains count
        "0000000000000000000000000000000000000000000000000000000000000020" # // offset to domains[0]
        "0000000000000000000000000000000000000000000000000000000000000009" # // len("knowledge")
        "6b6e6f776c656467650000000000000000000000000000000000000000000000"   // padded
      );

      assert(calldata.size() == expected.size());
      assert(calldata == expected);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // EIP-1559 Transaction
  // ═══════════════════════════════════════════════════════════════════════

  suite("EIP-1559", func() {
    test("unsignedTxHash produces 32-byte hash", func() {
      let params : EvmUtils.TxParams = {
        chainId = 84532;
        nonce = 0;
        maxPriorityFeePerGas = 1_500_000_000;
        maxFeePerGas = 3_000_000_000;
        gasLimit = 500_000;
        to = EvmUtils.addressToBytes("0x0F3998E6E4287fa7a5620979c5513D8e83fE80D3");
        value = 0;
        data = [];
      };
      let hash = EvmUtils.unsignedTxHash(params);
      assert(hash.size() == 32);
    });

    test("signedRawTx starts with 0x02", func() {
      let params : EvmUtils.TxParams = {
        chainId = 84532;
        nonce = 0;
        maxPriorityFeePerGas = 1_500_000_000;
        maxFeePerGas = 3_000_000_000;
        gasLimit = 500_000;
        to = EvmUtils.addressToBytes("0x0F3998E6E4287fa7a5620979c5513D8e83fE80D3");
        value = 0;
        data = [];
      };
      let r = EvmUtils.natToBytes(1, 32);
      let s = EvmUtils.natToBytes(2, 32);
      let raw = EvmUtils.signedRawTx(params, r, s, 0);
      assert(raw[0] == 0x02); // EIP-1559 type byte
    });

    test("unsigned tx is deterministic", func() {
      let params : EvmUtils.TxParams = {
        chainId = 1;
        nonce = 42;
        maxPriorityFeePerGas = 2_000_000_000;
        maxFeePerGas = 50_000_000_000;
        gasLimit = 21000;
        to = EvmUtils.hexToBytes("d8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
        value = 1_000_000_000_000_000_000; // 1 ETH
        data = [];
      };
      let h1 = EvmUtils.unsignedTxHash(params);
      let h2 = EvmUtils.unsignedTxHash(params);
      assert(h1 == h2);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // EIP-1559 golden vectors (viem, cross-verified by ethers)
  // ═══════════════════════════════════════════════════════════════════════
  //
  // WHAT: byte-for-byte pins of unsignedTxHash (the EIP-1559 signing hash) and
  // signedRawTx (the broadcastable raw tx), plus keccak256(raw tx) == canonical
  // tx hash, against reference serializations produced OUTSIDE this codebase.
  // PROVENANCE: viem@2.55.0 (node v26.5.0) serializeTransaction + keccak256;
  // signatures from viem sign() (RFC-6979 deterministic, low-S) under private key
  // 0x0707…07 (signer 0x4a62316623ad457F02cDC5D997deD67a383EC569); deterministic
  // across generator runs and round-tripped through viem parseTransaction.
  // Independently re-derived byte-for-byte with ethers v6.17.0 (zero viem):
  // Transaction.from(raw) restores every field and re-serializes identically.
  suite("EIP-1559 golden vectors (viem, cross-verified by ethers)", func() {

    // Shared by the RLP-edge fixture and the leading-zero r/s regression below.
    // Stresses zero integers -> empty RLP item 0x80 (nonce, tip, value, empty data),
    // single byte < 0x80 encoded as itself (maxFeePerGas=1 -> 0x01), and a 20-byte
    // `to` with 19 leading zero bytes kept verbatim (byte STRING, never integer-trimmed).
    let edgeParams : EvmUtils.TxParams = {
      chainId = 1;
      nonce = 0;
      maxPriorityFeePerGas = 0;
      maxFeePerGas = 1;
      gasLimit = 21_000;
      to = EvmUtils.addressToBytes("0x0000000000000000000000000000000000000001");
      value = 0;
      data = [];
    };

    test("typical Base-Sepolia ERC-20 transfer: signing hash, raw tx, tx hash", func() {
      // chainId 84532 (Base Sepolia), to = Base Sepolia USDC, calldata =
      // transfer(0x1111…11, 1000000). Stresses multi-byte fee integers, 68-byte
      // calldata (RLP long string 0xb844), empty accessList (0xc0), yParity=0 (0x80).
      let params : EvmUtils.TxParams = {
        chainId = 84532;
        nonce = 7;
        maxPriorityFeePerGas = 1_500_000_000;
        maxFeePerGas = 30_000_000_000;
        gasLimit = 100_000;
        to = EvmUtils.addressToBytes("0x036CbD53842c5426634e7929541eC2318f3dCF7e");
        value = 0;
        data = EvmUtils.hexToBytes("0xa9059cbb000000000000000000000000111111111111111111111111111111111111111100000000000000000000000000000000000000000000000000000000000f4240");
      };
      assert(params.data.size() == 68);

      // (a) signing hash = keccak256(0x02 || rlp([chainId..accessList]))
      let signingHash = EvmUtils.hexToBytes("0x59d3274d47d1e7eb67c4bcef66635e1d8c24091e59ad22d7068b5a5af2185ed0");
      assert(signingHash.size() == 32);
      assert(EvmUtils.unsignedTxHash(params) == signingHash);

      // (b) signed raw tx with viem's signature over that hash (yParity = 0)
      let r = EvmUtils.hexToBytes("0x53d38779910a1e723eef33a92117247beab106287efe13fc9f74013a359f00dc");
      let s = EvmUtils.hexToBytes("0x4a408a12c79a8a4328553be6a0c4fbfe14fc408257edf437b16f6cd6224f33db");
      assert(r.size() == 32 and s.size() == 32);
      let raw = EvmUtils.signedRawTx(params, r, s, 0);
      let expectedRaw = EvmUtils.hexToBytes("0x02f8b483014a34078459682f008506fc23ac00830186a094036cbd53842c5426634e7929541ec2318f3dcf7e80b844a9059cbb000000000000000000000000111111111111111111111111111111111111111100000000000000000000000000000000000000000000000000000000000f4240c080a053d38779910a1e723eef33a92117247beab106287efe13fc9f74013a359f00dca04a408a12c79a8a4328553be6a0c4fbfe14fc408257edf437b16f6cd6224f33db");
      assert(expectedRaw.size() == 183);
      assert(raw == expectedRaw);

      // (c) canonical tx hash = keccak256(signed raw tx)
      assert(EvmAddress.keccak256(raw) == EvmUtils.hexToBytes("0x783b5fde5385fc9843779d0726753e34853ae15719dde886ad1e941589140ff2"));
    });

    test("RLP edge cases (chainId 1, nonce 0, zero fees): signing hash, raw tx, tx hash", func() {
      // (a) signing hash
      let signingHash = EvmUtils.hexToBytes("0xfbd968a856266aedf1ebff95f1bb5a0d1038a5d78147a049b15216c2ac25ad4a");
      assert(signingHash.size() == 32);
      assert(EvmUtils.unsignedTxHash(edgeParams) == signingHash);

      // (b) signed raw tx (yParity = 1 -> RLP item 0x01)
      let r = EvmUtils.hexToBytes("0x852308706546ccef582053e4c1ab227f89feabc64c1bfac4b841851fb4f6cc1f");
      let s = EvmUtils.hexToBytes("0x0f3672fe4d8c35cca79af193fd799805768a90569c21db54c2de210d2dfea333");
      assert(r.size() == 32 and s.size() == 32);
      let raw = EvmUtils.signedRawTx(edgeParams, r, s, 1);
      let expectedRaw = EvmUtils.hexToBytes("0x02f862018080018252089400000000000000000000000000000000000000018080c001a0852308706546ccef582053e4c1ab227f89feabc64c1bfac4b841851fb4f6cc1fa00f3672fe4d8c35cca79af193fd799805768a90569c21db54c2de210d2dfea333");
      assert(expectedRaw.size() == 101);
      assert(raw == expectedRaw);

      // (c) canonical tx hash
      assert(EvmAddress.keccak256(raw) == EvmUtils.hexToBytes("0x1c128d44be88a7b97a6a5c57f86f82597c684505216aba85a1bc25cee75a553b"));
    });

    // REGRESSION for the r/s RLP-integer fix: EIP-2718/1559 define signature_r and
    // signature_s as RLP INTEGERS (minimal big-endian, leading zeros trimmed). The
    // pre-fix encoder emitted the fixed 32-byte tECDSA slices as RLP byte strings
    // (0xa0 + 32 bytes, zeros kept), which geth-family nodes reject on decode as
    // "rlp: non-canonical integer" — an intermittent ~1-in-128 broadcast failure.
    test("REGRESSION: r/s with leading zero bytes serialize as minimal RLP integers (viem golden)", func() {
      // Same tx as the edge-case fixture; SYNTHETIC (non-curve-valid) signature purely
      // to pin encoder behavior: r has ONE leading zero byte, s has TWO. Expected bytes
      // re-derived with viem@2.55.0 serializeTransaction under an explicit signature
      // override (rederive-leading-zero-rs.mjs, matching probe-leading-zero-rs.mjs):
      // viem emits r as 0x9f + 31 bytes and s as 0x9e + 30 bytes, and parseTransaction
      // round-trips both back to the zero-padded 32-byte values.
      let r = EvmUtils.hexToBytes("0x00aa5308706546ccef582053e4c1ab227f89feabc64c1bfac4b841851fb4f6cc");
      let s = EvmUtils.hexToBytes("0x0000f3672fe4d8c35cca79af193fd799805768a90569c21db54c2de210d2dfea");
      assert(r.size() == 32 and s.size() == 32);
      assert(r[0] == 0x00 and s[0] == 0x00 and s[1] == 0x00);
      let raw = EvmUtils.signedRawTx(edgeParams, r, s, 0);
      let expectedRaw = EvmUtils.hexToBytes("0x02f85f018080018252089400000000000000000000000000000000000000018080c0809faa5308706546ccef582053e4c1ab227f89feabc64c1bfac4b841851fb4f6cc9ef3672fe4d8c35cca79af193fd799805768a90569c21db54c2de210d2dfea");
      assert(expectedRaw.size() == 98);
      assert(raw == expectedRaw);
    });
  });

  // ═══════════════════════════════════════════════════════════════════════
  // Hex codec golden vectors (cross-checked against Node's Buffer hex codec)
  // ═══════════════════════════════════════════════════════════════════════
  //
  // WHAT: pins bytesToHex/hexToBytes against a vector table cross-checked with
  // Node v26.5.0 Buffer.from(x, 'hex') / Buffer.toString('hex').
  // DELIBERATE DEVIATION: on odd length or ANY invalid character, ic402 rejects
  // the WHOLE input and returns [] — fail-closed on the payment path — where Node
  // silently partial-decodes ("abc" -> 0xab, "abZZcd" -> 0xab). The divergence
  // cases below pin ic402's reject, not the Node value.
  suite("hex codec golden vectors (Node cross-checked; whole-input reject on bad input)", func() {

    test("encode: always lowercase, always 0x-prefixed, empty -> 0x", func() {
      assert(EvmUtils.bytesToHex([]) == "0x");
      assert(EvmUtils.bytesToHex([0x00]) == "0x00");
      assert(EvmUtils.bytesToHex([0x0a, 0xff, 0x10]) == "0x0aff10");
      assert(EvmUtils.bytesToHex([0xde, 0xad, 0xbe, 0xef]) == "0xdeadbeef");
      let addr20 = Array.tabulate<Nat8>(20, func(i : Nat) : Nat8 { Nat8.fromNat(i + 1) });
      assert(EvmUtils.bytesToHex(addr20) == "0x0102030405060708090a0b0c0d0e0f1011121314");
    });

    test("decode: canonical, 0x prefix, 0X prefix, mixed case all agree with Node", func() {
      let expected : [Nat8] = [0xde, 0xad, 0xbe, 0xef];
      assert(EvmUtils.hexToBytes("deadbeef") == expected);
      assert(EvmUtils.hexToBytes("0xdeadbeef") == expected);
      assert(EvmUtils.hexToBytes("0XDEADBEEF") == expected);
      assert(EvmUtils.hexToBytes("DeAdBeEf") == expected);
    });

    test("decode: odd length rejects the whole input (Node keeps 0xab)", func() {
      assert(EvmUtils.hexToBytes("abc") == []);
      assert(EvmUtils.hexToBytes("0xabc") == []);
      assert(EvmUtils.hexToBytes("ab!cd") == []); // odd AND invalid char
    });

    test("decode: invalid char rejects the whole input (Node stops at 'Z', keeps 0xab)", func() {
      assert(EvmUtils.hexToBytes("abZZcd") == []);
    });

    test("decode: empty and bare prefix -> [] (agrees with Node)", func() {
      assert(EvmUtils.hexToBytes("") == []);
      assert(EvmUtils.hexToBytes("0x") == []);
    });

    test("round-trip: hexToBytes(bytesToHex(x)) == x", func() {
      let vectors : [[Nat8]] = [
        [],
        [0x00],
        [0x00, 0x01],
        [0x7f, 0x80, 0xff],
        Array.tabulate<Nat8>(20, func(i : Nat) : Nat8 { Nat8.fromNat(i + 1) }),
        Array.tabulate<Nat8>(32, func(_ : Nat) : Nat8 { 0xff }),
      ];
      for (v in vectors.vals()) {
        assert(EvmUtils.hexToBytes(EvmUtils.bytesToHex(v)) == v);
      };
    });
  });
});
