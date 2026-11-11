# MeloNX RAM bridge for LiveContainer

Lets [MeloNX](https://starforgejo.dev/projects/MeloNX) 2.7's RAM limit workaround run while MeloNX is installed inside [LiveContainer](https://github.com/LiveContainer/LiveContainer).

> **Status: untested on a real iPhone.** It passes the Mac test below, but nobody has confirmed it on a device yet.

## Background

iOS gives each process its own memory limit. MeloNX 2.7 gets around this by storing the emulated Switch's RAM (guest RAM) in up to 4 helper processes, called donors. Each donor has its own limit, and the shared memory doesn't count against MeloNX's own limit. See `MLXRamDonor.m` in the MeloNX source.

Inside LiveContainer this fails. MeloNX isn't really installed, so iOS doesn't know about its `MeloNXRamDonor` extension and can't launch it.

## How the bridge works

LiveContainer ships an extension called `LiveProcess`. It has the same extension type as MeloNX's donor, allows several copies at once, and can load custom code through `customPayloadDylib`. `MeloNXDonorBridge.dylib` uses it in two ways.

- **Inside MeloNX:** requests for the `RamDonor` extension are redirected to `LiveProcess`, along with this dylib's path and entry point. If LiveContainer has removed MeloNX's `PlugIns` folder, MeloNX is still told a donor exists.
- **Inside `LiveProcess`:** `MLXDonorPayloadMain` answers the same XPC protocol as MeloNX's own donor.

MeloNX itself isn't changed. Other apps in LiveContainer don't get extra memory, because only MeloNX has code to request and use donor memory.

The dylib is loaded through a weak `LC_LOAD_WEAK_DYLIB` command added to `LiveContainerShared.framework`. That framework loads from the real app bundle at launch, in both the main app and `LiveProcess`. `TweakLoader.dylib` won't work for this, because guests load it through a symlink in `Documents/Tweaks`. `@executable_path` won't work either, because LiveContainer points it at the guest.

## Files

| File | Purpose |
|---|---|
| `MeloNXDonorBridge.m` | The bridge: redirect hooks and donor |
| `add_weak_dylib.py` | Adds a weak dylib load command to an arm64 Mach-O |
| `patch_ipa.sh` | Builds the bridge and adds it to a LiveContainer IPA |
| `test/harness.m`, `test/run_tests.sh` | Mac test against MeloNX's real donor code |
| `upstream/` | MeloNX's `MLXRamDonor` files, used only by the test |

## Patching an IPA

You need macOS, Xcode and an iOS SDK.

```bash
./patch_ipa.sh LiveContainer+SideStore.ipa LiveContainer+SideStore-MeloNXDonor.ipa /tmp/lc-patch-work
```

The input IPA isn't changed. The output is ad-hoc signed, and your sideloader (SideStore, Impactor and similar) replaces that signature when you install it. No new extension is added, so it doesn't need another App ID.

Only the official LiveContainer IPA is recommended as input. This patch was first tried on a modified 3.8.10 build, which hasn't been audited.

## Using it

1. Sideload the patched LiveContainer. `LiveProcess` needs the Increased Memory Limit entitlement for donors to be useful.
2. Install **MeloNX 2.7 or later** inside LiveContainer. Earlier versions have no donor code.
3. Launch MeloNX normally, not in multitask mode, which may not work. JIT is still needed.
4. Leave **Donate Guest RAM** on in MeloNX's settings.
5. Start a game, and look for a `Guest RAM:` line in MeloNX's log.

The bridge writes a log to `Documents/MeloNXDonorBridge.log` in MeloNX's LiveContainer data. If donors can't start, MeloNX falls back to normal memory.

## Testing

```bash
./test/run_tests.sh
```

This builds the bridge for macOS and runs MeloNX's real `MLXRamDonor.m` against it. `NSExtension` is faked, so each donor runs as a thread instead of a process. It checks the redirect, the payload keys, the XPC protocol, a 3 GB request across 3 donors, and that the memory is really shared.

It can't check that iOS lets a LiveContainer guest launch `LiveProcess`, that the dylib loads after sideloading, real memory limits, or jetsam behaviour. Those need a device.

## License

GPLv3, because the donor code and protocol come from MeloNX, which is GPLv3. See `LICENSE`. MeloNX is by Stossy11 and its contributors. LiveContainer is a separate project with its own license, and none of its code is included here.
