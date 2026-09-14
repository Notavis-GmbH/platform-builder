# Platform Builder

## Install
```shell
cd ~ && wget -N --timestamping https://raw.githubusercontent.com/Notavis-GmbH/platform-builder/feat/siemens2/selfInstaller.sh && bash selfInstaller.sh
```

To install a specific version, pass its git tag as an argument. If omitted, the latest commit on the `feat/siemens2` branch is used.
```shell
wget -O selfInstaller.sh https://raw.githubusercontent.com/Notavis-GmbH/platform-builder/feat/siemens2/selfInstaller.sh && bash selfInstaller.sh v1.2.3
```
## Update
1. Connect to console
    1. In the desktop open a terminal. The desktop app can be close with Alt-F4

    2. Type in the browser: [http://raspberrypi:3000/ttyd](http://raspberrypi:3000/ttyd)
   
<img width="710" height="308" alt="image" src="https://github.com/user-attachments/assets/df192a85-8586-4838-ab26-e00930d91968" />

  
2. Copy the command above and insert in the console and press ENTER
3. Restart the device
4. Version on the top right corner should be changed in case of a successfull update
   

<img width="469" height="85" alt="image" src="https://github.com/user-attachments/assets/c01e087d-2234-4a2b-86aa-2bf656d0a666" />
