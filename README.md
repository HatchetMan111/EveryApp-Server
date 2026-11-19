# EveryApp-Server

Ein-Command-Installer für die **EveryApp-CLI** ([every-app/every-app](https://github.com/every-app/every-app)) als LXC-Container auf Proxmox VE — im Stil der [Proxmox VE Community Scripts](https://community-scripts.github.io/ProxmoxVE).

> ⚠️ **Ehrlich vorab:** EveryApp deployt die Apps (OpenSEO, OpenCRM, OpenAnalytics, OpenMail …)
> in **deinen eigenen Cloudflare-Account** (Cloudflare Workers, D1, KV, R2 — **R2 muss aktiviert
> sein**, Workers Paid ab ~5 USD/Monat, Domain bei Cloudflare). Das ist der vom Projekt selbst
> vorgesehene Betrieb — eine komplett lokale Ausführung ohne Cloudflare gibt es nicht.
> **Lokal** auf deinem Proxmox läuft die `everyapp`-CLI plus ein Webterminal, mit dem du das
> Cloudflare-Setup im Container durchführst.

## Was ist EveryApp?

EveryApp ([every-app/every-app](https://github.com/every-app/every-app), MIT, ~1k ⭐) ist eine
Plattform für **Open-Source-Alternativen zu bezahlten SaaS-Diensten** — „Open source
alternatives to everything". Statt einen CRM-, SEO- oder Analytics-Abodienst zu mieten,
installierst du die offenen Apps in **deinen eigenen Cloudflare-Account**:

| App | Ersetzt sinngemäß | Was es macht |
|---|---|---|
| **OpenSEO** | Ahrefs/Semrush-Lite | Keyword-Recherche, Rank-Tracking, Site-Audits |
| **OpenCRM** | HubSpot/Pipedrive-Lite | einfaches CRM mit Kontakten & Deals |
| **OpenAnalytics** | Google Analytics | Web-Analytics ohne Cookies/Tracking |
| **OpenMail** | kostenl. Mail-Clients | E-Mail-Postfach mit KI-Assistent |
| **OpenScribe** | Otter/Fireflies | KI-Meeting-Notizen (Mac-Desktop-App) |

„Selbst hosten" heißt bei EveryApp: **einmal `everyapp setup`, und die Plattform wird in
deinen Cloudflare-Account deployed** (Workers + D1 + KV + R2). Du zahlst keine Sitzplatzpreise,
sondern deine eigene Cloudflare-Rechnung (Workers Paid ab ~5 USD/Monat); die Daten liegen in
deinem Account. Ein KI-Agent (Claude Code, Codex …) bekommt über **einen einzigen MCP-Server**
Zugriff auf alle Apps gleichzeitig — das ist der eigentliche Kern des Projekts.

## Wo läuft die Weboberfläche — und was ist hier lokal?

**Die Apps haben echte Weboberflächen — sie laufen aber bei Cloudflare, nicht im LXC:**

| Ebene | Was | Wo erreichbar |
|---|---|---|
| **Apps** (OpenSEO, OpenCRM …) | vollwertige Web-UIs im Browser | `https://<app>.<deine-domain>` **bei Cloudflare** — nach `everyapp setup` |
| **Gateway** | Anmeldung/Consent für Apps & Agent-Zugriff (Cloudflare Access) | ebenfalls unter deiner Domain, bei Cloudflare |
| **CLI** (`everyapp`) | Fernbedienung: `setup`, `install`, `deploy`, `status`, `db`, `secret` | **lokal im LXC** (dieser Installer) |
| **Webterminal** (ttyd, Port 8093) | lokale Browser-Oberfläche für die CLI im Container | `http://<CT-IP>:8093` — das ist die „UI", die dieser Installer bereitstellt |

Der Workflow ist also: im **Webterminal auf deinem Proxmox** die CLI bedienen (`everyapp
install https://github.com/every-app/open-seo` …) — und die App-UIs danach im Browser unter
deiner Cloudflare-Domain öffnen. Eine lokale App-Weboberfläche auf einer Proxmox-IP gibt es
nicht, weil die Apps als Cloudflare-Workers bauen sind (das Projekt hat keinen lokalen
Server-Modus; nur ein experimenteller `everyapp dev`-Modus ohne Gateway/Multi-User).

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

## Erste Schritte — Schritt für Schritt

> Die Installation selbst erzeugt **nur die Steuerzentrale** (CLI + Webterminal im LXC) —
> das ist so gemeint. Die sichtbaren App-Oberflächen entstehen erst in den Schritten unten,
> und zwar **bei Cloudflare unter deiner eigenen Domain**.

### Voraussetzungen (Cloudflare, einmalig — vor Schritt 2)

1. **Cloudflare-Account** (kostenlos)
2. **Deine Domain bei Cloudflare** (Nameserver auf Cloudflare umgestellt; Free-Plan reicht)
3. **Workers Paid** aktivieren: Dashboard → Workers & Pages → Plan → *Workers Paid* (~5 USD/Monat)
4. **R2 aktivieren**: Dashboard → R2 → aktivieren (Payment-Info nötig; 10 GB inklusive).
   Ohne R2 stoppt `setup` mit `enable_r2` + Dashboard-Link.

### Im Webterminal (Browser: `http://<CT-IP>:8093`)

| Schritt | Befehl | Was passiert |
|---|---|---|
| 1 | `everyapp login` | CLI druckt eine **Device-URL + Code** → URL **auf deinem Desktop** im Browser öffnen, Cloudflare-Login bestätigen. Zurück im Terminal: `✓ Logged in`. |
| 2 | `everyapp setup --domain apps.deine-domain.de` | Deployt das Gateway in deinen Account (Worker, D1, KV, R2, Migrationen) — dauert laut Projekt ~15 min. Bei Fehlern druckt die CLI den Fix-Befehl direkt mit. |
| 3 | `everyapp install https://github.com/every-app/open-seo` | Installiert eine App (OpenSEO/OpenCRM/OpenAnalytics/OpenMail). Die CLI druckt die fertige **App-URL**. |
| 4 | App-URL im Browser öffnen | Die **echte Web-UI** der App — Anmeldung läuft über das Gateway (Cloudflare Access). |
| 5 | `everyapp status` | Kontrolle: Gateway, Apps, Login-Status. |
| 6 | optional: `everyapp mcp` | MCP-Server-Verbindung für deinen KI-Agenten (Claude Code, Codex …) — ein Endpoint für alle Apps. |

Telemetrie abschalten (tägl. anonymer Usage-Report): `everyapp telemetry off` (oder bei
`setup` gleich `--no-telemetry` mitgeben).

### Wo sehe ich was?

- **LXC-IP:8093** = Webterminal (schwarzes Fenster, CLI-Banner) — die „Fernbedienung“
- **`https://<app>.apps.deine-domain.de`** (bei Cloudflare) = die eigentlichen App-Web-UIs
- Auf der Proxmox-IP selbst läuft bewusst **keine** App-UI — die Apps sind Cloudflare-Workers

## Optionen

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
