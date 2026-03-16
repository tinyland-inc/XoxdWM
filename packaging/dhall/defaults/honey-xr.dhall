-- honey-xr.dhall — XR kernel boot configuration
--
-- Adds RT boot parameters, SMI mitigation, and CPU isolation to the
-- stock config. Used when installing kernel-xr on honey.

let BootEntry = (../types/BootEntry.dhall).BootEntry
let GrubDefaults = (../types/GrubDefaults.dhall).GrubDefaults
let DracutConfig = (../types/DracutConfig.dhall).DracutConfig
let FstabEntry = (../types/FstabEntry.dhall).FstabEntry
let BootGeneration = (../types/BootGeneration.dhall).BootGeneration

let stock = ./honey-stock.dhall

-- Boot parameters composed from BootParams.dhall logic, but rendered
-- as a single string for the BLS entry.
let xrOptions =
        "root=/dev/mapper/rl00-root ro"
    ++  " rd.lvm.lv=rl00/root rd.lvm.lv=rl00/swap"
    ++  " crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M"
    ++  " resume=/dev/mapper/rl00-swap"
    -- SMI mitigation (from firmware RE of T7810 BIOS A34)
    ++  " tsc=nowatchdog clocksource=tsc nosoftlockup"
    ++  " intel_pstate=disable processor.max_cstate=1 intel_idle.max_cstate=0"
    ++  " nmi_watchdog=0 mce=ignore_ce"
    -- CPU isolation (BCI workload: cores 2-7 isolated)
    ++  " isolcpus=managed_irq,domain,2-7 nohz_full=2-7 rcu_nocbs=2-7"
    ++  " irqaffinity=0-1 idle=poll skew_tick=1 rcu_nocb_poll"
    ++  " nowatchdog kthread_cpus=0-1"
    -- GPU
    ++  " amdgpu.modeset=1 amdgpu.dc=1 amdgpu.dcdebugmask=0x10"

let config
    : BootGeneration
    = { generation = 1
      , description = "XR kernel with RT params + SMI mitigation"
      , bootEntry =
        { title = "Rocky Linux (XR kernel) 10.1 (Coughlan)"
        , version = "6.19.5-1.xr.el10.x86_64"
        , linux = "/vmlinuz-6.19.5-1.xr.el10.x86_64"
        , initrd = [ "/initramfs-6.19.5-1.xr.el10.x86_64.img" ]
        , options = xrOptions
        , machineId = "honey"
        , grubClass = Some "kernel"
        }
      , grubDefaults = stock.grubDefaults
          // { cmdlineDefault = xrOptions }
      , dracutConfig =
        { name = "xr"
        , addDrivers = [ "nvme", "nvme_core", "amdgpu", "uio", "uio_pci_generic" ]
        , addModules = [ "lvm" ]
        , omitDrivers = [ "iTCO_wdt", "i2c_i801" ]
        , hostonly = True
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
