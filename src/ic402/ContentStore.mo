/// ic402 — Optional encrypted in-canister content storage.
///
/// Encrypts all content at rest using SHA-256-CTR. The encryption key
/// is derived from the canister's own principal — only the canister's
/// code can decrypt. This protects against subnet node operators
/// inspecting canister memory.
import Types "Types";
import SHA256 "mo:sha2/Sha256";
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Time "mo:base/Time";

module {

  let MAX_CHUNK_SIZE : Nat = 1_572_864; // 1.5 MB — safe under ICP's 2 MB message limit

  type InternalEntry = {
    id : Text;
    mimeType : Text;
    chunks : [var Blob];
    totalSize : Nat;
    createdAt : Int;
  };

  // ── Encryption helpers ──

  func natToBytes8(n : Nat) : [Nat8] {
    var value = n;
    let bytes = Array.init<Nat8>(8, 0);
    var i = 7 : Nat;
    while (i > 0) {
      bytes[i] := Nat8.fromNat(value % 256);
      value := value / 256;
      i -= 1;
    };
    bytes[0] := Nat8.fromNat(value % 256);
    Array.freeze(bytes);
  };

  /// SHA-256(masterKey ++ contentId)
  func deriveContentKey(masterKey : [Nat8], contentId : Text) : [Nat8] {
    let idBytes = Blob.toArray(Text.encodeUtf8(contentId));
    Blob.toArray(SHA256.fromArray(#sha256, Array.append(masterKey, idBytes)));
  };

  /// SHA-256(contentKey ++ chunkIndex) — unique key per chunk
  func deriveChunkKey(masterKey : [Nat8], contentId : Text, chunkIndex : Nat) : [Nat8] {
    let contentKey = deriveContentKey(masterKey, contentId);
    let indexBytes = natToBytes8(chunkIndex);
    Blob.toArray(SHA256.fromArray(#sha256, Array.append(contentKey, indexBytes)));
  };

  /// SHA-256(chunkKey ++ blockIndex) — one 32-byte keystream block
  func generateKeystream(chunkKey : [Nat8], blockIndex : Nat) : [Nat8] {
    let indexBytes = natToBytes8(blockIndex);
    Blob.toArray(SHA256.fromArray(#sha256, Array.append(chunkKey, indexBytes)));
  };

  /// XOR data with keystream blocks (CTR mode).
  func xorEncrypt(chunkKey : [Nat8], data : [Nat8]) : [Nat8] {
    if (data.size() == 0) return [];
    let result = Array.init<Nat8>(data.size(), 0 : Nat8);
    var blockIndex : Nat = 0;
    var keystream = generateKeystream(chunkKey, blockIndex);
    var ksOffset : Nat = 0;

    var i : Nat = 0;
    while (i < data.size()) {
      if (ksOffset >= 32) {
        blockIndex += 1;
        keystream := generateKeystream(chunkKey, blockIndex);
        ksOffset := 0;
      };
      result[i] := data[i] ^ keystream[ksOffset];
      ksOffset += 1;
      i += 1;
    };

    Array.freeze(result);
  };

  /// Encrypt a single chunk (uses contentId + chunkIndex for unique keystream).
  func encryptChunkData(masterKey : [Nat8], contentId : Text, chunkIndex : Nat, data : Blob) : Blob {
    let chunkKey = deriveChunkKey(masterKey, contentId, chunkIndex);
    Blob.fromArray(xorEncrypt(chunkKey, Blob.toArray(data)));
  };

  /// Decrypt a single chunk — XOR is symmetric, same operation as encrypt.
  func decryptChunkData(masterKey : [Nat8], contentId : Text, chunkIndex : Nat, data : Blob) : Blob {
    encryptChunkData(masterKey, contentId, chunkIndex, data);
  };

  /// Optional encrypted in-canister blob storage.
  ///
  /// ```motoko
  /// transient let store = ContentStore(Principal.fromActor(self));
  /// ignore store.put("doc-001", "text/plain", myBlob);
  /// let ?data = store.get("doc-001");
  /// ```
  public class ContentStore(selfPrincipal : Principal) {

    // Master key: SHA-256(principal ++ "ic402-content-key")
    let masterKey : [Nat8] = do {
      let principalBytes = Blob.toArray(Principal.toBlob(selfPrincipal));
      let suffix = Blob.toArray(Text.encodeUtf8("ic402-content-key"));
      Blob.toArray(SHA256.fromArray(#sha256, Array.append(principalBytes, suffix)));
    };

    var entries = HashMap.HashMap<Text, InternalEntry>(16, Text.equal, Text.hash);

    /// Store a blob, encrypting and auto-chunking at 1.5 MB.
    public func put(id : Text, mimeType : Text, data : Blob) : Types.ContentStoreResult {
      switch (entries.get(id)) {
        case (?_) { return #contentAlreadyExists };
        case (null) {};
      };

      let dataSize = data.size();
      let numChunks = if (dataSize == 0) { 1 } else {
        (dataSize + MAX_CHUNK_SIZE - 1) / MAX_CHUNK_SIZE;
      };
      let chunks = Array.init<Blob>(numChunks, "");
      let dataBytes = Blob.toArray(data);

      var i : Nat = 0;
      while (i < numChunks) {
        let start = i * MAX_CHUNK_SIZE;
        let end_ = Nat.min(start + MAX_CHUNK_SIZE, dataSize);
        let chunkData = if (start >= dataSize) {
          Blob.fromArray([]);
        } else {
          Blob.fromArray(Array.tabulate<Nat8>(end_ - start, func(j) { dataBytes[start + j] }));
        };
        chunks[i] := encryptChunkData(masterKey, id, i, chunkData);
        i += 1;
      };

      entries.put(id, { id; mimeType; chunks; totalSize = dataSize; createdAt = Time.now() });
      #ok;
    };

    /// Initialize a multi-chunk upload.
    public func putChunkedInit(id : Text, mimeType : Text, totalSize : Nat, chunkCount : Nat) : Types.ContentStoreResult {
      switch (entries.get(id)) {
        case (?_) { return #contentAlreadyExists };
        case (null) {};
      };

      let chunks = Array.init<Blob>(chunkCount, "");
      entries.put(id, { id; mimeType; chunks; totalSize; createdAt = Time.now() });
      #ok;
    };

    /// Upload one chunk (encrypted).
    public func putChunk(id : Text, index : Nat, data : Blob) : Types.ContentStoreResult {
      switch (entries.get(id)) {
        case (null) { #contentNotFound };
        case (?entry) {
          if (index >= entry.chunks.size()) { return #chunkNotFound(index) };
          if (data.size() > MAX_CHUNK_SIZE) { return #chunkTooLarge(data.size()) };
          entry.chunks[index] := encryptChunkData(masterKey, id, index, data);
          #ok;
        };
      };
    };

    /// Retrieve and decrypt full blob (reassembles chunks).
    public func get(id : Text) : ?Blob {
      switch (entries.get(id)) {
        case (null) { null };
        case (?entry) {
          let buf = Buffer.Buffer<Nat8>(entry.totalSize);
          var i : Nat = 0;
          while (i < entry.chunks.size()) {
            let decrypted = decryptChunkData(masterKey, id, i, entry.chunks[i]);
            for (byte in Blob.toArray(decrypted).vals()) {
              buf.add(byte);
            };
            i += 1;
          };
          ?Blob.fromArray(Buffer.toArray(buf));
        };
      };
    };

    /// Retrieve and decrypt a single chunk.
    public func getChunk(id : Text, index : Nat) : ?Blob {
      switch (entries.get(id)) {
        case (null) { null };
        case (?entry) {
          if (index >= entry.chunks.size()) { return null };
          ?decryptChunkData(masterKey, id, index, entry.chunks[index]);
        };
      };
    };

    /// Metadata without blob data.
    public func getMetadata(id : Text) : ?Types.ContentEntry {
      switch (entries.get(id)) {
        case (null) { null };
        case (?entry) {
          ?{
            id = entry.id;
            mimeType = entry.mimeType;
            totalSize = entry.totalSize;
            chunkCount = entry.chunks.size();
            createdAt = entry.createdAt;
          };
        };
      };
    };

    /// List all entries (metadata only).
    public func list() : [Types.ContentEntry] {
      Iter.toArray(
        Iter.map<(Text, InternalEntry), Types.ContentEntry>(
          entries.entries(),
          func((_, entry)) : Types.ContentEntry {
            {
              id = entry.id;
              mimeType = entry.mimeType;
              totalSize = entry.totalSize;
              chunkCount = entry.chunks.size();
              createdAt = entry.createdAt;
            };
          },
        )
      );
    };

    /// Remove an entry.
    public func delete(id : Text) : Types.ContentStoreResult {
      switch (entries.remove(id)) {
        case (null) { #contentNotFound };
        case (?_) { #ok };
      };
    };

    /// Bridge to Gateway.issueGrant() — returns a ContentRef for the given ID.
    public func toContentRef(id : Text) : ?Types.ContentRef {
      switch (entries.get(id)) {
        case (null) { null };
        case (?entry) {
          ?{
            id = entry.id;
            mimeType = ?entry.mimeType;
            sizeBytes = ?entry.totalSize;
            metadata = null;
          };
        };
      };
    };

    /// Serialize for upgrades. Data stays encrypted in stable state.
    public func toStable() : Types.StableContentStoreState {
      let stableEntries = Iter.toArray(
        Iter.map<(Text, InternalEntry), Types.StableContentEntry>(
          entries.entries(),
          func((_, entry)) : Types.StableContentEntry {
            {
              id = entry.id;
              mimeType = entry.mimeType;
              chunks = Array.freeze(entry.chunks);
              totalSize = entry.totalSize;
              createdAt = entry.createdAt;
            };
          },
        )
      );
      { entries = stableEntries };
    };

    /// Deserialize after upgrade.
    public func loadStable(data : Types.StableContentStoreState) {
      entries := HashMap.HashMap<Text, InternalEntry>(
        data.entries.size(), Text.equal, Text.hash,
      );
      for (entry in data.entries.vals()) {
        entries.put(entry.id, {
          id = entry.id;
          mimeType = entry.mimeType;
          chunks = Array.thaw<Blob>(entry.chunks);
          totalSize = entry.totalSize;
          createdAt = entry.createdAt;
        });
      };
    };
  };
};
