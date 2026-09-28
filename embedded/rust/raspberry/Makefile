# Build every kernel module in modules/ and drivers/ against the kernel the
# box compiled.
#
# Each directory in modules/ and drivers/ is one module: a Makefile in the
# kbuild style, naming the object or objects to build.
#
# A C module:
#
#	obj-m += hello.o
#
# A Rust module, where the Rust sources are built by the kernel's own Rust
# support:
#
#	obj-m += rust_hello.o
#	rust_hello-objs += rust_hello_core.o
#
# Add a directory, run 'make', and the module is built against the kernel in
# Kdir. Override Kdir to build against your own tree ($KERNEL_SRC).
#
# The box calls this Makefile itself when you run './raspberry_pi_box.sh
# build', so you normally do not need to run it by hand.

Kdir ?= ../linux-6.1.34

MODULES := $(patsubst %/,%,$(wildcard modules/*/))
DRIVERS := $(patsubst %/,%,$(wildcard drivers/*/))

all: $(MODULES) $(DRIVERS)

$(MODULES) $(DRIVERS):
	$(MAKE) -C $(Kdir) M=$(CURDIR)/$@ modules

clean:
	@for m in $(MODULES) $(DRIVERS); do \
		$(MAKE) -C $(Kdir) M=$(CURDIR)/$$m clean; \
	done

.PHONY: all clean $(MODULES) $(DRIVERS)
