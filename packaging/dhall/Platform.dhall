-- Platform.dhall — Type-safe hardware platform definitions
--
-- Defines the Dell T7810 (Grantley/Wellsburg) platform characteristics
-- discovered via firmware RE of BIOS A34. Used to generate:
--   - Kernel config fragments (scripts/config calls)
--   - Boot parameters (grubby / BLS entries)
--   - tuned profiles
--   - SMI validation thresholds

let SMISource =
      { name : Text
      , smiEnBit : Natural
      , biosDisable : Optional Text
      , kernelParam : Optional Text
      , risk : Text
      , description : Text
      }

let PCH =
      { name : Text
      , codename : Text
      , acpiBase : Natural
      , smiEnPort : Natural
      , smiStsPort : Natural
      , smiSources : List SMISource
      }

let CPU =
      { name : Text
      , codename : Text
      , sockets : Natural
      , coresPerSocket : Natural
      , threadsPerCore : Natural
      , tscReliable : Bool
      , tscDeadlineErrata : Bool
      , microcodeFixBios : Text
      }

let Platform =
      { name : Text
      , vendor : Text
      , model : Text
      , boardId : Text
      , biosVersion : Text
      , biosSha256 : Text
      , pch : PCH
      , cpu : CPU
      , ramGiB : Natural
      , gpu : Text
      , firmwareModules :
          { total : Natural
          , dxeDrivers : Natural
          , smmHandlers : Natural
          , peiModules : Natural
          }
      }

let wellsburg
    : PCH
    = { name = "Intel C610/C612"
      , codename = "Wellsburg"
      , acpiBase = 0x0400
      , smiEnPort = 0x0430
      , smiStsPort = 0x0434
      , smiSources =
        [ { name = "USB Legacy 1.1"
          , smiEnBit = 3
          , biosDisable = Some "Disable USB Legacy Support"
          , kernelParam = None Text
          , risk = "CRITICAL"
          , description = "EHCI legacy emulation — 24 refs in PCH dispatcher"
          }
        , { name = "APMC (Software SMI)"
          , smiEnBit = 5
          , biosDisable = None Text
          , kernelParam = None Text
          , risk = "HIGH"
          , description = "Software SMI port — used by Dell SMBIOS DA/CI"
          }
        , { name = "TCO Watchdog"
          , smiEnBit = 13
          , biosDisable = None Text
          , kernelParam = None Text
          , risk = "MEDIUM"
          , description = "TCO watchdog timer — disable via CONFIG_TCO_WATCHDOG=n"
          }
        , { name = "Periodic Timer"
          , smiEnBit = 14
          , biosDisable = None Text
          , kernelParam = None Text
          , risk = "MEDIUM"
          , description = "Periodic SMI timer — Dell Smart Timer uses this"
          }
        , { name = "USB Legacy 2.0"
          , smiEnBit = 17
          , biosDisable = Some "Disable USB Legacy Support"
          , kernelParam = None Text
          , risk = "CRITICAL"
          , description = "xHCI legacy emulation — 33 refs in PCH dispatcher"
          }
        ]
      }

let haswellEP
    : CPU
    = { name = "Xeon E5-2630 v3"
      , codename = "Haswell-EP"
      , sockets = 2
      , coresPerSocket = 8
      , threadsPerCore = 2
      , tscReliable = True
      , tscDeadlineErrata = True
      , microcodeFixBios = "A34"
      }

let dellT7810
    : Platform
    = { name = "honey"
      , vendor = "Dell"
      , model = "Precision Tower 7810"
      , boardId = "0GWHMW"
      , biosVersion = "A34"
      , biosSha256 =
          "6a1c9a01683453881c610c5771fb225a024b1b2122da0cf6f95a43e870a77ff9"
      , pch = wellsburg
      , cpu = haswellEP
      , ramGiB = 220
      , gpu = "AMD Radeon RX 9070 XT (Navi 48 / RDNA4)"
      , firmwareModules =
          { total = 497, dxeDrivers = 270, smmHandlers = 153, peiModules = 72 }
      }

in  { Platform, PCH, CPU, SMISource, dellT7810, wellsburg, haswellEP }
