/// Motoko unit tests for EvmUtils (RLP, ABI, EIP-1559, hex).
import EvmUtils "../src/ic402/EvmUtils";
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
});
