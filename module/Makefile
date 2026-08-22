obj-m += egpu_rp_window.o

# CURDIR, not PWD. PWD is a shell variable and "make -C" does not update it, so
# with "make -C $SELFDIR/module" the M= argument pointed one directory too high
# and the build silently looked in the wrong place. CURDIR is make's own
# variable and holds the correct value after -C.
KDIR ?= /lib/modules/$(shell uname -r)/build

# WHY THE BUILD HAPPENS SOMEWHERE ELSE
#
# kbuild writes every artifact next to the sources it is given, and it has no
# equivalent of "O=" for external modules ("M=" IS the output directory). Built
# under sudo, that left this directory full of root-owned .o/.mod/.cmd files
# that the normal user could then neither overwrite nor delete.
#
# So the sources are copied into BUILDDIR and kbuild is pointed at that copy.
# This directory stays source-only, and everything generated is disposable:
# "make clean" removes BUILDDIR outright.
BUILDDIR ?= $(abspath $(CURDIR)/../build/module)
SRCS     := egpu_rp_window.c Makefile
KO        = $(BUILDDIR)/egpu_rp_window.ko

.PHONY: all clean print-ko print-builddir

all:
	@mkdir -p "$(BUILDDIR)"
	@cp -p $(addprefix $(CURDIR)/,$(SRCS)) "$(BUILDDIR)/"
	$(MAKE) -C $(KDIR) M="$(BUILDDIR)" modules
	@echo "  module: $(KO)"

clean:
	@# Guard: never let an empty BUILDDIR turn this into "rm -rf /".
	@test -n "$(BUILDDIR)" || { echo "BUILDDIR is empty - refusing to clean" >&2; exit 1; }
	@if [ -f "$(BUILDDIR)/Makefile" ]; then \
	    $(MAKE) -C $(KDIR) M="$(BUILDDIR)" clean >/dev/null 2>&1 || true; \
	fi
	@rm -rf "$(BUILDDIR)"
	@echo "  removed $(BUILDDIR)"

# So the scripts do not have to hardcode the path.
print-ko:
	@echo "$(KO)"

print-builddir:
	@echo "$(BUILDDIR)"
