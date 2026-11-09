#!/bin/sh
# Keep the primary beta URL while using the same installer as SSH and LuCI.
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
set -o pipefail
wget -T 30 -O - https://raw.githubusercontent.com/Zagorsky17/LoKi/main/install.sh | sh
