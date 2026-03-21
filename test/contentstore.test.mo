/// Motoko unit tests for ContentStore (encrypted in-canister blob storage).
import ContentStore "../src/ic402/ContentStore";
import Types "../src/ic402/Types";
import Principal "mo:base/Principal";
import Blob "mo:base/Blob";
import Text "mo:base/Text";
import { test; suite } "mo:test";

suite("ContentStore", func() {

  let testPrincipal = Principal.fromText("aaaaa-aa");

  test("put and get small blob", func() {
    let store = ContentStore.ContentStore(testPrincipal);
    let data = Text.encodeUtf8("Hello, World!");

    switch (store.put("doc-001", "text/plain", data)) {
      case (#ok) {};
      case (_) { assert(false) };
    };

    switch (store.get("doc-001")) {
      case (?retrieved) { assert(retrieved == data) };
      case (null) { assert(false) };
    };
  });

  test("put rejects duplicate ID", func() {
    let store = ContentStore.ContentStore(testPrincipal);
    ignore store.put("doc-001", "text/plain", Text.encodeUtf8("first"));

    switch (store.put("doc-001", "text/plain", Text.encodeUtf8("second"))) {
      case (#contentAlreadyExists) {};
      case (_) { assert(false) };
    };
  });

  test("get unknown ID returns null", func() {
    let store = ContentStore.ContentStore(testPrincipal);
    assert(store.get("nonexistent") == null);
  });

  test("delete and verify", func() {
    let store = ContentStore.ContentStore(testPrincipal);
    ignore store.put("doc-001", "text/plain", Text.encodeUtf8("data"));

    switch (store.delete("doc-001")) {
      case (#ok) {};
      case (_) { assert(false) };
    };

    assert(store.get("doc-001") == null);
  });

  test("delete nonexistent returns contentNotFound", func() {
    let store = ContentStore.ContentStore(testPrincipal);

    switch (store.delete("nonexistent")) {
      case (#contentNotFound) {};
      case (_) { assert(false) };
    };
  });

  test("getMetadata returns correct entry", func() {
    let store = ContentStore.ContentStore(testPrincipal);
    let data = Text.encodeUtf8("test content");
    ignore store.put("doc-001", "text/plain", data);

    switch (store.getMetadata("doc-001")) {
      case (?meta) {
        assert(meta.id == "doc-001");
        assert(meta.mimeType == "text/plain");
        assert(meta.totalSize == data.size());
        assert(meta.chunkCount == 1);
      };
      case (null) { assert(false) };
    };
  });

  test("list returns all entries", func() {
    let store = ContentStore.ContentStore(testPrincipal);
    ignore store.put("a", "text/plain", Text.encodeUtf8("aaa"));
    ignore store.put("b", "text/plain", Text.encodeUtf8("bbb"));

    let items = store.list();
    assert(items.size() == 2);
  });

  test("toContentRef bridges to Gateway", func() {
    let store = ContentStore.ContentStore(testPrincipal);
    ignore store.put("photo-001", "image/jpeg", Text.encodeUtf8("jpeg data"));

    switch (store.toContentRef("photo-001")) {
      case (?ref) {
        assert(ref.id == "photo-001");
        assert(ref.mimeType == ?"image/jpeg");
        assert(ref.sizeBytes == ?9); // "jpeg data" is 9 bytes
      };
      case (null) { assert(false) };
    };

    assert(store.toContentRef("nonexistent") == null);
  });

  test("getChunk and out-of-range", func() {
    let store = ContentStore.ContentStore(testPrincipal);
    let data = Text.encodeUtf8("chunk test");
    ignore store.put("doc-001", "text/plain", data);

    // Chunk 0 should exist and match the original data
    switch (store.getChunk("doc-001", 0)) {
      case (?chunk) { assert(chunk == data) };
      case (null) { assert(false) };
    };

    // Chunk 1 should not exist (small data = 1 chunk)
    assert(store.getChunk("doc-001", 1) == null);

    // Unknown content
    assert(store.getChunk("nonexistent", 0) == null);
  });

  test("chunked upload: init + putChunk + get", func() {
    let store = ContentStore.ContentStore(testPrincipal);
    let part1 = Text.encodeUtf8("Hello, ");
    let part2 = Text.encodeUtf8("World!");

    switch (store.putChunkedInit("chunked-001", "text/plain", 13, 2)) {
      case (#ok) {};
      case (_) { assert(false) };
    };

    switch (store.putChunk("chunked-001", 0, part1)) {
      case (#ok) {};
      case (_) { assert(false) };
    };

    switch (store.putChunk("chunked-001", 1, part2)) {
      case (#ok) {};
      case (_) { assert(false) };
    };

    // get() should reassemble and return full content
    switch (store.get("chunked-001")) {
      case (?full) {
        assert(full == Text.encodeUtf8("Hello, World!"));
      };
      case (null) { assert(false) };
    };

    // getChunk should return individual chunks
    switch (store.getChunk("chunked-001", 0)) {
      case (?c) { assert(c == part1) };
      case (null) { assert(false) };
    };

    switch (store.getChunk("chunked-001", 1)) {
      case (?c) { assert(c == part2) };
      case (null) { assert(false) };
    };
  });

  test("stable state roundtrip", func() {
    let store1 = ContentStore.ContentStore(testPrincipal);
    ignore store1.put("doc-001", "text/plain", Text.encodeUtf8("stable data"));
    ignore store1.put("doc-002", "image/png", Text.encodeUtf8("png bytes"));

    let snapshot = store1.toStable();

    let store2 = ContentStore.ContentStore(testPrincipal);
    store2.loadStable(snapshot);

    // Verify data survived roundtrip
    switch (store2.get("doc-001")) {
      case (?data) { assert(data == Text.encodeUtf8("stable data")) };
      case (null) { assert(false) };
    };

    switch (store2.get("doc-002")) {
      case (?data) { assert(data == Text.encodeUtf8("png bytes")) };
      case (null) { assert(false) };
    };

    assert(store2.list().size() == 2);
  });

  test("empty blob edge case", func() {
    let store = ContentStore.ContentStore(testPrincipal);
    let empty = Blob.fromArray([]);

    switch (store.put("empty", "application/octet-stream", empty)) {
      case (#ok) {};
      case (_) { assert(false) };
    };

    switch (store.get("empty")) {
      case (?data) { assert(data.size() == 0) };
      case (null) { assert(false) };
    };

    switch (store.getMetadata("empty")) {
      case (?meta) {
        assert(meta.totalSize == 0);
        assert(meta.chunkCount == 1);
      };
      case (null) { assert(false) };
    };
  });
});
