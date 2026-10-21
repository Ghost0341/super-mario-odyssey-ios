# Signing and installation

Follow the numbered steps at the bottom of README.md first. The normal command
uses Xcode's signed-in Apple account to obtain an exact-app **development** profile:

```sh
python tools/sign_install.py --ipa /path/to/Odyssey-unsigned.ipa \
  --team YOUR_TEAM_ID --device YOUR_DEVICE_ID --install
```

It extracts the private IPA beside it, signs a separate copy, verifies the
signature and entitlements, exports a signed IPA and optionally installs the
app. It never deletes or launches an installed game. Its private signing work
directory contains the provisioning material and receipt; do not publish it.
Use a new `--output` path when signing again; existing files are not overwritten.

The signing helper supports only development profiles. The provisioning profile
must allow the exact bundle ID, the intended UDID, and Increased Memory Limit,
and its certificate/private key must be in the Mac's Keychain. This is the
[normal memory entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit),
not the separate Increased Debugging Memory Limit entitlement. The latter is not
used here. More RAM permission does not guarantee every device has enough RAM.

## Profile setup

If automatic provisioning fails:

1. In Xcode Settings → Apple Accounts, confirm the correct developer team is
   signed in and has a development certificate.
2. In [Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list),
   create/select an explicit App ID matching the bundle ID passed to the build.
3. Enable **Increased Memory Limit** for that App ID. If using cloud saves, also
   enable **iCloud → CloudKit** and associate your container (docs/ICLOUD.md).
4. Register the device's **UDID** under Devices. `devicectl` also displays a
   CoreDevice identifier; if using the developer website, copy the hardware UDID
   from Xcode's device details, not a different local identifier.
5. Create an **iOS App Development** profile for that App ID, your development
   certificate, and the devices. Download it outside the source checkout.
6. Rerun with the profile:

   ```sh
   python tools/sign_install.py --ipa /path/to/Odyssey-unsigned.ipa \
     --profile /path/to/Odyssey.mobileprovision \
     --device YOUR_HARDWARE_UDID --install
   ```

For automatic signing, pass the hardware UDID too so profile validation can
confirm it. `xcrun devicectl device info details --device DEVICE_ID` shows the
hardware details if the summary list only shows a CoreDevice identifier.

## Common problems

| Problem | Next step |
| --- | --- |
| Missing .NET 10 | Install the .NET 10 SDK/runtime; a newer major runtime alone cannot run the pinned translator. |
| Xcode license/components missing | Open Xcode once, accept the license and finish component installation. |
| No Apple account/provisioning permission | Sign in in Xcode, select the correct team, and check the private `provision.log`. |
| Memory entitlement absent | Enable Increased Memory Limit for your explicit App ID and regenerate the profile. Free-team support is not verified. |
| Device not in profile | Register its hardware UDID and regenerate the development profile. |
| Device locked/unavailable | Unlock it, trust the Mac, enable Developer Mode and keep it awake. USB is best for the large first install. |
| Wrong game version/hash | Use the unmodified base game plus update 1.4.1; see INPUTS.md. |
| Black screen / app exits | Check device memory, iOS version and `log.txt`. Older/lower-memory devices are unverified. |
| Output already exists | Use a new signed output filename. Keep a backup before cleaning old private build folders. |

Apple documents [Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
and [installation on registered devices](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices).

## Installing on a friend's device

A development-signed IPA runs only on devices in its provisioning profile.
Register the additional phone, sign again with a profile containing it, and
install using the Mac helper, Xcode, or Apple Configurator. Sending the file by
AirDrop alone does not install it. The friend can also build/sign independently
using their own files and account. Don't commit or publish the resulting game IPA.

Ad hoc distribution is a separate signing flow requiring a distribution
certificate/profile and registered devices; this helper doesn't implement it.
Do not simply change a Development CloudKit entitlement to Production: cloud
environments store different data, and production requires a deployed schema.
