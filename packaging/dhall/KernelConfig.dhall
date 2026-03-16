-- KernelConfig.dhall — Generate kernel config fragments from platform definition
--
-- Outputs scripts/config commands for the RPM spec's %prep section.
-- Separates concerns:
--   - XR config: display, HID, VR hardware support
--   - RT config: preemption model, timer resolution
--   - SMI config: disable kernel features that trigger SMIs
--   - BCI config: high-resolution timers, CPU isolation support

let Action = < enable | disable | set-val | set-str >

let ConfigEntry =
      { Type = { key : Text, value : Text, action : Action }
      , default = { value = "", action = Action.enable }
      }

let enable = \(key : Text) -> { key, value = "", action = Action.enable }

let disable = \(key : Text) -> { key, value = "", action = Action.disable }

let setVal =
      \(key : Text) -> \(value : Text) -> { key, value, action = Action.set-val }

let setStr =
      \(key : Text) -> \(value : Text) -> { key, value, action = Action.set-str }

let xrConfig =
      [ enable "CONFIG_DRM_AMD_DC_DSC"
      , enable "CONFIG_DRM_AMD_DC_FP"
      , enable "CONFIG_USB_HIDDEV"
      , enable "CONFIG_HID_GENERIC"
      , enable "CONFIG_USB_VIDEO_CLASS"
      , enable "CONFIG_DRM"
      , setVal "CONFIG_HZ" "1000"
      , enable "CONFIG_HZ_1000"
      , disable "CONFIG_HZ_250"
      ]

let rtConfig =
      [ enable "CONFIG_PREEMPT_RT"
      , disable "CONFIG_PREEMPT_VOLUNTARY"
      , disable "CONFIG_PREEMPT_NONE"
      , enable "CONFIG_HIGH_RES_TIMERS"
      , enable "CONFIG_NO_HZ_FULL"
      , enable "CONFIG_RCU_NOCB_CPU"
      , enable "CONFIG_IRQ_FORCED_THREADING"
      ]

let smiMitigationConfig =
      [ -- Disable TCO watchdog to eliminate TCO_EN SMIs
        disable "CONFIG_TCO_WATCHDOG"
        -- Disable i2c-i801 SMBus (generates SMIs on Wellsburg)
      , disable "CONFIG_I2C_I801"
        -- Enable TSC watchdog bypass (prevent false unstable marking)
      , enable "CONFIG_X86_TSC"
        -- Disable iTCO_wdt (Intel TCO Watchdog Timer)
      , disable "CONFIG_ITCO_WDT"
        -- Enable hwlat tracer for SMI characterization
      , enable "CONFIG_HWLAT_TRACER"
        -- Enable MSR access for SMI_COUNT (MSR 0x34) reading
      , enable "CONFIG_X86_MSR"
        -- Enable Dell Remote BIOS Update driver (Linux-native BIOS updates)
      , enable "CONFIG_DELL_RBU"
        -- Enable tracer snapshot for latency capture
      , enable "CONFIG_TRACER_SNAPSHOT"
      ]

let bciConfig =
      [ -- High-precision timers for sample clock sync
        enable "CONFIG_HIGH_RES_TIMERS"
        -- CPU isolation support
      , enable "CONFIG_CPU_ISOLATION"
        -- POSIX timers for AD/DA timing
      , enable "CONFIG_POSIX_TIMERS"
        -- Tickless idle on isolated cores
      , enable "CONFIG_NO_HZ_FULL"
        -- Offload RCU callbacks
      , enable "CONFIG_RCU_NOCB_CPU"
        -- Memory-mapped I/O for BCI devices
      , enable "CONFIG_UIO"
      , enable "CONFIG_UIO_PCI_GENERIC"
      ]

let renderEntry =
      \(entry : { key : Text, value : Text, action : Action }) ->
        merge
          { enable = "scripts/config --enable ${entry.key}"
          , disable = "scripts/config --disable ${entry.key}"
          , set-val = "scripts/config --set-val ${entry.key} ${entry.value}"
          , set-str = "scripts/config --set-str ${entry.key} ${entry.value}"
          }
          entry.action

in  { Action
    , ConfigEntry
    , enable
    , disable
    , setVal
    , setStr
    , xrConfig
    , rtConfig
    , smiMitigationConfig
    , bciConfig
    , renderEntry
    }
