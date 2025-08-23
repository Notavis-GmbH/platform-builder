import os
import subprocess

# Define the base path
base_path = "/sys/devices/platform/soc/"

# Use find and grep to find all v4l2 devices
command = "find . | grep video4linux | grep dev_debug"
v4l2_devices = subprocess.check_output(command, shell=True, cwd=base_path).decode().splitlines()

# For each v4l2 device, write 0x3 to dev_debug
for dev_debug_path in v4l2_devices:
    abs_path = os.path.join(base_path, dev_debug_path)
    print("Found {}".format(abs_path))

    if os.path.exists(abs_path):
        print("Writing 0x3 to {}".format(abs_path))
        with open(abs_path, 'w') as f:
            f.write('0x3')

with open("/sys/module/videobuf2_common/parameters/debug", 'w') as f:
    f.write('0x3')
with open("/sys/module/videobuf2_v4l2/parameters/debug", 'w') as f:
    f.write('0x3')
