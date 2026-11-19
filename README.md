<p align="center"><img src="icon.png" alt="ShamanKit icon" width="128" height="128"></p>

# ShamanKit

Small helpers for shamans, for World of Warcraft: Forever, in the default UI style.

- **Totem bar**: each active totem with its time left and whether you are in range of it. A buff totem is judged by its buff when the game lets addons read it (out of a fight); otherwise by distance, and near the edge of the range it shows a yellow ? instead of guessing, because a totem lands a little to one side of you. This is the "Watch the totem's buff" option on the Totem bar page (on by default); off goes back to judging by your drop spot alone. Can replace the default
  totem timers under the player frame. Right-click a totem to dismiss it. With the bar locked, left-click a place to cast
  the totem it shows (the dim placeholder of a kept place, or a totem that is out), also in a fight; it can be switched off.
- **Buffs**: two small optional icons. The weapon icon either pops up when your weapon has no enchant (or one that is
  about to run out), or, if you prefer, shows which enchant is on and its time left, like the shield icon (main hand,
  hidden when dead, with no weapon or a fishing pole). The other icon shows your Lightning Shield charges while it is up. They can hang on the totem bar or the player frame (any side, any alignment, nudge and size are settings)
  or sit in a place of their own that you drag.
- **A narrower "?"**: your position is only an estimate of the distance to a totem, so close to its edge in a fight the
  icon shows a yellow ?. Each time you walk away from a totem out of a fight, ShamanKit notes where its buff really
  stopped and uses that for the same totem in the next fight, so the ? shrinks to about a yard. Totems with no buff
  (Searing, Magma) can't learn this and keep the wider ?.
- **Buff on the totem's icon** (Totem bar page, three choices): *a small picture on the corner* while the buff is on you, or
  *the icon follows it*: in a fight the totem icon stands red and the game draws a bright copy over it only while you have
  the buff, so bright means in range and red means out, with no guessing and no ?. The game draws it, so it works in a
  fight and in dungeons, where no addon can measure range or read buffs. The buff's spell ids are learned the first time
  a totem's buff can be read, so drop each totem once out of a fight. A buff from someone else's identical totem shows
  too. Totems with no buff (Searing, Magma, Earthbind, Stoneclaw) keep the position estimate.
- **Simple and advanced settings**: each settings page shows the choices most people want. The fiddly ones (exact
  nudges, screen positions, spacing, per-button placement, range-accuracy) sit behind a **Show advanced** button at the
  top right of the page; it is one switch for every page, and nothing changes in how the addon works.
- **Move mode**: one "Move on screen" button on every settings page (or `/shamankit move`) puts the totem bar, the buff
  icons, the cure row and the Call buttons on screen at once as labelled frames you drag where you want them. Pieces that
  sit on top of each other turn red and are named. Moving something that sat on the bar or the player frame gives it a
  place of its own. It is for out of combat only, and a fight ends it.
- **Call spells**: optional buttons at the totem bar (any side, any alignment, nudge and size are settings) or in a place of
  their own that you drag, shown all the time or only while a totem is out (and each button can be given a position
  of its own, apart from the others): one for Call of the Elements /
  Ancestors / Spirits with a small arrow to pick which, like the default totem bar, plus Totemic Call and Totemic
  Recall. Each is its own option (all off until you switch them on), and each only shows when you know the spell. In a
  fight a click casts as normal, but choosing another Call spell waits until the fight is over.
- **Cures**: Cure Disease (tan), Cure Poison (green) and, for an Orc, Shatter Curse (purple) light up, on the action bar
  buttons that hold them and in an optional small icon row, while a debuff they can remove is on you. The game draws the
  highlight (an aura container), so it works in a fight too. Click a lit icon in the row to cast that cure on yourself (also in a fight; can be switched off). Unlocking the frames only shows the row while a ShamanKit settings page is open, so you can drag it. Own settings page; it can be switched off. Replaces the
  separate CureWatch addon (ShamanKit stays off while CureWatch is installed).

Settings: Esc > Options > AddOns > ShamanKit (a home page and five pages: Totem bar, Totems, Buffs, Cures, Call spells), or `/shamankit`.
`/shamankit buffs` (or `bar`, `totems`, `cures`, `calls`) opens a page, `/shamankit cures test` lights the cures for a few seconds, `/shamankit lock | unlock` locks or unlocks the frames,
`/shamankit reset` puts the bar and the icons back in their usual place, and `/shamankit status` prints what the addon
reads for the totems and the buff icons. `/totemrange` still works too.

## Install and update (wowupd)

Install it with the `wowupd` addon manager, which then keeps it updated: `wowupd add https://github.com/shrimptec/ShamanKit`
(or *Add addon...* in the wowupd window). No account or token is needed. Restart the game after the first install;
later updates need only `/reload`. Without wowupd: download `ShamanKit-v<version>-forever.zip` from the latest
release and unzip it into `World of Warcraft/_forever_/Interface/AddOns/`.

## Your settings, and syncing them between computers

A WoW addon can't write its own config file; the game saves an addon's settings itself when you `/reload` or log out. ShamanKit
keeps two things:

- **Your settings** (layout, sizes, positions, options): `WTF/Account/<your account>/SavedVariables/ShamanKit.lua`. This is
  the one file to sync between computers (for example with Syncthing); ignore `ShamanKit.lua.bak` in that folder.
- **The debug log** (only useful for bug reports) is kept per character, in
  `WTF/Account/<your account>/<realm>/<character>/SavedVariables/ShamanKit.lua`, so it never ends up in the file you sync.

The game reads the settings file when you log in and writes it when you log out or `/reload`, so: close or log out of the
game on one computer before you play on the other, and give Syncthing a moment to finish. If both games run at once,
whichever logs out last wins. Positions are saved relative to the screen, so a different monitor or UI scale may need a
touch-up with **Move on screen**.

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
