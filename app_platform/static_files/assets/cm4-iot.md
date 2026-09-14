 # Startup



# Hardware
1. The system is based on Raspberrypi Compute Module 4 and a base board 
2. The base board inherits two camera interfaces MIPI CSI-2 for VC imagers
3. Additionally the USB C port is used in this configuration for powering
4. The USB A is configured as an host. USB devices like ethernet adapters can be connected directly or with an USB hub
5. The OS is installed on the SD card.
6. An desktop is installed. It can be displayed by connecting a mini HDMI connector 
7. If an ethernet adapter is used, a dns server is needed, since dhcp is enabled for additional ethernet interfaces
## Connect
<ol>
<li>The device supplies an access point that is avaiable under the SSID <b>notavis-platform builder</b> </li>
<li>The password/PSK is <b>pirmasens</b> </li>
<li>On your device, enable dhcp, since the module assigns by an DNS server</li>
<li>The device by itself is available under the dns name <b>raspberrypi</b> </li>
<li>Alternatively the device  is available under the ip address <b>10.3.141.1</b></li>
<li>For the ethernet port, there are two ip addresses available. The static one is <b>192.168.153.15</b>  with subnet mask <b>255.255.255.0</b> </li>
<li>The second ip is set dynamically by a dhcp server (i.e. a router) on the ethernet port</li>
</ol>

## FTP Server
1. All images recorded on the device are available to be downloaded by the local ftp server. \ 
The button with the camera in the live view stores the images \
 ![image](assets/manual/StoreButton.png)
2. The ftpserver is available under the dns name <b>raspberrypi</b> and the default port <b>21</b> 
3. The password is <b>pirmasens</b>
4. Example with filezilla client \
![image](assets/manual/Filezilla.png)

## Imager Selection
![image](assets/manual/Imager_Selection.png)
1. In the imager selection, first the board type has to be selected.
2. It depends on type of module and base board, if one or two imagers are supported. It is displayed automatically
3. Choose the right model that is or will be installed mechanically on the board
4. Also choose the right mode. In most cases, streaming with 10 bit and 2 lanes fits for the boards
5. Store the one or two interfaces
6. Restart and apply the settings in the end by pressing the last button

## SSH Connect
SSH Connection is needed, if any settings on the compute module has to be set.
From a terminal, the device is available by the following command. 
The password is **pirmasens**
```bash
ssh notavis@raspberrypi
```
Alternatively, a web console is available under http://raspberrypi:3000/wetty

# Live View
## Controls
 ![image](assets/manual/StoreButton.png)
<ol>
<li>Play button stops or pause image stream
</li>
<li>Capture button saves the current image on the compute module. The image roll above is updated
</li>
<li>The download button pushs the current image to be downloaded from the module to the connected PC
</li>
</ol>

# Trigger Intervals
It is possible to trigger the storing of images at specific times. \
Therefore dates can be added. If the are stored, the intervals are automatically started. \
Be aware to use the local time of the device. It could differ from the real time and is therefore displayed at the top \
Only use **Save last image** for this type of camera.  \
![image](assets/manual/TriggerIntervals.png)
