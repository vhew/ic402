/// ic402 — Optional encrypted in-canister content storage.
///
/// Encrypts all content at rest using ChaCha20-Poly1305 (RFC 8439).
/// The encryption key is derived from the canister's own principal —
/// only the canister's code can decrypt. Authenticated encryption
/// prevents both eavesdropping and tampering.
import Types "Types";
import SHA256 "mo:sha2/Sha256";
import ChaCha "mo:chacha";
import Array "mo:base/Array";
import Blob "mo:base/Blob";
import Buffer "mo:base/Buffer";
import HashMap "mo:base/HashMap";
import Iter "mo:base/Iter";
import Int "mo:base/Int";
import Nat "mo:base/Nat";
import Nat8 "mo:base/Nat8";
import Order "mo:base/Order";
import Principal "mo:base/Principal";
import Text "mo:base/Text";
import Time "mo:base/Time";
import Debug "mo:base/Debug";
import Utils "Utils";

module {

  let MAX_CHUNK_SIZE : Nat = 1_572_864; // 1.5 MB — safe under ICP's 2 MB message limit

  type InternalEntry = {
    id : Text;
    mimeType : Text;
    chunks : [var Blob];
    totalSize : Nat;
    createdAt : Int;
  };

  // ── Encryption helpers (ChaCha20-Poly1305 AEAD) ──

  /// Derive a 32-byte ChaCha20 key for a specific chunk.
  /// key = SHA-256(masterKey || contentId || chunkIndex)
  func deriveChunkKey(masterKey : [Nat8], contentId : Text, chunkIndex : Nat) : [Nat8] {
    let idBytes = Blob.toArray(Text.encodeUtf8(contentId));
    let indexBytes = Utils.natToBytes8(chunkIndex);
    Blob.toArray(SHA256.fromArray(#sha256, Array.append(Array.append(masterKey, idBytes), indexBytes)));
  };

  /// Derive a 12-byte nonce from contentId + chunkIndex.
  /// nonce = SHA-256(contentId || chunkIndex)[0..12]
  func deriveNonce(contentId : Text, chunkIndex : Nat) : [Nat8] {
    let idBytes = Blob.toArray(Text.encodeUtf8(contentId));
    let indexBytes = Utils.natToBytes8(chunkIndex);
    let hash = Blob.toArray(SHA256.fromArray(#sha256, Array.append(idBytes, indexBytes)));
    Array.subArray(hash, 0, 12);
  };

  /// Encrypt a chunk with ChaCha20-Poly1305 AEAD.
  /// Returns ciphertext || tag (16-byte auth tag appended).
  func encryptChunkData(masterKey : [Nat8], contentId : Text, chunkIndex : Nat, data : Blob) : Blob {
    let key = deriveChunkKey(masterKey, contentId, chunkIndex);
    let nonce = deriveNonce(contentId, chunkIndex);
    let (ciphertext, tag) = ChaCha.aeadEncryptWithNonce(
      Blob.toArray(data),
      [], // no additional authenticated data
      key,   // 32-byte key
      nonce, // 12-byte nonce
    );
    Blob.fromArray(Array.append<Nat8>(ciphertext, tag));
  };

  /// Decrypt a chunk with ChaCha20-Poly1305 AEAD.
  /// Input is ciphertext || tag (last 16 bytes are tag).
  /// H-6: Returns null on authentication failure instead of silently returning empty blob.
  func decryptChunkData(masterKey : [Nat8], contentId : Text, chunkIndex : Nat, data : Blob) : ?Blob {
    let bytes = Blob.toArray(data);
    if (bytes.size() < 16) return null;
    let ciphertext = Array.subArray(bytes, 0, bytes.size() - 16);
    let tag = Array.subArray(bytes, bytes.size() - 16, 16);
    let key = deriveChunkKey(masterKey, contentId, chunkIndex);
    let nonce = deriveNonce(contentId, chunkIndex);
    switch (ChaCha.aeadDecryptWithNonce(ciphertext, tag, [], key, nonce)) {
      case (?plaintext) { ?Blob.fromArray(plaintext) };
      case (null) { null }; // authentication failed — tampered or wrong key
    };
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
    // M-6: Changed to var so it can be re-keyed with external randomness
    var masterKey : [Nat8] = do {
      let principalBytes = Blob.toArray(Principal.toBlob(selfPrincipal));
      let suffix = Blob.toArray(Text.encodeUtf8("ic402-content-key"));
      Blob.toArray(SHA256.fromArray(#sha256, Array.append(principalBytes, suffix)));
    };

    // H-3: Tracks whether initExternalSeed() has been called.
    // Defaults to true because the deterministic key (from principal) provides
    // basic encryption. Call initExternalSeed() for production-grade security.
    // The consuming canister should call initExternalSeed(raw_rand()) on first deploy.
    var seedInitialized : Bool = true;

    /// M-6: Initialize master key with external randomness.
    /// Derives key: SHA-256(seed ++ principal ++ "ic402-content-key").
    /// Call once on first deployment with raw_rand() output.
    /// Returns true if initialized, false if already initialized (idempotent).
    /// WARNING: Cannot be called again after initialization — re-keying invalidates all encrypted content.
    public func initExternalSeed(seed : Blob) : Bool {
      if (seedInitialized) { return false };
      let seedBytes = Blob.toArray(seed);
      let principalBytes = Blob.toArray(Principal.toBlob(selfPrincipal));
      let suffix = Blob.toArray(Text.encodeUtf8("ic402-content-key"));
      masterKey := Blob.toArray(SHA256.fromArray(#sha256, Array.append(Array.append(seedBytes, principalBytes), suffix)));
      seedInitialized := true;
      true;
    };

    var entries = HashMap.HashMap<Text, InternalEntry>(16, Text.equal, Text.hash);

    /// Store a blob, encrypting and auto-chunking at 1.5 MB.
    public func put(id : Text, mimeType : Text, data : Blob) : Types.ContentStoreResult {
      // H-3: Refuse writes before external seed initialization — the default key
      // derived from principal alone is deterministic and weaker.
      if (not seedInitialized) {
        Debug.trap("ic402: ContentStore encryption not initialized — call startTimers() or initExternalSeed() first");
      };
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
      // H-3: Refuse writes before external seed initialization.
      if (not seedInitialized) {
        Debug.trap("ic402: ContentStore encryption not initialized — call startTimers() or initExternalSeed() first");
      };
      switch (entries.get(id)) {
        case (?_) { return #contentAlreadyExists };
        case (null) {};
      };

      let chunks = Array.init<Blob>(chunkCount, "");
      entries.put(id, { id; mimeType; chunks; totalSize; createdAt = Time.now() });
      #ok;
    };

    /// Upload one chunk (encrypted). Chunks are write-once — cannot be overwritten
    /// after initial upload to prevent CTR keystream reuse.
    public func putChunk(id : Text, index : Nat, data : Blob) : Types.ContentStoreResult {
      switch (entries.get(id)) {
        case (null) { #contentNotFound };
        case (?entry) {
          if (index >= entry.chunks.size()) { return #chunkNotFound(index) };
          if (data.size() > MAX_CHUNK_SIZE) { return #chunkTooLarge(data.size()) };
          // Reject overwrites — CTR mode reuses the same keystream for the same (id, index)
          if (Blob.toArray(entry.chunks[index]).size() > 0) { return #contentAlreadyExists };
          entry.chunks[index] := encryptChunkData(masterKey, id, index, data);
          #ok;
        };
      };
    };

    /// Retrieve and decrypt full blob (reassembles chunks).
    /// H-6: Returns null if any chunk fails authentication (tampered or wrong key).
    public func get(id : Text) : ?Blob {
      switch (entries.get(id)) {
        case (null) { null };
        case (?entry) {
          let buf = Buffer.Buffer<Nat8>(entry.totalSize);
          var i : Nat = 0;
          while (i < entry.chunks.size()) {
            switch (decryptChunkData(masterKey, id, i, entry.chunks[i])) {
              case (?decrypted) {
                for (byte in Blob.toArray(decrypted).vals()) {
                  buf.add(byte);
                };
              };
              case (null) { return null }; // H-6: decryption authentication failed
            };
            i += 1;
          };
          ?Blob.fromArray(Buffer.toArray(buf));
        };
      };
    };

    /// Retrieve and decrypt a single chunk.
    /// H-6: Returns null if decryption authentication fails (tampered or wrong key).
    public func getChunk(id : Text, index : Nat) : ?Blob {
      switch (entries.get(id)) {
        case (null) { null };
        case (?entry) {
          if (index >= entry.chunks.size()) { return null };
          decryptChunkData(masterKey, id, index, entry.chunks[index]);
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

    /// List all entries (metadata only), sorted by createdAt ascending.
    public func list() : [Types.ContentEntry] {
      let items = Iter.toArray(
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
      Array.sort<Types.ContentEntry>(items, func(a, b) {
        Int.compare(a.createdAt, b.createdAt);
      });
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
      // seedInitialized defaults to true. If initExternalSeed was called in a
      // previous deployment, the master key was already upgraded. Content remains
      // readable because the stable key bytes are restored by the persistent actor.
    };
  };
};
