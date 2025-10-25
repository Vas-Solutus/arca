# Makefile for vsock_tap_bridge kernel module

# Module name
obj-m += vsock_tap_bridge.o

# Kernel source directory (adjust for your kernel build)
KDIR := /lib/modules/$(shell uname -r)/build

# Current directory
PWD := $(shell pwd)

# Default target - build the module
all:
	$(MAKE) -C $(KDIR) M=$(PWD) modules

# Clean build artifacts
clean:
	$(MAKE) -C $(KDIR) M=$(PWD) clean

# Install module (requires root)
install:
	$(MAKE) -C $(KDIR) M=$(PWD) modules_install
	depmod -a

# Load module into running kernel
load:
	insmod vsock_tap_bridge.ko vsock_port=5000 tap_name=tap0 ip_addr=172.18.0.2

# Unload module
unload:
	rmmod vsock_tap_bridge

# View kernel log messages
log:
	dmesg | tail -50

.PHONY: all clean install load unload log
