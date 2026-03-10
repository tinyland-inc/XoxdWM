# Upstream Submission: DSC QP Table + RC Offset Fixes

## Status: PLANNED

## Summary

The `amd-bsb-dsc-fix.patch` (raika-xino) corrects a VESA DSC 1.1 Table E-5
transcription error in the AMD display driver's rate control parameters for
8bpc 4:4:4 at 8 BPP. This fix has never been submitted upstream.

## Files Modified

- `drivers/gpu/drm/amd/display/dc/dml/dsc/qp_tables.h` — 2 hunks
  (qp_table_444_8bpc_max, qp_table_444_8bpc_min at BPP=8)
- `drivers/gpu/drm/amd/display/dc/dml/dsc/rc_calc_fpu.c` — 1 hunk
  (ofs[11] in get_ofs_set for CM_444/CM_RGB: -10 → -12)

## Why This Matters

Without this fix, DSC at 8 BPP in 4:4:4 mode produces incorrect rate control
parameters. Displays requiring this mode (e.g., Bigscreen Beyond VR headset)
show rainbow static or fail to decode. The fix aligns the kernel tables with
the VESA DSC 1.1 reference model.

## Independence from Bolyukin's Series

Bolyukin's 7-patch VESA DisplayID series (v7, reviewed but not merged) modifies
completely different files (drm_edid.c, amdgpu_dm.c, drm_connector.h, etc.).
Zero merge conflicts. Submit independently.

## Target

- **Tree**: `amd-staging-drm-next` (AMD display internal)
- **List**: `amd-gfx@lists.freedesktop.org`, CC `dri-devel@lists.freedesktop.org`
- **Maintainers**: Harry Wentland, Leo Li, Austin Zheng, Jun Lei, Alex Deucher

## Proposed Commit Message

```
drm/amd/display: fix DSC RC parameters for 8bpc 4:4:4 at 8 BPP

The qp_table_444_8bpc_max and qp_table_444_8bpc_min entries at BPP=8.0
have incorrect values that cause DSC encoder rate control failure. The
RC offset ofs[11] in get_ofs_set() for CM_444/CM_RGB incorrectly uses
-10 instead of -12 when BPP >= 8.

Correct the QP range tables and RC offset to match the VESA DSC 1.1
reference model output (Table E-5) for the 8bpc 4:4:4 at 8 BPP
operating point.

This fixes visual artifacts on displays requiring DSC at 8 BPP in
4:4:4 mode, such as the Bigscreen Beyond VR headset.

Signed-off-by: Jess Sullivan <jess@jesssullivan.dev>
Tested-by: Jess Sullivan <jess@jesssullivan.dev> # RX 9070 XT + Beyond 2e
Cc: stable@vger.kernel.org
```

## Steps

1. [ ] Contact raika-xino re: attribution (Co-developed-by vs Reported-by)
2. [ ] Clone amd-staging-drm-next, apply fix, verify with checkpatch.pl
3. [ ] Generate patch with git format-patch
4. [ ] Run scripts/get_maintainer.pl to confirm CC list
5. [ ] Send via git send-email
6. [ ] Solicit additional Tested-by from CachyOS issue #731 participants
7. [ ] Follow up after 2 weeks if no response

## Timeline

- Submit: after linux-xr kernel validates fix on honey
- Expected review: 1-2 weeks
- Expected merge: 3-4 weeks → 7.1-rc1 (~June 2026)
- Cc: stable → backport to 6.19.x, 6.12.x LTS within weeks of merge

## References

- raika-xino repo: https://github.com/raika-xino/amd-bsb-dsc-fix
- CachyOS issue #731 (patches applied to 6.19/7.0)
- Bolyukin v7: https://lore.kernel.org/amd-gfx/ (Dec 2, 2025)
- VESA DSC 1.1 specification, Annex E, Table E-5
