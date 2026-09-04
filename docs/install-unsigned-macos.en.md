# Open unsigned Solnari on macOS for the first time

The current public preview DMG is not signed with an Apple Developer ID or notarized by Apple.
macOS therefore warns that it cannot check Solnari for malicious software. The procedure below does
not disable the warning or weaken system-wide security. It creates an exception only for the one
Solnari app that you have reviewed.

If you are not comfortable creating that exception, do not run the DMG. Review and build the source
instead. Download builds only from the [official Solnari Releases page](https://github.com/dreamyoungs/solnari/releases)
and verify the published SHA-256 file when one is provided.

## 1. Copy the app from the DMG

Open the DMG and drag **Solnari** onto the **Applications** folder on the right.

![Solnari DMG window with an arrow from the app to the Applications folder](images/install/dmg-install.png)

To verify a published checksum from Terminal, place the DMG and its `.sha256` file in the same
folder, then run the following command. Do not open the DMG unless the result says `OK`.

```bash
shasum -a 256 -c Solnari-0.2.1-macos-arm64-unsigned.dmg.sha256
```

## 2. Acknowledge the first-launch warning

Try to launch Solnari once from Applications. When the warning below appears, click **Done**. Do not
choose **Move to Bin** unless you intend to delete the app.

![macOS first-launch warning saying Apple cannot check Solnari for malicious software](images/install/first-launch-warning.png)

This warning appears because the current build is not Developer ID-signed or notarized. Stop if the
app name or download source is not what you expected.

## 3. Allow this app once in Privacy & Security

Open **System Settings → Privacy & Security**, then scroll down to **Security**. Find the message
saying Solnari was blocked to protect your Mac and click **Open Anyway**.

![Security section of Privacy & Security showing the Open Anyway button for Solnari](images/install/privacy-security-open-anyway.png)

Authenticate with your password or Touch ID. In the final confirmation, verify that the app is
named **Solnari**, then click **Open Anyway**. Some macOS versions label this button **Open**.

![Korean macOS final confirmation asking whether to open Solnari and showing Open Anyway](images/install/final-open-confirmation.png)

You can subsequently open this copy like any authorized app.
The **Open Anyway** entry is available for about one hour after the failed launch attempt.

Do not use Terminal commands that disable Gatekeeper globally or enable apps from every source.
Apple likewise recommends applying an exception only after checking the app's source and integrity.

## Verified environment

- Screenshots and procedure verified on macOS 26.6.2 (build 25G83), 2026-09-04
- Solnari supports macOS 14 or newer
- Apple guidance: [Safely open apps on your Mac](https://support.apple.com/en-us/102445) and
  [Open an app by overriding security settings](https://support.apple.com/guide/mac-help/mh40617/mac)

Button labels and locations can vary slightly by macOS version and display language. If your flow
differs, do not lower security settings; consult Apple's current guidance first.
