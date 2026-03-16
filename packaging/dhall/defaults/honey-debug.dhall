-- honey-debug.dhall — Debug boot configuration
--
-- Minimal boot with early console, single CPU, and rd.break for
-- troubleshooting kernel boot failures. Use this when a new kernel
-- fails to boot — select the debug entry from GRUB menu.

let BootEntry = (../types/BootEntry.dhall).BootEntry
let GrubDefaults = (../types/GrubDefaults.dhall).GrubDefaults
let DracutConfig = (../types/DracutConfig.dhall).DracutConfig
let FstabEntry = (../types/FstabEntry.dhall).FstabEntry
let BootGeneration = (../types/BootGeneration.dhall).BootGeneration

let stock = ./honey-stock.dhall

let debugOptions =
        "root=/dev/mapper/rl00-root ro"
    ++  " rd.lvm.lv=rl00/root rd.lvm.lv=rl00/swap"
    ++  " earlyprintk=vga,keep ignore_loglevel initcall_debug"
    ++  " nosmp nosoftlockup systemd.log_level=debug"
    ++  " rd.break"

let config
    : BootGeneration
    = { generation = 99
      , description = "Debug boot — early console, single CPU, rd.break"
      , bootEntry =
        { title = "Rocky Linux (debug) 10.1 (Coughlan)"
        , version = stock.bootEntry.version
        , linux = stock.bootEntry.linux
        , initrd = stock.bootEntry.initrd
        , options = debugOptions
        , machineId = "honey"
        , grubClass = Some "kernel"
        }
      , grubDefaults = stock.grubDefaults
      , dracutConfig =
        { name = "debug"
        , addDrivers = [ "nvme", "nvme_core", "amdgpu" ]
        , addModules = [ "lvm" ]
        , omitDrivers = [] : List Text
        , hostonly = False
        , earlyMicrocode = True
        , fipsModule = False
        }
      , fstabEntries = stock.fstabEntries
      , rootDevice = "/dev/mapper/rl00-root"
      , rootVG = "rl00"
      }

-- Safety invariants (checked at Dhall evaluation time)
-- GRUB cannot read thin LVM: Red Hat BZ#1164947 (2014, WONTFIX)
let _ = assert : config.rootVG === "rl00"
let _ = assert : config.grubDefaults.enableBLS === True

in  config
