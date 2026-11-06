# WinUSB for macOS

Makes a bootable Windows 10 / 11 installer USB drive from an ISO on macOS, similar to what Rufus does on Windows.

## How it works
1. Erases the USB drive as **FAT32** with an MBR or GPT partition map (`diskutil`). Only external, non-internal disks are listed.
2. Mounts the ISO read-only (`hdiutil`) and copies every file to the drive, with progress shown.
3. If `sources/install.wim` is bigger than FAT32's 4 GB file limit, splits it into `install.swm`, `install2.swm`, … using the bundled **wimlib**. Windows Setup reads split files without any extra steps.
4. Optional Windows 11 tweaks, written as `autounattend.xml`:
   - skip the TPM 2.0 / Secure Boot / RAM / CPU checks
   - allow setup without a Microsoft account
   - create a local account
   - skip the privacy questions
5. Removes macOS `._*` metadata files, then ejects the drive.

The drive boots on **UEFI** machines (every PC that can run Windows 11). Booting on older legacy-BIOS machines is not supported.

## Build
```bash
brew install wimlib          # gets bundled into the app
./scripts/build-app.sh       # -> build/WinUSB.app
```

## CLI
```bash
build/WinUSB.app/Contents/MacOS/winusb-cli list
build/WinUSB.app/Contents/MacOS/winusb-cli info Win11.iso
build/WinUSB.app/Contents/MacOS/winusb-cli write Win11.iso disk4 --bypass-checks --bypass-online
```

## Roadmap
- [ ] **Legacy BIOS boot support**: write Windows-compatible MBR boot code and a FAT32 boot sector (as Rufus does via ms-sys), so the stick also boots on old non-UEFI PCs
- [ ] NTFS/exFAT + UEFI:NTFS mode, so `install.wim` doesn't need splitting
- [ ] Verify written files against the ISO (checksum pass)
- [ ] Download Windows ISOs from inside the app
- [ ] Signed and notarized releases (DMG)
