-- honey-stock.dhall — Rocky 10.1 stock boot config (known-good baseline)
--
-- This represents the actual boot configuration honey is running as of
-- 2026-03-16, after storage migration (root on NVMe via pvmove).
-- Validated against live system: grubby --info=DEFAULT, /etc/default/grub,
-- /etc/fstab, /proc/cmdline.
--
-- Use this as a baseline: any new BootGeneration should diff cleanly
-- against this to show exactly what changes.

let BootEntry = (../types/BootEntry.dhall).BootEntry
let GrubDefaults = (../types/GrubDefaults.dhall).GrubDefaults
let DracutConfig = (../types/DracutConfig.dhall).DracutConfig
let FstabEntry = (../types/FstabEntry.dhall).FstabEntry
let BootGeneration = (../types/BootGeneration.dhall).BootGeneration

-- Machine ID from /etc/machine-id on honey
let machineId = "ed6bef3921544c24bb9a0a94f8252fd2"

-- Swap UUID (from blkid, used for resume=)
let swapUUID = "6e9a97e2-44b0-4a14-922b-26ced14feed6"

let config
    : BootGeneration
    = { generation = 0
      , description = "Rocky 10.1 stock (ELRepo kernel-ml 6.19.5, known-good)"
      , bootEntry =
        { title = "Rocky Linux (6.19.5-1.el10.elrepo.x86_64) 10.1 (Red Quartz)"
        , version = "6.19.5-1.el10.elrepo.x86_64"
        , linux = "/vmlinuz-6.19.5-1.el10.elrepo.x86_64"
        , initrd = [ "/initramfs-6.19.5-1.el10.elrepo.x86_64.img" ]
        , options =
                "ro crashkernel=2G-64G:256M,64G-:512M"
            ++  " resume=UUID=${swapUUID}"
            ++  " rd.lvm.lv=rl00/root rd.lvm.lv=rl00/swap"
            ++  " amdgpu.modeset=1 amdgpu.dc=1 amdgpu.dcdebugmask=0x10"
        , machineId = machineId
        , grubClass = Some "kernel"
        }
      , grubDefaults =
        { cmdlineDefault =
                "crashkernel=2G-64G:256M,64G-:512M"
            ++  " resume=UUID=${swapUUID}"
            ++  " rd.lvm.lv=rl00/root rd.lvm.lv=rl00/swap"
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
        [ { device = "UUID=a0fbfd79-13cf-4e84-9029-0ed99b9298f8"
          , mountPoint = "/"
          , fsType = "xfs"
          , options = "defaults"
          , dump = 0
          , pass = 0
          }
        , { device = "UUID=a82f9c0e-cc5a-4b8d-9227-c76078cef62b"
          , mountPoint = "/boot"
          , fsType = "xfs"
          , options = "defaults"
          , dump = 0
          , pass = 0
          }
        , { device = "UUID=C7D0-7769"
          , mountPoint = "/boot/efi"
          , fsType = "vfat"
          , options = "umask=0077,shortname=winnt"
          , dump = 0
          , pass = 2
          }
        , { device = "UUID=12691d58-f008-4808-868f-8a932aa87134"
          , mountPoint = "/home"
          , fsType = "xfs"
          , options = "defaults"
          , dump = 0
          , pass = 0
          }
        , { device = "/dev/mapper/data-containers"
          , mountPoint = "/var/lib/rancher"
          , fsType = "xfs"
          , options = "defaults"
          , dump = 0
          , pass = 0
          }
        , { device = "/dev/mapper/data-bci"
          , mountPoint = "/data"
          , fsType = "xfs"
          , options = "defaults"
          , dump = 0
          , pass = 0
          }
        , { device = "/dev/mapper/hdd-archive"
          , mountPoint = "/archive"
          , fsType = "xfs"
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
