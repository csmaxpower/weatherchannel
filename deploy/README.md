# ws4kp Deployment Guide

Deploy WeatherStar 4000+ on Proxmox VE with Docker, Traefik and Watchtower, and
run it as a 24/7 IPTV channel.

**Website:** `weather.randharris.org` → `10.30.0.60:8080`
**Video egress:** MediaMTX at `10.30.0.54` (path `weather`) + MPEG-TS multicast on `239.10.30.60:5004`

```
GitHub (main) ──actions──> ghcr.io ──watchtower──> LXC 10.30.0.60
                                                        ├─ ws4kp          web app + weather.gov proxy  :8080
                                                        ├─ ws4kp-caster   Xvfb → Chromium kiosk → ffmpeg
                                                        │                   ├─> rtsp://10.30.0.54:8554/weather
                                                        │                   └─> udp://239.10.30.60:5004 (MPEG-TS)
                                                        └─ watchtower     pulls new images, restarts containers
```

---

## 1. One-time: GitHub Actions → GitHub Container Registry

The workflow in `.github/workflows/build-docker.yaml` builds two images on
every push to `main` and pushes them to GitHub Container Registry (ghcr.io)
tagged `latest` and `vX.Y.Z`, then creates a GitHub Release:

| Image | Dockerfile | Contents |
|---|---|---|
| `ghcr.io/csmaxpower/weatherchannel-web` | `Dockerfile.server` | Express app, weather.gov caching proxy, built site |
| `ghcr.io/csmaxpower/weatherchannel-caster` | `Dockerfile.caster` | Chromium + Xvfb + ffmpeg, the channel encoder |

**No secrets to configure.** The workflow logs in to ghcr.io with the job's own
`GITHUB_TOKEN`. Two things to check once:

1. **Actions may create packages.** Repo → **Settings → Actions → General →
   Workflow permissions** must be *Read and write permissions*. (The workflow
   also declares `packages: write`, which is enough when the setting is the
   default.)
2. **Make the packages public after the first run.** A user-owned package is
   private the first time it is pushed, and a private image needs a login on
   the LXC. On your GitHub profile → **Packages** → `weatherchannel-web` →
   **Package settings** → *Change visibility* → **Public**. Repeat for
   `weatherchannel-caster`. The images carry the
   `org.opencontainers.image.source` label, so they link back to this repo.

   If you would rather keep them private, log the LXC in once with a classic
   personal access token that has `read:packages`, then let Watchtower reuse
   that credential:
   ```bash
   docker login ghcr.io -u csmaxpower         # paste the PAT as the password
   ```
   and uncomment the `/root/.docker/config.json` volume on the `watchtower`
   service in `docker-compose.yml`.

Pushes that only touch `*.md`, `deploy/**` or `.gitignore` do not trigger a
build. To build on demand, use **Actions → Build and Push Docker Images → Run
workflow**; it can take an explicit version and skip the slow caster image.

The first run creates `v0.1.0`; each later run increments the patch number.
Unlike Docker Hub, ghcr.io has no anonymous pull rate limit, so Watchtower's
five-minute polling costs nothing.

---

## 2. Create the Docker LXC via Proxmox Community Scripts

Run this in the **Proxmox host shell** (`10.30.0.51`), not inside a container:

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh)"
```

### Sizing

| Setting      | Value     | Notes                                                                 |
|--------------|-----------|-----------------------------------------------------------------------|
| OS           | Debian 13 |                                                                       |
| CPU          | 4 cores   | 2 is enough for the web app alone; libx264 at 1080p30 wants the rest   |
| RAM          | 4096 MB   | Chromium + ffmpeg are the drivers; 2 GB is fine without the caster     |
| Disk         | 8 GB      | The caster image pulls Chromium and ffmpeg                             |
| Unprivileged | Yes       |                                                                       |
| Nesting      | Enabled   | Required for Docker-in-LXC                                             |

During setup: choose **Advanced**, set the static IP to **`10.30.0.60/24`**
with your gateway. Portainer optional, Portainer Agent no, Docker TCP socket no.

> **Already running the 2 core / 2 GB LXC from the earlier guide?** Resize it
> before enabling the caster. On the Proxmox host (`CTID` is the container id):
> ```bash
> pct set <CTID> --cores 4 --memory 4096
> pct resize <CTID> rootfs +4G
> ```
> Cores and memory apply live; the disk grows online too on an ext4 rootfs.

---

## 3. Deploy the application

SSH into the LXC (`10.30.0.60`):

```bash
apt install -y git
cd /opt
git clone https://github.com/csmaxpower/weatherchannel.git
cd weatherchannel/deploy
cp .env.example .env
```

Edit `.env`. The only values that normally change:

```
CHANNEL_ZIP=35406                  # the channel's location
CHANNEL_LATLON=33.2699,-87.5173    # its lat,lon (recommended, see .env.example)
CHANNEL_QUERY=                     # optional display/units parameters from a permalink
```

Start the web app and Watchtower (the caster stays off until step 5):

```bash
docker compose up -d
```

Verify:

```bash
docker compose ps
curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8080/
curl -s http://localhost:8080/playlist.m3u
```

The playlist should list the multicast, HLS and RTSP URLs built from `.env`.

> **Upgrading from the old build-on-the-LXC compose file?** The new
> `docker-compose.yml` pulls published images instead of building. Pull the
> repo, copy `.env.example` to `.env`, then `docker compose up -d`. The old
> locally-built `ws4kp` image is left behind; `docker image prune` removes it.

> **Building on the LXC instead.** To test an uncommitted change, layer the
> build override on and stop Watchtower so it does not replace your local image:
> ```bash
> docker compose stop watchtower
> docker compose -f docker-compose.yml -f docker-compose.build.yml up -d --build
> ```

---

## 4. Configure Traefik

`deploy/weatherchannel.yml` is the dynamic route for `weather.randharris.org`.
Copy it into the `spf-traefik` repo and deploy from there, which rsyncs the
whole `dynamic/` tree to the Traefik host (`10.30.0.52`):

```bash
cp deploy/weatherchannel.yml ../spf-traefik/config/dynamic/services/weatherchannel.yml
cd ../spf-traefik && ./scripts/validate.sh && ./scripts/deploy.sh
```

The file provider runs with `watch: true`, so Traefik loads it without a
restart. DNS: an **A record** for `weather` pointing at Traefik's address.

---

## 5. Enable the channel (caster)

### 5a. Add the path on MediaMTX

`pathDefaults.source` on the MediaMTX box is already `publisher`, so the path
needs no settings of its own. Add it to the config file so it survives a
restart, then tell the running server about it over the API (which is
localhost-only, so run both on the box itself):

```bash
ssh root@10.30.0.54

# persistent: add under paths: in /opt/mediamtx/mediamtx.yml, next to radar:
#   weather:
sed -i '/^paths:/a\  weather:' /opt/mediamtx/mediamtx.yml

# live, no restart:
curl -X POST http://127.0.0.1:9997/v3/config/paths/add/weather \
  -H 'Content-Type: application/json' -d '{}'

# confirm
curl -s http://127.0.0.1:9997/v3/config/paths/list | jq '.items[].name'
```

Also add `weather:` to `mediamtx.yml` in the `SPF-MediaMTX` repo so the repo
matches the box.

> Publishing is unauthenticated on this server (`user: any` holds `publish` and
> `read` with no IP restriction), so the caster needs no credentials. Only the
> administrative API is restricted to `127.0.0.1`.

### 5b. Start the caster

```bash
cd /opt/weatherchannel/deploy
docker compose --profile cast up -d
docker compose logs -f ws4kp-caster
```

Expect `starting Xvfb`, `channel page: http://localhost:8080/?latLonQuery=...`,
`music: N tracks`, `page is up`, `launching chromium`, `watchdog started`, then
`starting ffmpeg` with both `output:` lines.

### 5c. Verify the outputs

```bash
# RTSP into MediaMTX, from anywhere on the LAN
ffprobe -rtsp_transport tcp rtsp://10.30.0.54:8554/weather

# MediaMTX sees a publisher (on the MediaMTX box; the API is localhost-only)
ssh root@10.30.0.54 "curl -s http://127.0.0.1:9997/v3/paths/get/weather | jq '.ready, .tracks'"

# Multicast, from a different machine on VLAN 30
ffplay udp://@239.10.30.60:5004
```

Because MediaMTX re-serves whatever it ingests, the channel is also available as:

| Protocol  | URL                                            |
|-----------|------------------------------------------------|
| RTSP      | `rtsp://10.30.0.54:8554/weather`               |
| RTMP      | `rtmp://10.30.0.54:1935/weather`               |
| HLS       | `http://10.30.0.54:8888/weather`               |
| WebRTC    | `http://10.30.0.54:8889/weather`               |
| SRT       | `srt://10.30.0.54:8890?streamid=read:weather`  |
| Multicast | `udp://@239.10.30.60:5004`                     |

### 5d. Tune in from an IPTV app

Point the app at the playlist the web container serves:

```
http://10.30.0.60:8080/playlist.m3u
```

It lists the same channel three ways (multicast, HLS, RTSP). Add
`?only=multicast` (or `hls`, `rtsp`) for apps that cannot handle alternatives.
Multicast is the lowest-latency choice on the wired VLAN; HLS is the one that
works everywhere, including Wi-Fi and across VLANs.

Multicast reaches every port on VLAN 30 because the switch floods it (IGMP
snooping is off). That is deliberate and documented in
`FlightTrackerDisplay/deploy/IGMP_Setup.md`; a second ~8 Mbps stream does not
change the calculus. Wi-Fi clients should use HLS.

---

## 6. Updating

Nothing to do. Push to `main`, GitHub Actions publishes new images to
ghcr.io, and Watchtower pulls and restarts the containers within five minutes.

To deploy immediately instead of waiting:

```bash
cd /opt/weatherchannel/deploy
docker compose --profile cast pull
docker compose --profile cast up -d
```

To pin or roll back, set `IMAGE_TAG=v0.1.2` in `.env` and run the two commands
above. Watchtower only follows the tag you are running, so a pinned deployment
stays pinned until you change `IMAGE_TAG` back to `latest`.

Changing anything in `.env` (a new ZIP, different displays, music volume) does
not need a new image:

```bash
docker compose --profile cast up -d    # recreates only containers whose env changed
```

---

## 7. Troubleshooting

**Stream shows the loading screen or a blank page.** The caster waited for the
web container but the page failed to load its data. Check
`docker compose logs ws4kp` for proxy errors, then
`docker compose restart ws4kp-caster`.

**Stream froze on one slide.** The watchdog should reload the page within a
minute (`watchdog: page appears frozen` then `reloading frozen page` in the
logs). If it never fires, the beacon is not running: confirm the channel URL in
the logs contains `kiosk=true`.

**No sound.** `docker compose logs ws4kp-caster | grep music` should report a
track count. `no mp3 files found` means `/music` is empty; if you mounted a
volume over it, check the path. `MUSIC=0` in `.env` is silence on purpose.

**Player shows nothing but ffprobe is happy.** Hardware decoders refuse 4:4:4;
make sure `PIX_FMT=yuv420p` (the default). If the picture looks washed out on a
PC player, try `OUT_RANGE=full`.

**Watchtower logs `unauthorized` or `denied` pulling from ghcr.io.** The
package is still private. Make it public (section 1) or mount the host's
Docker login into Watchtower.

**Watchtower exits with "client version 1.25 is too old".** Set
`DOCKER_API_VERSION` in `.env` to what `docker version --format
'{{.Server.APIVersion}}'` reports.

**MediaMTX says `path 'weather' is not configured`.** Step 5a was skipped or
the server restarted before the file was edited. Re-run it.

---

## Firewall Notes

- **Inbound:** TCP 8080 on `10.30.0.60` from the Traefik host and from any IPTV
  client fetching `/playlist.m3u`
- **Outbound:** HTTPS (443) to weather.gov APIs (`api.weather.gov`,
  `radar.weather.gov`, `www.spc.noaa.gov`, `forecast.weather.gov`,
  `mesonet.agron.iastate.edu`) and `geocode.arcgis.com`
- **Outbound:** TCP 8554 to `10.30.0.54` (RTSP publish) and UDP multicast on
  VLAN 30 (the caster uses host networking, so no port mapping is involved)
- Browser geolocation ("Use My Location") requires HTTPS, so it works via
  Traefik but not via direct HTTP access

## Environment Variables (website defaults)

Set default display options for visitors using `WSQS_` prefixed environment
variables on the `ws4kp` service. Convert permalink query parameters by adding
the `WSQS_` prefix and replacing hyphens with underscores:

| Permalink parameter              | Environment variable                  |
|----------------------------------|---------------------------------------|
| `latLonQuery=Tuscaloosa, AL`     | `WSQS_latLonQuery=Tuscaloosa, AL`     |
| `current-weather-checkbox=true`  | `WSQS_current_weather_checkbox=true`  |
| `hazards-checkbox=false`         | `WSQS_hazards_checkbox=false`         |

These affect the website only. The channel's parameters come from
`CHANNEL_ZIP`, `CHANNEL_LATLON` and `CHANNEL_QUERY`.
