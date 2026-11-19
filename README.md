# EveryApp-Server

Ein-Command-Installer für die **EveryApp-CLI** ([every-app/every-app](https://github.com/every-app/every-app)) als LXC-Container auf Proxmox VE — im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

> ⚠️ **Ehrlich vorab:** EveryApp deployt die Apps (OpenSEO, OpenCRM, OpenAnalytics, OpenMail …)
> in **deinen eigenen Cloudflare-Account** (Cloudflare Workers, D1, KV, R2 — **R2 muss aktiviert
> sein**, Workers Paid ab ~5 USD/Monat, Domain bei Cloudflare). Das ist der vom Projekt selbst
> vorgesehene Betrieb — eine komplett lokale Ausführung ohne Cloudflare gibt es nicht.
> **Lokal** auf deinem Proxmox läuft die `everyapp`-CLI plus ein Webterminal, mit dem du das
> Cloudflare-Setup im Container durchführst.

## Installation (Einzeiler, auf dem Proxmox-Host als root)

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/EveryApp-Server/main/install/everyapp.sh)"
```

Das Script:

- ermittelt die **nächste freie CT-ID** automatisch (oder `--ctid N`)
- erstellt einen unprivileged Debian-LXC mit Hostname `every-app` (`onboot=1`, `nesting=1`)
- 2 vCPU / 2 GB RAM / 8 GB Disk (per Env überschreibbar: `CORES`, `MEM_MB`, `DISK_GB`, `STORAGE`, `BRIDGE`, `TTYD_PORT`)
- installiert **Node.js 22 LTS** (≥ 22.18.0 — Engines-Anforderung der CLI) und `everyapp` global via npm
- installiert **ttyd 1.7.7** als Webterminal auf **Port 8093**, gekoppelt an eine tmux-Session
  (das Setup überlebt ein geschlossenes Browser-Fenster)
- richtet `everyapp-ttyd.service` ein (`Restart=always`, `After=network-online.target`)
- verifiziert selbst: Service `active`, HTTP-Check auf `localhost:8093`, `everyapp --version`
- gibt am Ende die **finale URL** mit der Container-IP aus

Erwartete Ausgabe am Ende:

```
  ============================================================
   EveryApp CLI installiert!  (CT 105, Hostname every-app)
  ============================================================

   Webterminal :  http://10.0.0.50:8093
   ...
```

## Danach (im Webterminal unter `http://<CT-IP>:8093`)

```bash
everyapp login                              # Cloudflare-Anmeldung
everyapp setup --domain apps.deine-domain.de
everyapp install https://github.com/every-app/open-seo
everyapp status
```

Telemetrie abschalten (tägl. anonymer Usage-Report): `everyapp telemetry off`

## Optionen

| Option | Bedeutung |
|---|---|
| `--ctid N` | bestimmte CT-ID (sonst nächste freie; existierender `every-app`-CT wird wiederverwendet) |
| `--update` | bestehenden CT aktualisieren (everyapp-CLI via npm + ttyd-Binary) |
| `--uninstall` | CT stoppen + löschen (mit Rückfrage) |
| `--yes` | Rückfrage bei `--uninstall` überspringen |
| `--debug` | `bash -x` — alles loggen |

## Update

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/EveryApp-Server/main/install/everyapp.sh)" --update
```

(Alternativ im CT: `npm install -g everyapp && systemctl restart everyapp-ttyd`.)

## Deinstall

```bash
bash -c "$(wget -qLO - https://raw.githubusercontent.com/HatchetMan111/EveryApp-Server/main/install/everyapp.sh)" --uninstall --yes
```

## Reboot-Sicherheit

- Container: `onboot=1` in der CT-Config → startet mit dem Host
- Service: `systemctl enable everyapp-ttyd` + `Restart=always`
- Test nach eigenen Eingriffen: `pct reboot <CT-ID>` und danach wieder `http://<CT-IP>:8093` öffnen

## Debugging

Bei Fehlern gibt das Script die **komplette Fehlerkette** aus (Befehl, vollständige
stdout+stderr-Ausgabe, Exit-Code, relevante Log-Auszüge) — nicht nur die letzte Zeile.

- Komplettes Log: `/var/log/everyapp-install.log` (im Container / auf dem Host)
- Detail-Neulauf: `bash -x install/everyapp.sh 2>&1 | tee /var/log/everyapp-install.log`
- Service-Logs im CT: `journalctl -u everyapp-ttyd -n 50 --no-pager`

## Bekannte Grenzen

- Die Apps laufen bei Cloudflare — ein lokaler "Dev"-Betrieb (`everyapp dev`) ist möglich,
  aber nicht das Ziel dieses Installers (kein Gateway/OAuth, Provider-Keys in `.dev.vars`).
- Firewall im LXC: Debian-LXCs haben default keine aktive Firewall; Port 8093 ist daher frei.
  Wer `firewall=1` im CT aktiviert, muss 8093/tcp selbst freigeben.

## Repo-Struktur

```
install/everyapp.sh   Installer (Community-Scripts-konform, Variablen oben, set -euo pipefail)
tests/harness.sh      Mock-Harness (Fakebin + unshare -r): alle Pfade, ohne echtes Proxmox
README.md             diese Datei
```
