-- BootEntry.dhall — BLS (Boot Loader Specification) entry type
--
-- Represents a single /boot/loader/entries/*.conf file.
-- BLS entries are the source of truth for GRUB on Rocky/RHEL with
-- GRUB_ENABLE_BLSCFG=true. Never regenerate grub.cfg directly.
--
-- CRITICAL: `rootDevice` is a required field. It is prepended to `extraOptions`
-- when rendering. This prevents the boot failure where a missing `root=` causes
-- initrd-switch-root to fail ("os-release file is missing") because /sysroot
-- is never mounted even though LVM is activated.

let BootEntry =
      { title : Text
      , version : Text
      , linux : Text
      , initrd : List Text
      , rootDevice : Text
      , extraOptions : Text
      , machineId : Text
      , grubClass : Optional Text
      }

let renderOptions =
      \(entry : BootEntry) ->
            "root=${entry.rootDevice} ${entry.extraOptions}"

let render =
      \(entry : BootEntry) ->
        let initrdLines =
              List/fold
                Text
                entry.initrd
                Text
                (\(i : Text) -> \(acc : Text) -> acc ++ "initrd ${i}\n")
                ""

        let grubClassLine =
              merge
                { Some = \(c : Text) -> "grub_class ${c}\n"
                , None = ""
                }
                entry.grubClass

        let options = renderOptions entry

        in      "title ${entry.title}\n"
            ++  "version ${entry.version}\n"
            ++  "linux ${entry.linux}\n"
            ++  initrdLines
            ++  "options ${options}\n"
            ++  "id ${entry.machineId}-${entry.version}\n"
            ++  grubClassLine

in  { BootEntry, render, renderOptions }
