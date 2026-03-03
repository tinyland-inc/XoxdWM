# R15.2: FIPS 140-3 Implications for WiVRn VR Streaming

## WiVRn Encryption Architecture

WiVRn streams VR frames from a Linux host to a standalone headset (e.g.,
Meta Quest 3) over Wi-Fi. The connection uses:

1. **Discovery**: mDNS/DNS-SD on local network (no encryption)
2. **Control channel**: TCP with optional TLS
3. **Video stream**: RTP/RTSP over UDP, optionally DTLS-encrypted
4. **Audio stream**: Same as video

## Cipher Suites Used

WiVRn links against system OpenSSL for TLS/DTLS operations:

| Protocol | Default Cipher | FIPS Alternative |
|----------|---------------|-----------------|
| DTLS 1.2 | ECDHE-RSA-AES128-GCM-SHA256 | Same (FIPS-approved) |
| DTLS 1.3 | TLS_AES_128_GCM_SHA256 | Same (FIPS-approved) |
| Key Exchange | ECDHE with X25519 | ECDHE with P-256 |

## FIPS Compatibility Assessment

### Compatible
- AES-128-GCM: FIPS-approved (NIST SP 800-38D)
- AES-256-GCM: FIPS-approved
- SHA-256: FIPS-approved (FIPS 180-4)
- ECDHE with P-256: FIPS-approved (SP 800-56A)
- RSA-2048+: FIPS-approved (FIPS 186-5)

### Incompatible (default, but switchable)
- X25519 key exchange: NOT FIPS-approved (use P-256 instead)
- ChaCha20-Poly1305: NOT FIPS-approved (but AES-GCM is the default anyway)

## Latency Impact

Switching from X25519 to P-256 ECDHE:
- X25519: ~0.05ms per key exchange
- P-256: ~0.15ms per key exchange
- Impact: negligible — key exchange happens once per session, not per frame

Switching from ChaCha20 to AES-GCM:
- On AES-NI hardware (all modern x86): AES-GCM is FASTER than ChaCha20
- On ARM without AES extensions: ChaCha20 is ~2x faster
- Impact for VR: Quest 3 uses Snapdragon XR2 Gen 2 (has ARM crypto extensions),
  so AES-GCM performance is comparable

**Conclusion**: FIPS mode has negligible latency impact for VR streaming on
modern hardware.

## Configuration for FIPS Mode

### OpenSSL 3.x FIPS Provider

```bash
# Enable FIPS provider system-wide
openssl fipsinstall -out /etc/ssl/fipsmodule.cnf -module /usr/lib64/ossl-modules/fips.so

# In /etc/ssl/openssl.cnf:
[provider_sect]
default = default_sect
fips = fips_sect

[fips_sect]
activate = 1
```

### WiVRn-Specific

WiVRn respects OpenSSL's FIPS mode when the system provider is active.
No WiVRn-specific configuration needed — it uses OpenSSL's default cipher
negotiation which will restrict to FIPS-approved algorithms.

To verify:
```bash
OPENSSL_FIPS=1 wivrn-server --verbose 2>&1 | grep cipher
# Should show only FIPS-approved cipher suites
```

### NixOS Configuration

```nix
# In NixOS configuration.nix
services.exwm-vr.vr.runtime = "monado";
# WiVRn inherits system OpenSSL FIPS configuration
# No additional config needed

# System-wide FIPS (if NixOS supports it)
security.openssl.fips.enable = true;  # hypothetical
```

## Recommendation

WiVRn's default cipher suite (AES-128-GCM with ECDHE) is already
FIPS-compatible. The only change needed for strict FIPS compliance is ensuring
the OpenSSL FIPS provider is active (to force P-256 over X25519 for key
exchange). This has no measurable latency impact on modern hardware.

**Action items:**
1. Document OpenSSL FIPS provider setup in installation guide
2. Test WiVRn streaming with FIPS provider active — verify no fallback to
   non-approved algorithms
3. Add `ewwm-environment` check for `OPENSSL_FIPS` when VR streaming is enabled
