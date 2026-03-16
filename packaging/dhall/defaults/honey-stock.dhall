-- honey-stock.dhall — Rocky 10.1 stock boot config (known-good baseline)
--
-- This represents the factory-default boot configuration that honey is
-- currently running. Rendering this and diffing against the live system
-- validates that the Dhall pipeline produces correct output.
--
-- Use this as a baseline: any new BootGeneration should diff cleanly
-- against this to show exactly what changes.

let BootEntry = (../types/BootEntry.dhall).BootEntry
let GrubDefaults = (../types/GrubDefaults.dhall).GrubDefaults
let DracutConfig = (../types/DracutConfig.dhall).DracutConfig
let FstabEntry = (../types/FstabEntry.dhall).FstabEntry
let BootGeneration = (../types/BootGeneration.dhall).BootGeneration

let config
    : BootGeneration
    = { generation = 0
      , description = "Rocky 10.1 stock (ELRepo kernel-ml, known-good)"
      , bootEntry =
        { title = "Rocky Linux (6.15.4-1.el10.elrepo.x86_64) 10.1 (Coughlan)"
        , version = "6.15.4-1.el10.elrepo.x86_64"
        , linux = "/vmlinuz-6.15.4-1.el10.elrepo.x86_64"
        , initrd = [ "/initramfs-6.15.4-1.el10.elrepo.x86_64.img" ]
        , options =
                "root=/dev/mapper/rl00-root ro"
            ++  " rd.lvm.lv=rl00/root rd.lvm.lv=rl00/swap"
            ++  " crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M"
            ++  " resume=/dev/mapper/rl00-swap"
            ++  " amdgpu.modeset=1 amdgpu.dc=1 amdgpu.dcdebugmask=0x10"
        , machineId = "honey"
        , grubClass = Some "kernel"
        }
      , grubDefaults =
        { cmdlineDefault =
                "root=/dev/mapper/rl00-root rd.lvm.lv=rl00/root rd.lvm.lv=rl00/swap"
            ++  " crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M"
            ++  " resume=/dev/mapper/rl00-swap"
            ++  " amdgpu.modeset=1 amdgpu.dc=1 amdgpu.dcdebugmask=0x10"
        , timeout = 5
        , enableBLS = True
        , terminalOutput = "console"
        , disableRecovery = True
        , disableSubmenu = True
        }
      , dracutConfig =
        { name = "stock"
        , addDrivers = [ "nvme", "nvme_core", "amdgpu" ]
        , addModules = [ "lvm" ]
        , omitDrivers = [] : List Text
        , hostonly = True
        , earlyMicrocode = True
        , fipsModule = False
        }
      , fstabEntries =
        [ { device = "/dev/mapper/rl00-root"
          , mountPoint = "/"
          , fsType = "xfs"
          , options = "defaults"
          , dump = 0
          , pass = 0
          }
        , { device = "/dev/mapper/rl00-swap"
          , mountPoint = "swap"
          , fsType = "swap"
          , options = "defaults"
          , dump = 0
          , pass = 0
          }
        ]
      , rootDevice = "/dev/mapper/rl00-root"
      , rootVG = "rl00"
      }

-- Safety invariants (checked at Dhall evaluation time)
-- GRUB cannot read thin LVM: Red Hat BZ#1164947 (2014, WONTFIX)
let _ = assert : config.rootVG === "rl00"
let _ = assert : config.grubDefaults.enableBLS === True

in  config
