# Honey Storage Architecture

## Why pvmove, Not Thin LVM Root

**GRUB cannot read thin LVM.** This is an architectural limitation of GRUB's
`diskfilter.c`, not a bug. It has been documented since 2014:

- **Red Hat Bugzilla #1164947** (filed 2014-11-16, open, WONTFIX):
  GRUB's diskfilter only supports thick/linear/mirror/raid LV types. Thin
  provisioning uses a separate metadata LV + data LV that GRUB cannot parse.

- **Error when attempting thin LVM root**:
  ```
  error: diskfilter writes are not supported
  ```

- **Why it won't be fixed**: Thin LVM requires dm-thin-pool kernel module,
  which is unavailable at GRUB stage. GRUB would need to implement thin pool
  metadata parsing in its own block layer — an enormous scope change with no
  upstream interest.

**Conclusion: thin pools are for data volumes only — never root.**

## The pvmove Approach

`pvmove` live-migrates LV extents between PVs within the same VG. After
migration:

- VG name: unchanged (`rl00`)
- LV name: unchanged (`root`, `swap`)
- LV UUID: unchanged
- GRUB config: unchanged
- BLS entries: unchanged
- fstab: unchanged
- initramfs: unchanged (rebuilt for NVMe modules only)

This is the approach that should have been used from the start instead of
attempting a thin LVM root migration, which bricked the server.

## Target Layout

```
Device          VG      LVM Type    Mount            Size
────────────────────────────────────────────────────────────
sda1            -       -           /boot/efi        600M (FAT32)
sda2            -       -           /boot            1G (xfs)
sda3            -       -           (freed)          -

nvme0n1p1       rl00    thick       /                ~2TB (xfs)
                rl00    thick       swap             32G
                rl00    thick       /home            373G (original)

nvme1n1p1       data    thin pool   /home            500G (xfs)
                data    thin pool   /var/lib/rancher 500G (xfs)
                data    thin pool   /data            200G (xfs)

sdb3            hdd     thick       /archive         3.5T (xfs)
```

### Why This Layout

| Volume | LVM Type | Rationale |
|--------|----------|-----------|
| root   | **Thick** | GRUB must read it at boot (BZ#1164947) |
| swap   | **Thick** | resume= references it in boot params |
| /home  | Thin     | Data volume, overprovisioned, snapshottable |
| /var/lib/rancher | Thin | Container storage, snapshottable |
| /data  | Thin     | BCI data, snapshottable |
| /archive | Thick  | HDD, no benefit from thin (single LV fills disk) |

## Migration Phases

See `packaging/scripts/honey-storage-migrate` for the phased migration:

1. **phase0**: Pre-flight checks (non-destructive)
2. **phase1**: Clean failed thin pool, partition NVMe, `pvmove` root (live)
3. **phase2**: Set up data thin pool on second NVMe (after reboot)
4. **phase3**: Set up HDD archive tier
5. **phase4**: Install boom-boot for kernel snapshot testing

## Boot Configuration Pipeline

All boot config changes now flow through Dhall:

```
packaging/dhall/defaults/honey-*.dhall   (source of truth)
    → dhall text                         (type-check + assertions)
    → /tmp/boot-staging/                 (rendered text)
    → diff against current               (human review)
    → packaging/scripts/boot-apply       (install with backup)
```

Safety invariants enforced at Dhall evaluation time:
- Root must reference thick LVM VG (`rl00`)
- BLS must be enabled (`GRUB_ENABLE_BLSCFG=true`)
- New BLS entries created (existing never modified)
- `grub2-mkconfig` never runs (BLS entries are the source of truth)

See `packaging/dhall/types/BootGeneration.dhall` for the assertion definitions.

## Lessons Learned

1. **Never attempt thin LVM root** — GRUB cannot read it (BZ#1164947, 2014)
2. **pvmove preserves all identifiers** — zero boot config changes needed
3. **BLS entries are the source of truth** — never run `grub2-mkconfig`
4. **Always keep a fallback boot entry** — never modify all entries at once
5. **Dhall catches errors at render time** — bad configs never reach the system
