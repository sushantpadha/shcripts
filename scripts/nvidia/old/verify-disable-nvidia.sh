echo ">>> Should say intel..."
prime-select query

echo ">>> Should output error..."
nvidia-smi

echo ">>> Output nothing..."
lsmod | grep nvidia           # → no output

echo ">>> driver in use: none; modules may be loaded..."
lspci -k | grep -A 3 -i nvidia # → driver in use: (none)

echo ">>> Suspended"
cat /sys/bus/pci/devices/*/power/runtime_status | grep -i suspended

echo ">>> D3cold is best"
cat /sys/bus/pci/devices/0000\:01\:00.0/power_status

