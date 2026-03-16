-- generate-boot.dhall — Rendering pipeline for boot generations
--
-- Usage:
--   dhall text --file packaging/dhall/generate-boot.dhall
--
-- This renders the active boot generation (honey-xr by default) into
-- the text that boot-apply will stage and install.

let BootEntry = ./types/BootEntry.dhall
let GrubDefaults = ./types/GrubDefaults.dhall
let DracutConfig = ./types/DracutConfig.dhall
let FstabTypes = ./types/FstabEntry.dhall
let BootGen = ./types/BootGeneration.dhall

-- Select which generation to render.
-- Assertions in the defaults file are checked when this import is evaluated.
-- If rootVG != "rl00" or enableBLS != True, Dhall will abort here.
let gen = ./defaults/honey-xr.dhall

let blsEntry = BootEntry.render gen.bootEntry
let grubDefaults = GrubDefaults.render gen.grubDefaults
let dracutConfig = DracutConfig.render gen.dracutConfig

let fstab =
      List/fold
        FstabTypes.FstabEntry
        gen.fstabEntries
        Text
        ( \(entry : FstabTypes.FstabEntry) ->
          \(acc : Text) ->
            acc ++ FstabTypes.render entry ++ "\n"
        )
        ""

in      "# Boot Generation ${Natural/show gen.generation}\n"
    ++  "# ${gen.description}\n"
    ++  "#\n"
    ++  "# Root: ${gen.rootDevice} (VG: ${gen.rootVG}, thick LVM)\n"
    ++  "# GRUB cannot read thin LVM — Red Hat BZ#1164947 (2014, WONTFIX)\n"
    ++  "\n"
    ++  "### BLS Entry (/boot/loader/entries/) ###\n"
    ++  blsEntry
    ++  "\n"
    ++  "### /etc/default/grub ###\n"
    ++  grubDefaults
    ++  "\n"
    ++  "### /etc/dracut.conf.d/ ###\n"
    ++  dracutConfig
    ++  "\n"
    ++  "### fstab entries ###\n"
    ++  fstab
