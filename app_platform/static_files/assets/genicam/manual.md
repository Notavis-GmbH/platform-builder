 # Startup
  
  ## Connect

<ol>
 <li>Delete the default route </li>
 Add new route to the gateway 
 <li>If a direct connection is chosen, the connected PC must have an ipV4 address between 169.254.0.0 and 169.254.255.255.
 
 On Windows PC toggle on auto ip.</li>
 <li>Open a webbrowser (Chrome, Firefox, or Edge)</li>
 <li>Enter the address: http://raspi4:8080</li>
  <li>Start screen is visible</li>



 </ol>

 ## SSH Connect
SSH Connection is needed, if any settings on the compute module has to be set.

```bash
ssh raspberrypi@raspi4
```
# Live View
## Controls
![image](assets/manual/controls.png)
<ol>
<li>Play button stops or pause image stream
</li>
<li>Capture button saves the current image on the compute module. The image roll above is updated
</li>
<li>The download button pushs the current image to be downloaded from the module to the connected PC
</li>
<li>The upload button pushs the current image to the FTP server
</li>
</ol>

# Imager Selection

  ![image](assets/manual/ImagerSelection.png)

  <ol>
  <li>Choose the connected sensor</li>
  <li>The different modes are specifying the format, the triggering and number of lanes that are used</li>
  <li>Clicking on save, restarts the compute module and  switches the config to the selected one</li>
  </ol>


# FTP Settings
  ![image](assets/manual/ftpscreenshot.png)

<ol>
<li>If active, the ftp server is connected and in case of stored images, the image is uploaded</li>
<li>Host address for ftp server</li>
<li>Port number (default: 21)</li>
<li>Password for the user</li>
<li>User for the ftp login</li>
<li>Save button stores the config on the device and restarts the ftp client</li>
<li>Reset button restores the last stored values</li>
<li>The black console shows the latest status. Error, last uploaded images or deactivated client</li>
</ol>

# Hardware

## Pins

![image](assets/manual/inputs.png)
