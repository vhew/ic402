#!/usr/bin/env node

// Generate a DFX-compatible Ed25519 identity PEM for mops publishing.
//
// mops expects an 85-byte PKCS#8 DER that includes both the private and
// public key (the format `dfx identity export` produces). Standard OpenSSL
// Ed25519 PEMs are only 48 bytes and `icp identity` creates secp256k1 —
// neither works with mops.
//
// Usage:
//   node deploy/gen-mops-identity.js > ic402-mops.pem
//   mops user import --no-encrypt -- "$(cat ic402-mops.pem)"
//   mops user get-principal
//
// Back up the PEM file securely — it IS the identity.

import { generateKeyPairSync } from 'node:crypto';

const { privateKey, publicKey } = generateKeyPairSync('ed25519');

const stdDer = privateKey.export({ type: 'pkcs8', format: 'der' });
const privRaw = stdDer.subarray(16, 48);
const pubDer = publicKey.export({ type: 'spki', format: 'der' });
const pubRaw = pubDer.subarray(pubDer.length - 32);

// Build 85-byte DFX-compatible PKCS#8 DER:
//   SEQUENCE {
//     INTEGER 1
//     SEQUENCE { OID 1.3.101.112 (Ed25519) }
//     OCTET STRING { OCTET STRING (32 bytes privkey) }
//     [1] { BIT STRING { 00 + 32 bytes pubkey } }
//   }
const buf = Buffer.alloc(85);
let p = 0;
buf[p++] = 0x30;
buf[p++] = 83; // SEQUENCE (83 bytes)
buf[p++] = 0x02;
buf[p++] = 0x01;
buf[p++] = 0x01; // INTEGER 1
buf[p++] = 0x30;
buf[p++] = 0x05; // SEQUENCE (5 bytes)
buf[p++] = 0x06;
buf[p++] = 0x03;
buf[p++] = 0x2b;
buf[p++] = 0x65;
buf[p++] = 0x70; // OID Ed25519
buf[p++] = 0x04;
buf[p++] = 0x22; // OCTET STRING (34 bytes)
buf[p++] = 0x04;
buf[p++] = 0x20; // OCTET STRING (32 bytes)
privRaw.copy(buf, p);
p += 32; // private key
buf[p++] = 0xa1;
buf[p++] = 0x23; // [1] (35 bytes)
buf[p++] = 0x03;
buf[p++] = 0x21; // BIT STRING (33 bytes)
buf[p++] = 0x00; // no unused bits
pubRaw.copy(buf, p); // public key

const b64 = buf.toString('base64');
const lines = b64.match(/.{1,64}/g).join('\n');
process.stdout.write(`-----BEGIN PRIVATE KEY-----\n${lines}\n-----END PRIVATE KEY-----\n`);
