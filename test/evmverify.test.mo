/// Motoko unit tests for EvmVerify helpers (hex parsing, log filtering).
import EvmVerify "../src/ic402/EvmVerify";
import { test; suite } "mo:test";

suite("EvmVerify", func() {

  // ── hexToAddress ──

  suite("hexToAddress", func() {

    test("extracts last 20 bytes from 32-byte zero-padded topic", func() {
      let padded = "0x000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7";
      assert(EvmVerify.hexToAddress(padded) == "0xdac17f958d2ee523a2206206994597c13d831ec7");
    });

    test("normalizes to lowercase", func() {
      let padded = "0x000000000000000000000000DAC17F958D2EE523A2206206994597C13D831EC7";
      assert(EvmVerify.hexToAddress(padded) == "0xdac17f958d2ee523a2206206994597c13d831ec7");
    });

    test("handles no 0x prefix", func() {
      let padded = "000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7";
      assert(EvmVerify.hexToAddress(padded) == "0xdac17f958d2ee523a2206206994597c13d831ec7");
    });

    test("returns empty for short input", func() {
      assert(EvmVerify.hexToAddress("0x1234") == "");
    });
  });

  // ── hexToNat ──

  suite("hexToNat", func() {

    test("parses 0x0 as 0", func() {
      assert(EvmVerify.hexToNat("0x0") == 0);
    });

    test("parses 0x1 as 1", func() {
      assert(EvmVerify.hexToNat("0x1") == 1);
    });

    test("parses 0xff as 255", func() {
      assert(EvmVerify.hexToNat("0xff") == 255);
    });

    test("parses 0xFF as 255 (uppercase)", func() {
      assert(EvmVerify.hexToNat("0xFF") == 255);
    });

    test("parses typical USDC amount (1 USDC = 1_000_000 = 0xF4240)", func() {
      assert(EvmVerify.hexToNat("0x00000000000000000000000000000000000000000000000000000000000f4240") == 1_000_000);
    });

    test("parses without 0x prefix", func() {
      assert(EvmVerify.hexToNat("ff") == 255);
    });
  });

  // ── toLower ──

  suite("toLower", func() {

    test("converts uppercase hex", func() {
      assert(EvmVerify.toLower("0xABCDEF") == "0xabcdef");
    });

    test("already lowercase passthrough", func() {
      assert(EvmVerify.toLower("0xabcdef") == "0xabcdef");
    });

    test("mixed case", func() {
      assert(EvmVerify.toLower("0xAbCdEf123") == "0xabcdef123");
    });
  });

  // ── findTransferLog ──

  suite("findTransferLog", func() {

    // keccak256("Transfer(address,address,uint256)")
    let transferSig = "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef";
    let usdcAddr = "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48";
    let recipient = "0xdac17f958d2ee523a2206206994597c13d831ec7";
    let recipientPadded = "0x000000000000000000000000dac17f958d2ee523a2206206994597c13d831ec7";
    let senderPadded = "0x0000000000000000000000001234567890abcdef1234567890abcdef12345678";
    // 1_000_000 = 0xF4240
    let amountData = "0x00000000000000000000000000000000000000000000000000000000000f4240";

    func makeLog(address : Text, topics : [Text], data : Text) : EvmVerify.LogEntry {
      {
        transactionHash = ?"0xabc";
        blockNumber = ?123;
        data;
        blockHash = ?"0xdef";
        transactionIndex = ?0;
        topics;
        address;
        logIndex = ?0;
        removed = false;
      };
    };

    test("matches correct contract, recipient, and amount", func() {
      let log = makeLog(usdcAddr, [transferSig, senderPadded, recipientPadded], amountData);
      switch (EvmVerify.findTransferLog([log], usdcAddr, recipient)) {
        case (?(addr, amt)) {
          assert(addr == recipient);
          assert(amt == 1_000_000);
        };
        case (null) { assert(false) };
      };
    });

    test("C-2: rejects log from wrong contract address", func() {
      let attackerContract = "0x1111111111111111111111111111111111111111";
      let log = makeLog(attackerContract, [transferSig, senderPadded, recipientPadded], amountData);
      assert(EvmVerify.findTransferLog([log], usdcAddr, recipient) == null);
    });

    test("C-2: matches when contract address differs only in case", func() {
      let log = makeLog("0xA0B86991C6218B36C1D19D4A2E9EB0CE3606EB48", [transferSig, senderPadded, recipientPadded], amountData);
      switch (EvmVerify.findTransferLog([log], usdcAddr, recipient)) {
        case (?(_, _)) {};
        case (null) { assert(false) };
      };
    });

    test("returns null when no logs", func() {
      assert(EvmVerify.findTransferLog([], usdcAddr, recipient) == null);
    });

    test("skips logs with fewer than 3 topics", func() {
      let log = makeLog(usdcAddr, [transferSig], amountData);
      assert(EvmVerify.findTransferLog([log], usdcAddr, recipient) == null);
    });

    test("skips non-Transfer events from correct contract", func() {
      let approvalTopic = "0x8c5be1e5ebec7d5bd14f71427d1e84f3dd0314c0f7b2291e5b200ac8c7c3b925";
      let log = makeLog(usdcAddr, [approvalTopic, senderPadded, recipientPadded], amountData);
      assert(EvmVerify.findTransferLog([log], usdcAddr, recipient) == null);
    });

    test("C-2: finds correct log among multiple (wrong contract first)", func() {
      let wrongLog = makeLog("0x1111111111111111111111111111111111111111", [transferSig, senderPadded, recipientPadded], amountData);
      let rightLog = makeLog(usdcAddr, [transferSig, senderPadded, recipientPadded], amountData);
      switch (EvmVerify.findTransferLog([wrongLog, rightLog], usdcAddr, recipient)) {
        case (?(addr, amt)) {
          assert(addr == recipient);
          assert(amt == 1_000_000);
        };
        case (null) { assert(false) };
      };
    });
  });
});
