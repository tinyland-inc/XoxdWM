-- BootGeneration.dhall — Ties boot configuration into an atomic generation
--
-- A BootGeneration is a complete, validated snapshot of boot configuration.
-- Every change to boot config produces a new generation. The previous
-- generation is always preserved as a fallback BLS entry.

let BootEntry = (./BootEntry.dhall).BootEntry
let FstabEntry = (./FstabEntry.dhall).FstabEntry
let GrubDefaults = (./GrubDefaults.dhall).GrubDefaults
let DracutConfig = (./DracutConfig.dhall).DracutConfig

let BootGeneration =
      { generation : Natural
      , description : Text
      , bootEntry : BootEntry
      , grubDefaults : GrubDefaults
      , dracutConfig : DracutConfig
      , fstabEntries : List FstabEntry
      , rootDevice : Text
      , rootVG : Text
      }

-- Safety invariants:
-- Place `assert` in each defaults/*.dhall file where concrete values exist.
-- Dhall assertions are compile-time checks — they require concrete values.
--
-- Required assertions (copy into each defaults file):
--   assert : config.rootVG === "rl00"
--   assert : config.grubDefaults.enableBLS === True
--
-- Root VG must be "rl00" (the thick LVM VG on honey).
-- GRUB cannot read thin LVM: Red Hat BZ#1164947 (2014, WONTFIX).
-- diskfilter.c only supports thick/linear/mirror/raid LVs.
-- BLS must be enabled — never use legacy grub.cfg generation.

in  { BootGeneration }
