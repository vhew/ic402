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
import Timer "mo:base/Timer";
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
    // M-2: per-entry salt mixed into key + nonce derivation. A re-created id
    // (delete + re-put) gets a fresh salt, so the same (key, nonce) — and thus
    // the same keystream — is never reused across the two encryptions.
    salt : Nat;
  };

  // ── Encryption helpers (ChaCha20-Poly1305 AEAD) ──

  /// Derive a 32-byte ChaCha20 key for a specific chunk.
  /// key = SHA-256(masterKey || salt || contentId || chunkIndex)
  func deriveChunkKey(masterKey : [Nat8], salt : Nat, contentId : Text, chunkIndex : Nat) : [Nat8] {
    let saltBytes = Utils.natToBytes8(salt); // fixed 8 bytes: unambiguous boundary with the variable-length contentId
    let idBytes = Blob.toArray(Text.encodeUtf8(contentId));
    let indexBytes = Utils.natToBytes8(chunkIndex);
    Blob.toArray(SHA256.fromArray(#sha256, Array.append(Array.append(Array.append(masterKey, saltBytes), idBytes), indexBytes)));
  };

  /// Derive a 12-byte nonce from salt + contentId + chunkIndex.
  /// nonce = SHA-256(salt || contentId || chunkIndex)[0..12]
  func deriveNonce(salt : Nat, contentId : Text, chunkIndex : Nat) : [Nat8] {
    let saltBytes = Utils.natToBytes8(salt); // fixed 8 bytes: unambiguous boundary with the variable-length contentId
    let idBytes = Blob.toArray(Text.encodeUtf8(contentId));
    let indexBytes = Utils.natToBytes8(chunkIndex);
    let hash = Blob.toArray(SHA256.fromArray(#sha256, Array.append(Array.append(saltBytes, idBytes), indexBytes)));
    Array.subArray(hash, 0, 12);
  };

  /// Encrypt a chunk with ChaCha20-Poly1305 AEAD.
  /// Returns ciphertext || tag (16-byte auth tag appended).
  func encryptChunkData(masterKey : [Nat8], salt : Nat, contentId : Text, chunkIndex : Nat, data : Blob) : Blob {
    let key = deriveChunkKey(masterKey, salt, contentId, chunkIndex);
    let nonce = deriveNonce(salt, contentId, chunkIndex);
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
  func decryptChunkData(masterKey : [Nat8], salt : Nat, contentId : Text, chunkIndex : Nat, data : Blob) : ?Blob {
    let bytes = Blob.toArray(data);
    if (bytes.size() < 16) return null;
    let ciphertext = Array.subArray(bytes, 0, Utils.satSub(bytes.size(), 16));
    let tag = Array.subArray(bytes, Utils.satSub(bytes.size(), 16), 16);
    let key = deriveChunkKey(masterKey, salt, contentId, chunkIndex);
    let nonce = deriveNonce(salt, contentId, chunkIndex);
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

    // Placeholder master key derived from the (public) principal. This is NEVER
    // used to encrypt: put()/putChunkedInit() trap until initExternalSeed() has
    // installed a real key from canister randomness (see seedInitialized below).
    var masterKey : [Nat8] = do {
      let principalBytes = Blob.toArray(Principal.toBlob(selfPrincipal));
      let suffix = Blob.toArray(Text.encodeUtf8("ic402-content-key"));
      Blob.toArray(SHA256.fromArray(#sha256, Array.append(principalBytes, suffix)));
    };

    // H-6 (v2): Defaults to FALSE — external-randomness seeding is now REQUIRED.
    // The previous default (true) made the encryption key fully deterministic from
    // the public canister principal, so anyone who exfiltrated stable memory could
    // re-derive it. Writes trap until initExternalSeed(raw_rand()) installs a real
    // key; ContentStore.startTimers() (or the consuming actor) must call it once
    // after deploy. Existing pre-v2 deterministic-key content must be migrated.
    var seedInitialized : Bool = false;

    // M-2: monotonic counter backing per-entry salts (persisted in stable state).
    var saltCounter : Nat = 0;

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

    /// H-6 (v2): Auto-seed the master key from canister randomness on first deploy.
    /// Call once from actor context (requires <system>). Idempotent: does nothing
    /// if the key was already seeded (incl. restored from stable state on upgrade).
    public func startTimers<system>() {
      if (seedInitialized) { return };
      ignore Timer.setTimer<system>(#seconds 0, func() : async () {
        if (seedInitialized) { return };
        let ic : actor { raw_rand : () -> async Blob } = actor "aaaaa-aa";
        let seed = await ic.raw_rand();
        ignore initExternalSeed(seed);
      });
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

      saltCounter += 1;
      let salt = saltCounter;
      let dataSize = data.size();
      let numChunks = if (dataSize == 0) { 1 } else {
        (dataSize + Utils.satSub(MAX_CHUNK_SIZE, 1)) / MAX_CHUNK_SIZE;
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
        chunks[i] := encryptChunkData(masterKey, salt, id, i, chunkData);
        i += 1;
      };

      entries.put(id, { id; mimeType; chunks; totalSize = dataSize; createdAt = Time.now(); salt });
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

      saltCounter += 1;
      let salt = saltCounter;
      let chunks = Array.init<Blob>(chunkCount, "");
      entries.put(id, { id; mimeType; chunks; totalSize; createdAt = Time.now(); salt });
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
          entry.chunks[index] := encryptChunkData(masterKey, entry.salt, id, index, data);
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
            switch (decryptChunkData(masterKey, entry.salt, id, i, entry.chunks[i])) {
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
          decryptChunkData(masterKey, entry.salt, id, index, entry.chunks[index]);
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
    /// H-7 (v2): the master key, seed flag, and salt counter are persisted so
    /// externally-seeded content stays decryptable across upgrades.
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
              salt = ?entry.salt;
            };
          },
        )
      );
      {
        entries = stableEntries;
        masterKey = ?Blob.fromArray(masterKey);
        seedInitialized = ?seedInitialized;
        saltCounter = ?saltCounter;
      };
    };

    /// Deserialize after upgrade.
    /// H-7 (v2): restore the persisted key/flag/salt counter. Fields are optional
    /// so pre-v2 state still decodes (without a persisted key the store stays
    /// unseeded and writes trap until re-seeded — pre-v2 content must be migrated).
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
          salt = switch (entry.salt) { case (?s) { s }; case (null) { 0 } };
        });
      };
      switch (data.masterKey) { case (?k) { masterKey := Blob.toArray(k) }; case (null) {} };
      switch (data.seedInitialized) { case (?s) { seedInitialized := s }; case (null) {} };
      switch (data.saltCounter) { case (?c) { saltCounter := c }; case (null) {} };
    };
  };
};
