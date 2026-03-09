# ws4kp Deployment Guide

Deploy WeatherStar 4000+ on Proxmox VE with Docker and Traefik.

**Target:** `weather.randharris.org` → `10.30.0.60:8080`

---

## 1. Create Docker LXC via Proxmox Community Scripts

We use the [Proxmox VE Helper-Scripts](https://community-scripts.github.io/ProxmoxVE/) Docker LXC script. This creates a Debian 13 LXC with Docker CE, Docker Compose plugin, and Docker BuildX pre-installed — no manual Docker installation needed.

Run this command in your **Proxmox host shell** (not inside a container):

```bash
bash -c "$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/ct/docker.sh)"
```

### Script defaults

| Setting       | Default     | Notes                                              |
|---------------|-------------|----------------------------------------------------|
| OS            | Debian 13   |                                                    |
| CPU           | 2 cores     | 1 core is sufficient for ws4kp if you want to save resources |
| RAM           | 2048 MB     | 512 MB is sufficient for ws4kp runtime, but 2 GB helps during the Docker image build |
| Disk          | 4 GB        | Fine as-is                                         |
| Unprivileged  | Yes         |                                                    |
| Nesting       | Enabled     | Required for Docker-in-LXC                         |

### During the interactive setup

1. Choose **Advanced** mode when prompted so you can customize the network settings.
2. Set the static IP to **`10.30.0.60/24`** and your gateway.
3. When asked about **Portainer**: optional — say No if you prefer managing containers via CLI and docker-compose. Say Yes if you want a web UI for container management (accessible on port 9443).
4. When asked about **Portainer Agent**: No (unless you have a central Portainer instance elsewhere).
5. When asked about **Docker TCP socket**: No (not needed for this deployment).

> **Why not Alpine Docker or Docker VM?**
> - The **Alpine Docker** LXC script uses Alpine Linux and installs Docker Compose as a separate binary rather than the integrated plugin. Debian is a better match since the ws4kp `Dockerfile.server` is based on `node:24-alpine` internally but the build tooling (npm, gulp, webpack) benefits from the larger Debian package ecosystem if you ever need to debug.
> - The **Docker VM** script creates a full virtual machine (4 GB RAM, 10 GB disk default). This is overkill for a single lightweight container app and wastes resources compared to an LXC.

## 2. Deploy the Application

SSH into or open the console of your new Docker LXC (`10.30.0.60`), then:

```bash
apt install -y git
cd /opt
git clone https://github.com/netbymatt/ws4kp.git
cd ws4kp/deploy
```

Edit `docker-compose.yml` if you want to change the default location or add custom music.

Build and start:

```bash
docker compose up -d --build
```

Verify the container is running:

```bash
docker compose ps
curl -s http://localhost:8080/ | head -5
```

> **Note:** The first build takes ~2-5 minutes as it runs `npm ci` and `npm run build` (webpack/gulp). Subsequent builds are faster due to Docker layer caching.

## 3. Configure Traefik

Copy `traefik-ws4kp.yml` to your Traefik dynamic configuration directory:

```bash
# Example — adjust the path to match your Traefik file provider directory
cp /opt/ws4kp/deploy/traefik-ws4kp.yml /etc/traefik/dynamic/ws4kp.yml
```

If your Traefik file provider has `watch: true`, it will pick up the new config automatically. Otherwise, restart Traefik.

## 4. Configure DNS

Create an **A record** in your DNS provider:

| Type | Name    | Value                      |
|------|---------|----------------------------|
| A    | weather | Traefik's public IP address |

If Traefik is internal-only, point the A record to Traefik's internal IP instead.

## 5. Verify

1. **Direct access:** Open `http://10.30.0.60:8080` from a machine on your network
2. **Via Traefik:** Open `https://weather.randharris.org` — should load with a valid TLS certificate
3. **Weather data:** Search a US location to confirm the server-side proxy is working
4. **Logs:** `docker compose -f /opt/ws4kp/deploy/docker-compose.yml logs -f` — look for cache hit/miss lines

## Updating

```bash
cd /opt/ws4kp
git pull
cd deploy
docker compose up -d --build
```

## Firewall Notes

- **Inbound:** TCP 8080 on `10.30.0.60` must be reachable from your Traefik host
- **Outbound:** HTTPS (443) to weather.gov APIs (`api.weather.gov`, `radar.weather.gov`, `www.spc.noaa.gov`, `forecast.weather.gov`, `mesonet.agron.iastate.edu`)
- Browser geolocation ("Use My Location") requires HTTPS — works via Traefik, not via direct HTTP access

## Environment Variables

Set default display options using `WSQS_` prefixed environment variables in `docker-compose.yml`. Convert permalink query parameters by adding the `WSQS_` prefix and replacing hyphens with underscores:

| Permalink parameter              | Environment variable                  |
|----------------------------------|---------------------------------------|
| `latLonQuery=Tuscaloosa, AL`     | `WSQS_latLonQuery=Tuscaloosa, AL`     |
| `current-weather-checkbox=true`  | `WSQS_current_weather_checkbox=true`  |
| `hazards-checkbox=false`         | `WSQS_hazards_checkbox=false`         |

Use the app's permalink/share feature to generate a starting point, then convert each parameter.
