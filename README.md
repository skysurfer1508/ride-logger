# Ride Logger

Self-hosted motorbike ride logger. Receives GPS location batches from the
[Overland](https://github.com/aaronpk/Overland-iOS) iOS app, groups them into
rides, and shows them on a Leaflet map with stats.

## Setup

```bash
python3 -m venv .venv
.venv/bin/pip install -r requirements.txt
cp .env.example .env   # then edit INGEST_TOKEN / DASH_USER / DASH_PASS / SESSION_SECRET
```

Run locally:

```bash
.venv/bin/uvicorn app.main:app --host 127.0.0.1 --port 8090 --reload
```

## Ingest endpoint

`POST /api/ingest` — set this as the Server URL in Overland's settings
(`https://<your-tunnel-hostname>/api/ingest`), with the Access Token set to
`INGEST_TOKEN` from `.env`. Overland sends `Authorization: Bearer <token>`.

## Dashboard

`GET /`, `/rides/{id}`, `/overview` — protected by a session-cookie login at
`/login` (`DASH_USER` / `DASH_PASS` from `.env`, signed with `SESSION_SECRET`).
Visiting any dashboard page while logged out redirects to `/login`; `/logout`
clears the session.

## Maintenance

Recompute all rides from raw points (after tuning segmentation/stat logic):

```bash
.venv/bin/python -m app.cli reprocess [--since 2026-01-01]
```

## Deploying as a systemd service

```bash
sudo cp deploy/ride-logger.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now ride-logger
sudo systemctl status ride-logger
```

## Cloudflare Tunnel

This server already runs a remotely-managed `cloudflared` tunnel in Docker
(container `gifted_matsumoto`, token-based, no local `config.yml`). No new
tunnel or install needed — routing is added entirely in the Cloudflare Zero
Trust dashboard: Networks → Tunnels → (existing tunnel) → Public Hostname →
add a hostname with Service `HTTP` → `192.168.0.123:8090` (the server's LAN
IP; the container reaches the host over the Docker bridge either way, but the
LAN IP is easier to recognize later — set a DHCP reservation for this host so
it doesn't change).

Currently routed to `https://ride.skyserver1508.org`.
