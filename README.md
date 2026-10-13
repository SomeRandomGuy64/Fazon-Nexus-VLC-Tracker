# Fazon Nexus Tracker for VLC

A [VLC](https://www.videolan.org/vlc/) extension that logs what you watch to your
[fazon.nexus](https://fazon.nexus) **Track** as **active** or **passive immersion**. The time goes
into a sub-category named after what you're watching (you can rename it first), created for you if
you don't have it yet.

- **Off by default.** Nothing is logged until you turn it on from the View menu, so the English
  video you watch afterwards doesn't end up in your Track.
- **Counts real playing time:** not paused or stopped. It counts wall-clock time, so 30 minutes at
  1.5× speed logs 30 minutes.
- **One at a time:** active and passive can't run together; starting the other one switches.
- **Doesn't lose time:** if the site can't be reached, the time is saved and sent later.

Prefer hotkeys? There's also [Fazon Nexus Tracker for mpv](https://github.com/SomeRandomGuy64/Fazon-Nexus-MPV-Tracker).
VLC extensions can't use hotkeys, so this one works from the menu.

## Requirements

- **VLC 3.0.** Tested on Linux with VLC 3.0.20. VLC 4 hasn't been tested.
- **curl.** It's built into Windows 10 and 11 and macOS, and most Linux distributions have it
  (`curl --version` to check).
- A **fazon.nexus account** and a **Read & write API key**:
  1. Log in to [fazon.nexus](https://fazon.nexus) and open your profile (account menu →
     **Your profile**).
  2. Scroll down to **Developers** and create a key with **Read & write** access.
  3. Copy it (it's shown once). It looks like `fz_` followed by 43 characters.

## Install

1. Download [`fazon_track.lua`](https://github.com/SomeRandomGuy64/Fazon-Nexus-VLC-Tracker/releases/latest/download/fazon_track.lua)
   from the [latest release](https://github.com/SomeRandomGuy64/Fazon-Nexus-VLC-Tracker/releases/latest).
2. Put it in VLC's extensions folder (create the folders if they don't exist):

   | | Extensions folder |
   |---|---|
   | Linux | `~/.local/share/vlc/lua/extensions/` |
   | Linux (Flatpak) | `~/.var/app/org.videolan.VLC/data/vlc/lua/extensions/` |
   | Linux (Snap) | `~/snap/vlc/current/.local/share/vlc/lua/extensions/` |
   | Windows | `%APPDATA%\vlc\lua\extensions\` (type it into the Explorer address bar) |
   | macOS | `~/Library/Application Support/org.videolan.vlc/lua/extensions/` |

3. Restart VLC, or go to **Tools → Plugins and extensions → Active Extensions → Reload extensions**.

On Linux from a terminal:

```sh
mkdir -p ~/.local/share/vlc/lua/extensions
curl -L -o ~/.local/share/vlc/lua/extensions/fazon_track.lua \
  https://github.com/SomeRandomGuy64/Fazon-Nexus-VLC-Tracker/releases/latest/download/fazon_track.lua
```

## Use

1. Play something, then choose **View → Fazon Track**.
2. **The first time,** it asks for your API key. Paste it and click **Save**. The key is checked
   with fazon.nexus before it's kept.
3. A window opens with the video's title as the sub-category name. Edit it if you like, then click
   **Active immersion** or **Passive immersion**.

From then on, **View → Fazon Track** has:

| Item | |
|---|---|
| **Start tracking…** | Opens the same window. Pick the other button to switch between active and passive. |
| **Stop tracking** | Turns it off and sends the time. |
| **Status** | What's being tracked, the time this session, and anything waiting to be sent. Useful for audio-only files, where VLC shows no on-screen messages. |
| **Set API key…** | Change the key (the old one stays until the new one is accepted). |

- **Every time VLC starts, tracking is off.** VLC doesn't keep extensions on between sessions, so
  you choose **View → Fazon Track** again when you want it.
- **Playlists:** when VLC moves to the next video, tracking carries on under the new video's title.
- **Where it goes:** the current Track week (Sunday 03:00 UTC to Sunday 03:00 UTC, like the site).
  If a week ends while you're watching, the time is split between the two weeks.

The suggested name is the video's title. Files without a title use the file name, with underscores
shown as spaces.

## When time is sent

VLC extensions can't run timers, so time is sent whenever something happens: you **pause**,
**stop**, **change video**, **stop tracking** or **quit VLC**. During one long stretch without
pausing, the time is counted but not sent yet. It's sent the moment you pause or quit.

If VLC crashes or is killed during such a stretch, that stretch is lost (anything already counted
before it is saved). If the site can't be reached, the time is saved and sent the next time you turn
tracking on.

## Settings

A few settings are at the top of `fazon_track.lua`. Open it in a text editor and restart VLC after
changing them:

| Setting | Default | |
|---|---|---|
| `CONTINUE_ON_NEXT_FILE` | `true` | Keep tracking when the playlist moves on (`false` stops instead). |
| `DEFAULT_SUBCAT` | `""` | Suggest this name instead of the title, e.g. `"Anime"`. |
| `API` | `https://api.fazon.nexus/v1/api/track` | Only change this if you run your own copy of the site. |

## What gets sent, and how it's counted

- Only what you track: the sub-category name and the time. Nothing about videos you don't track,
  and nothing else from your computer.
- Your key goes to `api.fazon.nexus` over HTTPS. It's stored in `fazon_track_key.conf` in VLC's
  config folder, readable only by you on Linux and macOS:

  | | Key file | Unsent time |
  |---|---|---|
  | Linux | `~/.config/vlc/` | `~/.local/share/vlc/fazon_track/` |
  | Windows | `%APPDATA%\vlc\` | `%APPDATA%\vlc\fazon_track\` |
  | macOS | `~/Library/Preferences/org.videolan.vlc/` | `~/Library/Application Support/org.videolan.vlc/fazon_track/` |

  curl reads the key from that file, so it never shows up in the process list.
- **Hours are counted in hundredths (36 seconds)**, like the site. Each send adds whole 36-second
  steps and keeps the leftover seconds for next time. When you stop, the last leftover is rounded to
  the nearest step (18 seconds or more counts as 0.01 h). Your Track ends up within about
  18 seconds of your real watch time per session.
- Time is **added** to the sub-category's total for the week, never replacing what's there.

## Good to know

- **Sub-category limit:** fazon.nexus allows **30 active sub-categories per category**. One per
  video fills that quickly. Archive old ones on the site (your hours stay in the old weeks), or set
  `DEFAULT_SUBCAT` so everything goes to one name. When it's full, the window tells you.
- **Names** are at most **40 characters**. Longer titles are cut.
- **Windows:** VLC runs curl through the command prompt, so a console window may flash briefly
  each time time is sent.

## Troubleshooting

Messages appear in the extension's window. For more detail, open **Tools → Messages**, set
verbosity to 2, and look for `[Fazon Track]`.

| Message | Fix |
|---|---|
| `didn't accept that key` | Copy the whole key from your profile, or create a new one. |
| `401 …` | The key was revoked. **View → Fazon Track → Set API key…** with a new one. |
| `403 … read-only` | The key is *Read only*. Create a *Read & write* one and set it. |
| `409 … at most 30 active sub-categories` | Archive some sub-categories on the site. |
| `no response (is curl installed?)` | Install curl, or check your internet connection. |
| *Fazon Track isn't in the View menu* | Check the file is in the extensions folder above, then reload extensions or restart VLC. |

**Platforms:** written for Linux, macOS and Windows, but only tested on Linux. If something doesn't
work on yours, please [open an issue](https://github.com/SomeRandomGuy64/Fazon-Nexus-VLC-Tracker/issues).

## Uninstall

Delete `fazon_track.lua` from the extensions folder, `fazon_track_key.conf` from VLC's config
folder and the `fazon_track` folder (see the table above), and revoke the key on your profile.

## Releasing

1. Bump `VERSION` at the top of `fazon_track.lua` and commit.
2. Tag and push: `git tag v1.0.1 && git push origin main v1.0.1`.

[`.github/workflows/release.yml`](.github/workflows/release.yml) checks the tag matches `VERSION`,
checks the script compiles, and publishes the release with `fazon_track.lua` attached. To redo an
existing tag: *Actions → Release → Run workflow*.

## License

[MIT](LICENSE)
