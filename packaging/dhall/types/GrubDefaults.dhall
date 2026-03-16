-- GrubDefaults.dhall — /etc/default/grub type
--
-- Represents the key settings in /etc/default/grub.
-- GRUB_ENABLE_BLSCFG must always be true on RHEL/Rocky.

let GrubDefaults =
      { cmdlineDefault : Text
      , timeout : Natural
      , enableBLS : Bool
      , terminalOutput : Text
      , disableRecovery : Bool
      , disableSubmenu : Bool
      }

let render =
      \(g : GrubDefaults) ->
        let boolToStr = \(b : Bool) -> if b then "true" else "false"

        in      "GRUB_TIMEOUT=${Natural/show g.timeout}\n"
            ++  "GRUB_DISTRIBUTOR=\"$(sed 's, release .*\$,,g' /etc/system-release)\"\n"
            ++  "GRUB_DEFAULT=saved\n"
            ++  "GRUB_DISABLE_SUBMENU=${boolToStr g.disableSubmenu}\n"
            ++  "GRUB_TERMINAL_OUTPUT=\"${g.terminalOutput}\"\n"
            ++  "GRUB_CMDLINE_LINUX=\"${g.cmdlineDefault}\"\n"
            ++  "GRUB_DISABLE_RECOVERY=\"${boolToStr g.disableRecovery}\"\n"
            ++  "GRUB_ENABLE_BLSCFG=\"${boolToStr g.enableBLS}\"\n"

in  { GrubDefaults, render }
