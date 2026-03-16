-- BootEntry.dhall — BLS (Boot Loader Specification) entry type
--
-- Represents a single /boot/loader/entries/*.conf file.
-- BLS entries are the source of truth for GRUB on Rocky/RHEL with
-- GRUB_ENABLE_BLSCFG=true. Never regenerate grub.cfg directly.

let BootEntry =
      { title : Text
      , version : Text
      , linux : Text
      , initrd : List Text
      , options : Text
      , machineId : Text
      , grubClass : Optional Text
      }

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

        in      "title ${entry.title}\n"
            ++  "version ${entry.version}\n"
            ++  "linux ${entry.linux}\n"
            ++  initrdLines
            ++  "options ${entry.options}\n"
            ++  "id ${entry.machineId}-${entry.version}\n"
            ++  grubClassLine

in  { BootEntry, render }
