# Installation screenshot maintenance

These screenshots document the unsigned preview flow. Refresh them when the DMG design changes,
when the minimum supported macOS release changes, or when Apple changes Gatekeeper wording.

Required files:

1. `dmg-install.png` — final branded DMG with release-style volume name.
2. `first-launch-warning.png` — the initial warning for a quarantined unsigned build.
3. `privacy-security-open-anyway.png` — only the Security card containing the Solnari exception.
4. `final-open-confirmation.png` — the last confirmation after authentication.

Capture at Retina resolution on a clean macOS account using a disposable Solnari build. Before
committing, inspect every image at full size and remove or recapture anything containing account
names, filesystem paths, notifications, unrelated apps, database names, hosts, usernames, project
identifiers, queries, or results. Crop by capturing only the target window or screen region; do not
blur sensitive data into an otherwise reusable source image.

Update the verified macOS version and capture date in both installation guides. Confirm the flow
against Apple's current support documentation, verify image alt text, and test every relative link.
Never weaken Gatekeeper globally just to refresh screenshots.
