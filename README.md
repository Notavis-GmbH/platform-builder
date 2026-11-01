# Platform Builder

## Install
```shell
cd ~ && wget -O selfInstaller.sh https://raw.githubusercontent.com/Notavis-GmbH/platform-builder/feat/siemens2/selfInstaller.sh && bash selfInstaller.sh
```

To install a specific version, pass its git tag as an argument. If omitted, the latest commit on the `feat/siemens2` branch is used.
```shell
cd ~ && wget -O selfInstaller.sh https://raw.githubusercontent.com/Notavis-GmbH/platform-builder/feat/siemens2/selfInstaller.sh && bash selfInstaller.sh v1.2.3
```

The installer asks for the sudo password once at the start. At the end it lists failed steps and exits with an
error if there were any; the step logs are in `~/.platform_installer_logs` (archives: `~/platform_install_logs_*.tar.gz`).

### Device data
Settings, users and device configuration are not in git, updates keep them. The repo only contains the defaults in
`app_platform/defaults/`; `install.sh` creates missing files from them, existing files are never overwritten.
`selfInstaller.sh` additionally backs them up to `/opt/platform-builder/device-backup/` before updating and restores them.

| File (in `app_platform/`) | Content |
|---|---|
| `.env` | device variables (e.g. `CONTROL_INTERFACE`, `START_CAMERA_AT_STARTUP`) |
| `settings/*.json` (except `filterControls.json`, `navServices.json`) | camera, app and backend settings, users |
| `ftp/ftpsettings.json` | FTP upload settings |
| `frpc/frpc.local.toml` | frp remote access of this device (`remotePort`, proxy `name`), preferred over `frpc.toml` |
| `docker-compose.override.yml` | device-specific compose changes, loaded on top of `docker-compose.siemens.yml` |
| `history_images/app.csv` | measurement history |
## Update
1. Connect to console
    1. In the desktop open a terminal. The desktop app can be close with Alt-F4

    2. Type in the browser: [http://raspberrypi:3000/ttyd](http://raspberrypi:3000/ttyd)
   
<img width="710" height="308" alt="image" src="https://github.com/user-attachments/assets/df192a85-8586-4838-ab26-e00930d91968" />

  
2. Copy the command above and insert in the console and press ENTER. The update continues even if the browser
   console gets disconnected (e.g. when the update restarts it); the result is then in the logs (see above).
3. Restart the device
4. Version on the top right corner should be changed in case of a successfull update
   

<img width="469" height="85" alt="image" src="https://github.com/user-attachments/assets/c01e087d-2234-4a2b-86aa-2bf656d0a666" />
