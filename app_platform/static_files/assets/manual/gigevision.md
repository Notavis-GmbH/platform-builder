# Anleitung: Anschließen von Genicam Kameras

## Schritt 1: IP-Adressen vergeben

Um Genicam Kameras an das System anzuschließen, müssen zunächst feste IP-Adressen vergeben werden. Der Namensbereich für die Kameras lautet 10.13.17.X.

```bash
Kamera 1: 10.13.17.1
Kamera 2: 10.13.17.2
...
```

Stellen Sie sicher, dass jede Kamera eine eindeutige IP-Adresse innerhalb dieses Bereichs hat.

## Schritt 2: Anschluss über PoE-Switch oder Modul

Verbinden Sie die Kameras über einen Power-over-Ethernet (PoE) Switch oder ein entsprechendes Modul. Stellen Sie sicher, dass die Verbindungen korrekt sind, um eine reibungslose Kommunikation zu gewährleisten.

## Schritt 3: Anzeige der Kameras in der Oberfläche

Nachdem die Kameras physisch angeschlossen sind, sollten sie in der Oberfläche angezeigt werden. Überprüfen Sie die Verbindung und stellen Sie sicher, dass die Kameras erkannt wurden.

## Schritt 4: Einstellungen für Action Commands

Um Action Commands zu testen, müssen einige Einstellungen vorgenommen werden:

1. Schalten Sie den Trigger-Modus auf "On".
2. Wählen Sie als Trigger-Quelle "Action 1" aus.

## Schritt 5: Abgleich der Parameter

Vergewissern Sie sich, dass die folgenden drei Parameter übereinstimmen:

1. **Action Device Key**
2. **Action Group Mask**
3. **Action Group Key**

Stellen Sie sicher, dass die Konfiguration für alle Kameras identisch ist, um konsistente Ergebnisse zu gewährleisten.

Mit diesen Schritten sollten Sie in der Lage sein, Genicam Kameras erfolgreich an Ihr System anzuschließen und die Action Commands zu testen.
## Schritt 6: Remotezugang

Das Modul besitzt zusätzlich zur Kamera IP Adresse eine zweite IP Adresse, die ist auf DHCP gestellt. 
Über SSH kann auf das Gerät zugegriffen werden. 

```bash
ssh compulab@ucm-imx8m-plus
# PW: compulab
```
Der Root User ist nicht für SSH freigegeben, aber angelegt. Passwort: root
## Schritt 7: Remotezugang

Die Anpassung der IP Adressen ist in der GUI oder auch per Shell möglich
Shellzugriff über das installierte Tool Netplan.io
Dazu wird die Datei /etc/netplan/01-ucm-imx8m-plus.yaml angepasst

```yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      addresses:
        - 10.13.17.20/24
      nameservers:
        addresses: [8.8.8.8, 1.1.1.1]
```
Befehle

```bash
sudo vim /etc/netplan/01-ucm-imx8m-plus.yaml 
# Anpassen der Datei mit Vim oder Nano

sudo netplan generate
# Check der Konfiguration

sudo netplan apply
#Aktivieren der Konfiguration
```
## Schritt 8: Podman Services

Die Kameraadapter und die GUI werden über Podman-compose verwalten

```bash
cd /opt/app
#Einstellungen liegen hier ab

podman-compose up -d
#Anlegen und Starten der Dienste

podman-compose down
#Stoppen und löschen der Dienste

podman-compose restart
#Restart der Dienste (ohne Neuanlegen)

podman-compose logs -f --tail 1000 genicam genicam_2 genicam_3 genicam_4 genicam_5
#Laufende Logs zu den Kameradiensten
```


## Controls:

<img src="assets/manual/ScreenshotGenicam.png">

1. Die untere Anzeige entspricht dem auszusendenen Befehl.
2. Der rechte Button sendet einen ActionCommands in das Netzwerk, dass auf der linken Seite eingestellt ist.
2. **Store images automatically** speichert die Bilder auf dem Gerät direkt nach der Aufnahme. Über die Bildanzeige oben, können die Bilder im Nachgang angeschaut und ggfs. heruntergeladen bzw. auf den FTP übertragen werden