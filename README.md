# TotemRange

World of Warcraft: Forever addon. Shows each active totem with its time left and whether you are in
range of it, in the default UI style. Can replace the default totem timers under the player frame.
Settings: Esc > Options > AddOns > TotemRange, or `/totemrange`.

Two optional small icons sit under the totem bar (or free-standing, drag them when the frame is unlocked):
**weapon enchant missing / running out** (main hand; hidden when dead, with no weapon or a fishing pole) and
**Lightning Shield charges** (only while the shield is up). Both can be switched off in the settings.
`/totemrange status` prints what the addon reads for them.

## Install and update (wowupd)

Install it with the `wowupd` addon manager, which then keeps it updated: `wowupd add https://github.com/shrimptec/TotemRange`
(or *Add addon...* in the wowupd window). No account or token is needed. Restart the game after the first install;
later updates need only `/reload`. Without wowupd: download `TotemRange-v<version>-forever.zip` from the latest
release and unzip it into `World of Warcraft/_forever_/Interface/AddOns/`.

## Publishing a change (for the maintainer)

```
./release.sh patch "what changed"      # patch | minor | major | X.Y.Z
```

Runs the checks, bumps `## Version:`, builds `dist/TotemRange-vX.Y.Z-forever.zip`, commits, tags, pushes and
creates the GitHub release, then downloads it back and compares. Tag, `.toc` version and zip name always match,
which is what wowupd compares. `./install.sh` copies the working tree into the local game folder for testing.
Tests: `luajit t/harness.lua`.
