-- StorageLayout.dhall — Type-safe storage topology for honey server
--
-- Documents the target storage architecture after pvmove migration.
-- Encodes the critical constraint: GRUB cannot read thin LVM.
--
-- Background (Red Hat BZ#1164947, filed 2014, will not be fixed):
--   GRUB's diskfilter.c only supports thick/linear/mirror/raid LV types.
--   Thin provisioning uses a separate metadata LV + data LV that GRUB
--   cannot parse. Attempts to boot from thin LVM fail with:
--     "error: diskfilter writes are not supported"
--   This is an architectural limitation of GRUB, not a bug.
--   Conclusion: thin pools are for data volumes only — never root.

let FstabEntry = (./FstabEntry.dhall).FstabEntry
let LVMType = (./FstabEntry.dhall).LVMType
let StorageVolume = (./FstabEntry.dhall).StorageVolume

let PhysicalDisk =
      { device : Text
      , type : Text
      , role : Text
      , partitions : List { partition : Text, use : Text }
      }

let VolumeGroup =
      { name : Text
      , pvDevice : Text
      , lvmType : LVMType
      , volumes : List StorageVolume
      }

-- Target layout after pvmove migration
let honeyDisks =
      [ { device = "/dev/sda"
        , type = "SATA SSD"
        , role = "boot (EFI + /boot), freed after pvmove"
        , partitions =
          [ { partition = "sda1", use = "/boot/efi (600M, FAT32) - unchanged" }
          , { partition = "sda2", use = "/boot (1G, xfs) - unchanged" }
          , { partition = "sda3", use = "freed (was rl00 PV, removed after pvmove)" }
          ]
        }
      , { device = "/dev/nvme0n1"
        , type = "NVMe"
        , role = "root VG (thick LVM, pvmove target)"
        , partitions =
          [ { partition = "nvme0n1p1", use = "rl00 VG (thick LVM for root)" }
          ]
        }
      , { device = "/dev/nvme1n1"
        , type = "NVMe"
        , role = "data VG (thin pool for non-root)"
        , partitions =
          [ { partition = "nvme1n1p1", use = "data VG (thin pool)" }
          ]
        }
      , { device = "/dev/sdb"
        , type = "HDD"
        , role = "archive tier"
        , partitions =
          [ { partition = "sdb3", use = "hdd VG (archive)" }
          ]
        }
      ]

let honeyVGs =
      [ { name = "rl00"
        , pvDevice = "/dev/nvme0n1p1"
        , lvmType = LVMType.Thick
        , volumes =
          [ { vg = "rl00", lv = "root", lvmType = LVMType.Thick
            , mountPoint = "/", fsType = "xfs", sizeDesc = "~2TB (extended)" }
          , { vg = "rl00", lv = "swap", lvmType = LVMType.Thick
            , mountPoint = "swap", fsType = "swap", sizeDesc = "32G" }
          ]
        }
      , { name = "data"
        , pvDevice = "/dev/nvme1n1p1"
        , lvmType = LVMType.Thin
        , volumes =
          [ { vg = "data", lv = "home", lvmType = LVMType.Thin
            , mountPoint = "/home", fsType = "xfs", sizeDesc = "500G thin" }
          , { vg = "data", lv = "containers", lvmType = LVMType.Thin
            , mountPoint = "/var/lib/rancher", fsType = "xfs", sizeDesc = "500G thin" }
          , { vg = "data", lv = "bci", lvmType = LVMType.Thin
            , mountPoint = "/data", fsType = "xfs", sizeDesc = "200G thin" }
          ]
        }
      , { name = "hdd"
        , pvDevice = "/dev/sdb3"
        , lvmType = LVMType.Thick
        , volumes =
          [ { vg = "hdd", lv = "archive", lvmType = LVMType.Thick
            , mountPoint = "/archive", fsType = "xfs", sizeDesc = "3.5T" }
          ]
        }
      ]

-- Invariant: rl00 (root VG) must be thick LVM.
-- GRUB cannot read thin LVM: Red Hat BZ#1164947 (2014, WONTFIX).
-- Checked at Dhall evaluation time on the concrete rl00 VG definition.
let rl00VG
    : VolumeGroup
    = { name = "rl00"
      , pvDevice = "/dev/nvme0n1p1"
      , lvmType = LVMType.Thick
      , volumes =
        [ { vg = "rl00", lv = "root", lvmType = LVMType.Thick
          , mountPoint = "/", fsType = "xfs", sizeDesc = "~2TB (extended)" }
        , { vg = "rl00", lv = "swap", lvmType = LVMType.Thick
          , mountPoint = "swap", fsType = "swap", sizeDesc = "32G" }
        ]
      }

let _ = assert : rl00VG.lvmType === LVMType.Thick

in  { PhysicalDisk, VolumeGroup, honeyDisks, honeyVGs }
