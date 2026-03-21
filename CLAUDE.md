# flowbit OS – Projekt-Kontext

## Übersicht
Bootbares Arch Linux IT-Toolkit mit Web-UI für IT-Techniker.
- **Repo:** github.com/AgimDur/flowbit-os
- **Download:** kiosk.flowbit.ch
- **Version:** v3.1 (40 Features)

## Stack
- Python HTTP Server (`server.py` ~2650 Zeilen) auf Port 8080
- Chromium Kiosk + Openbox
- Web-UI SPA (`index.html` ~1770 Zeilen)
- CLI-Module: kit.sh, wiper.sh, sysinfo.sh, network.sh, hwtest.sh, biostools.sh, backup.sh

## Build & Test (auf Hetzner pveh1)
```bash
# ISO bauen (CT 105)
pct exec 105 -- bash -c "cd /root/kit-iso && rm -rf /tmp/archiso-kit-work && mkarchiso -v -w /tmp/archiso-kit-work -o /root ."

# ISO in Test-VM laden (VM 106)
cp /datapool/subvol-105-disk-0/root/<iso> /var/lib/vz/template/iso/
qm set 106 -ide2 local:iso/<iso>,media=cdrom
qm reboot 106
```

## Auto-Update Server
- CT 114, Debian 12 + nginx, IP: 10.11.10.114
- manifest.json: Version, SHA256, ISO-URL
- Publish: `./publish-update.sh`

## Dateistruktur
```
/opt/kit/
├── kit.sh                    # CLI Hauptmenü
├── modules/                  # Bash-Module
└── webui/
    ├── server.py             # Python HTTP Server
    └── static/
        └── index.html        # Web-UI (SPA)
```

## Arbeitsregeln
- Änderungen an server.py und index.html → ISO neu bauen und testen
- Packages in packages.x86_64 pflegen
- Deutsch (CH) für UI, Englisch für Code
- Nach Änderungen: Notion Projekt-Seite updaten (ID: 324c4064-ffc7-8115-adfc-c11b2559252d)
