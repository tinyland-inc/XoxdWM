-- BootParams.dhall — Generate kernel boot parameters from platform definition
--
-- Composes RT-safe boot parameters based on:
--   - PCH SMI characteristics (from firmware RE)
--   - CPU errata (TSC-deadline, C-state behavior)
--   - Workload requirements (BCI isolation, VR frame timing)

let Platform = (./Platform.dhall).Platform

let Workload =
      { name : Text
      , isolatedCores : Text
      , housekeepingCores : Text
      , requireRT : Bool
      , requireTSC : Bool
      , idlePoll : Bool
      }

let bciWorkload
    : Workload
    = { name = "BCI/VR"
      , isolatedCores = "2-7"
      , housekeepingCores = "0-1"
      , requireRT = True
      , requireTSC = True
      , idlePoll = True
      }

let smiMitigationParams =
      \(platform : Platform) ->
        let base =
              [ "tsc=nowatchdog"
              , "nosoftlockup"
              , "intel_pstate=disable"
              , "processor.max_cstate=1"
              , "intel_idle.max_cstate=0"
              , "nmi_watchdog=0"
              , "mce=ignore_ce"
              ]

        let tscParam =
              if    platform.cpu.tscReliable
              then  [ "clocksource=tsc" ]
              else  [ "clocksource=hpet" ]

        in  base # tscParam

let workloadParams =
      \(w : Workload) ->
        let isolation =
              [ "isolcpus=managed_irq,domain,${w.isolatedCores}"
              , "nohz_full=${w.isolatedCores}"
              , "rcu_nocbs=${w.isolatedCores}"
              , "irqaffinity=${w.housekeepingCores}"
              ]

        let idle = if w.idlePoll then [ "idle=poll" ] else [] : List Text

        in  isolation # idle

let hardwareParams =
      [ "amdgpu.modeset=1"
      , "amdgpu.dc=1"
      , "amdgpu.dcdebugmask=0x10"
      ]

let debugParams =
      [ "earlyprintk=vga,keep"
      , "ignore_loglevel"
      , "initcall_debug"
      , "nosmp"
      , "nosoftlockup"
      ]

let allParams =
      \(platform : Platform) ->
        \(workload : Workload) ->
          let smi = smiMitigationParams platform

          let work = workloadParams workload

          in  smi # work # hardwareParams

in  { Workload
    , bciWorkload
    , smiMitigationParams
    , workloadParams
    , hardwareParams
    , debugParams
    , allParams
    }
