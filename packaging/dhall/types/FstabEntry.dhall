-- FstabEntry.dhall — /etc/fstab entry type
--
-- Type-safe fstab line representation. Enforces that root must always
-- be on thick LVM (never thin), per Red Hat BZ#1164947.

let FstabEntry =
      { device : Text
      , mountPoint : Text
      , fsType : Text
      , options : Text
      , dump : Natural
      , pass : Natural
      }

let render =
      \(entry : FstabEntry) ->
            entry.device
        ++  "\t"
        ++  entry.mountPoint
        ++  "\t"
        ++  entry.fsType
        ++  "\t"
        ++  entry.options
        ++  "\t"
        ++  Natural/show entry.dump
        ++  " "
        ++  Natural/show entry.pass

let LVMType = < Thick | Thin >

let StorageVolume =
      { vg : Text
      , lv : Text
      , lvmType : LVMType
      , mountPoint : Text
      , fsType : Text
      , sizeDesc : Text
      }

in  { FstabEntry, render, LVMType, StorageVolume }
