<img src="assets/manual/A7670E-Cat-1-HAT-1.jpg">

# Internet access
The internet access over the lte module is realized by an additional ethernet adapter.
Therefore the tool ppp is used
It is preinstalled (`apt-get install ppp`)

# How to setup a new connection
1. A nano SIM card has to be inserted
1. The antenne has to be connected to the coaxial connector
1. The module has to be connected by USB to a port of the board

# How to setup software

1. Connect through ssh by typing in powershell/console:
    ```bash
    ssh raspberrypi@raspi4
    ```
1. Alternative, use the webshell under  <a href="http://raspi4:3000/wetty" target="_blank">http://raspi4:3000/wetty</a>

1. Type in given password 
1. Open config file by 
    ```bash 
    sudo nano /etc/ppp/peers/rnet
    ```
1. Change line 2 for your provider 
    ```
    connect "/usr/sbin/chat -v -f /etc/chatscripts/gprs -T internet.telekom"
    ```
1. Save by Ctrl-X, and save by pressing "y" and "Enter"
1. Open 
    ```bash
    sudo nano /etc/chatscripts/gprs
    ```
1. Change line ```OK      AT+CPIN="XXXX"``` with the pin from the sim card
1. Save the file
1. Start the interface by typing 
    ```bash
    sudo pon rnet
    ```
1. Define the lte as standard port 
    ```bash
    sudo route add default dev ppp0
    ```
1. If you type now `ip a`, there should be an entry with ppp0



