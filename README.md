# RTMP Control

Bring remote performers' video streams into OBS, from the Mac menu bar. No Terminal, no config files.

Each performer streams (from OBS, a Blackmagic ATEM, vMix, etc.) to your Mac with their own
stream key. RTMP Control runs the receiving server in Docker, shows who's live and how healthy
their connection is, and lets you add, disable and kick performers with a click. In OBS, each
performer is a Media Source, so switching between them is just a scene change.

- **Status at a glance**: the menu bar icon is green with a count when performers are live,
  orange when the server is ready and waiting, and red when something needs attention.
- **One key per performer**: hard-to-guess keys are created for you, with a ready-to-send setup
  message (server, key, recommended encoder settings). Unknown keys are rejected.
- **Connection health**: live bitrate and a 3-minute graph per performer, with an **Unstable**
  warning when their upload is struggling, before the audience notices.
- **Recovers from stuck sessions**: dead connections are dropped automatically after 10 seconds,
  and **Fresh Restart** clears everything in a few seconds.
- **Notifications** when performers go live or stop, when a stream turns unstable, when an
  unknown key tries to connect, and if the server goes down.
- **Browser dashboard** at `http://localhost:8090` for a second screen.

Requires macOS 14.2 or later on Apple silicon, and [Docker Desktop](https://www.docker.com/products/docker-desktop/).

## Install

1. Install and open **Docker Desktop** once (accept its prompts). In its settings, turn on
   **Start Docker Desktop when you sign in**.
2. Build and install the app (needs Xcode command line tools: `xcode-select --install`):
   ```sh
   git clone https://github.com/BigDumbRobot/rtmp-control.git ~/rtmp-server
   ~/rtmp-server/RTMPControl/build.sh --install
   ```
3. Look for the video-camera icon in the menu bar and press **Start Server**.
4. In **Settings**, enter the address performers stream to (e.g. `rtmp://your.address:1935/live`)
   and turn on **Open RTMP Control at login**.

> Can't see the icon? A full menu bar hides icons behind the camera notch. Hold **⌘** and drag
> other icons out of the menu bar to make room.

The app expects the server files in `~/rtmp-server` (changeable in Settings). If the folder is
missing, it creates one from the copy inside the app.

## Using it

**Add a performer**: Keys tab → type their name → **Add Key** → **Copy Setup Message** and send it.
They set their encoder to:

- Server: `rtmp://your.address:1935/live`
- Stream key: the key you sent them

**In OBS**: add a **Media Source** per performer, uncheck *Local File*, set the input to
`rtmp://localhost:1935/live/<their key>`, and check *Restart playback when source becomes active*.

**During a show**: the Live tab shows each performer's bitrate, resolution, audio, uptime and
whether OBS is pulling their stream. **Kick** disconnects one performer; **Fresh Restart** drops
every connection (handy before a show, or if something is stuck).

## Letting performers reach you

Performers connect to your Mac through your router:

- **Port forwarding**: forward TCP port **1935** to your Mac's local IP address.
- **A stable address** (recommended): home IP addresses change. A free dynamic DNS name from
  [DuckDNS](https://www.duckdns.org) or [No-IP](https://www.noip.com) keeps the address working.

The dashboard (8090) and stat page (8080) only listen on this Mac and are never exposed.

## Recommended performer settings

| | |
|---|---|
| Video | 1080p30 at 4–6 Mbps CBR, or 720p30 at 2.5–4 Mbps |
| Keyframe interval | 2 seconds |
| Audio | AAC, 48 kHz, 128–160 kbps |
| Connection | Wired Ethernet; video bitrate at most ~60% of their measured upload |

## How it works

```
performers ──RTMP :1935──▶ rtmp (nginx-rtmp, 1 worker) ──▶ OBS Media Sources
                                │  on_publish: is this key allowed?
                                ▼
                           rtmp-admin (Python, stdlib only) ◀── RTMP Control.app
                           keys, activity log, dashboard :8090
```

| File | What it is |
|---|---|
| `compose.yaml` | The two containers. `rtmp-admin` shares `rtmp`'s network, so they talk over 127.0.0.1 |
| `nginx.conf` | RTMP server: one worker, idle-publisher drop, key check on publish |
| `admin/app.py` | Key store, publish authorization, activity log, JSON API, dashboard |
| `admin/static/index.html` | Browser dashboard |
| `stat.xsl` | Styles nginx's raw stat page at `http://localhost:8080` |
| `RTMPControl/` | The SwiftUI menu bar app (`build.sh` builds it and bundles the files above) |
| `data/` | Created at runtime: `keys.json`, `settings.json`, `events.jsonl`. Not in git |

Notes:

- nginx-rtmp allows one publisher per stream name, so a shared key makes the second person get
  `already publishing`. That's why every performer gets their own key.
- A single nginx worker is deliberate. Multiple workers with `rtmp_auto_push` copy every stream
  between workers and are a known source of instability.
- If the `rtmp` container restarts by itself, `rtmp-admin` notices within 20 seconds and restarts
  too, to rejoin its network.

## License

MIT. See [LICENSE](LICENSE). Uses [nginx-rtmp-module](https://github.com/arut/nginx-rtmp-module)
via the [tiangolo/nginx-rtmp](https://hub.docker.com/r/tiangolo/nginx-rtmp) image (pulled at runtime, not included).
