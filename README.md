<p align="center"><img src="icon.png" alt="ShamanKit icon" width="128" height="128"></p>

# ShamanKit

Small helpers for shamans, for World of Warcraft: Forever, in the default UI style.

- **Totem bar**: each active totem with its time left and whether you are in range of it. Can replace the default
  totem timers under the player frame. Right-click a totem to dismiss it. With the bar locked, left-click a place to cast
  the totem it shows (the dim placeholder of a kept place, or a totem that is out), also in a fight; it can be switched off.
- **Buffs**: two small optional icons. The weapon icon either pops up when your weapon has no enchant (or one that is
  about to run out), or, if you prefer, shows which enchant is on and its time left, like the shield icon (main hand,
  hidden when dead, with no weapon or a fishing pole). The other icon shows your Lightning Shield charges while it is up. They can hang on the totem bar or the player frame (any side, any alignment, nudge and size are settings)
  or sit in a place of their own that you drag.
- **Cures**: Cure Disease (tan), Cure Poison (green) and, for an Orc, Shatter Curse (purple) light up, on the action bar
  buttons that hold them and in an optional small icon row, while a debuff they can remove is on you. The game draws the
  highlight (an aura container), so it works in a fight too. Click a lit icon in the row to cast that cure on yourself (also in a fight; off with the frames unlocked or in settings). Own settings page; it can be switched off. Replaces the
  separate CureWatch addon (ShamanKit stays off while CureWatch is installed).

Settings: Esc > Options > AddOns > ShamanKit (a home page and four pages: Totem bar, Totems, Buffs, Cures), or `/shamankit`.
`/shamankit buffs` (or `bar`, `totems`, `cures`) opens a page, `/shamankit cures test` lights the cures for a few seconds, `/shamankit lock | unlock` locks or unlocks the frames,
`/shamankit reset` puts the bar and the icons back in their usual place, and `/shamankit status` prints what the addon
reads for the totems and the buff icons. `/totemrange` still works too.

## Install and update (wowupd)

Install it with the `wowupd` addon manager, which then keeps it updated: `wowupd add https://github.com/shrimptec/ShamanKit`
(or *Add addon...* in the wowupd window). No account or token is needed. Restart the game after the first install;
later updates need only `/reload`. Without wowupd: download `ShamanKit-v<version>-forever.zip` from the latest
release and unzip it into `World of Warcraft/_forever_/Interface/AddOns/`.

## Coming from TotemRange

ShamanKit is the new name of TotemRange. It is a separate addon folder with its own saved settings, so remove the old
`TotemRange` folder (`wowupd remove TotemRange`) before you start the game with ShamanKit, or both will run. Your old
settings are not picked up automatically: in `WTF/Account/<account>/SavedVariables/`, copy `TotemRange.lua` to
`ShamanKit.lua` and change the first word inside it from `TotemRangeDB` to `ShamanKitDB` while the game is closed.

## Publishing a change (for the maintainer)

```
./release.sh patch "what changed"      # patch | minor | major | X.Y.Z
```

Runs the checks, bumps `## Version:`, builds `dist/ShamanKit-vX.Y.Z-forever.zip`, commits, tags, pushes and
creates the GitHub release, then downloads it back and compares. Tag, `.toc` version and zip name always match,
which is what wowupd compares. `./install.sh` copies the working tree into the local game folder for testing.
Tests: `luajit t/harness.lua`.
