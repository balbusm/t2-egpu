// SPDX-License-Identifier: GPL-2.0
/*
 * egpu_rp_window - move a Thunderbolt root port's prefetchable window above
 * 4 GB, so that an eGPU gets its full 256 MB BAR1.
 *
 * MacBookPro15,1 (T2, Coffee Lake). Apple's firmware gives root port 00:01.1
 * a prefetchable window of 0xc1700000-0xcf6fffff = 224 MB, entirely BELOW
 * 4 GB. Linux CLAIMS that value and never allocates it afresh - so it never
 * reaches pci_bus_alloc_resource(), where for 64-bit windows the pci_high
 * region (>4 GB) is tried first. An RTX 4080 needs 288 MB (BAR1 256 + BAR3
 * 32) and simply cannot fit.
 *
 * Meanwhile the root bus has [mem 0x4000000000-0x7fffffffff] = 256 GB free,
 * untouched.
 *
 * This module does ONE thing: it repoints 00:01.1's prefetchable window at an
 * address above 4 GB, both in the kernel's resource tree and in the bridge's
 * registers. It does NOT touch the nested bridge sizing or the BAR layout -
 * the kernel allocator does that on the next rescan. That is why it is an
 * order of magnitude smaller than egpu_bar.c from t2-egpu-linux, which
 * inserted every BAR by hand and had to set res->parent itself.
 *
 * It does NOT remove the root port - removing 00:01.1 is precisely what used
 * to reset the machine.
 *
 * The subtree has to be removed first:
 *   echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove
 * because a window with assigned children cannot be moved.
 */

#include <linux/module.h>
#include <linux/kernel.h>
#include <linux/pci.h>
#include <linux/ioport.h>

/* A bridge's prefetchable window is the third bridge resource. */
#define PREF_IDX (PCI_BRIDGE_RESOURCES + 2)

static unsigned int rp_bus = 0x00;
static unsigned int rp_dev = 0x01;
static unsigned int rp_fn  = 0x01;
static unsigned long long win_base = 0x4010000000ULL;
static unsigned long win_mb = 1024;
static bool program_hw = true;

module_param(rp_bus, uint, 0444);
MODULE_PARM_DESC(rp_bus, "root port bus number (default 0x00)");
module_param(rp_dev, uint, 0444);
MODULE_PARM_DESC(rp_dev, "root port device number (default 0x01)");
module_param(rp_fn, uint, 0444);
MODULE_PARM_DESC(rp_fn, "root port function number (default 0x01)");
module_param(win_base, ullong, 0444);
MODULE_PARM_DESC(win_base, "base address of the new window (default 0x4010000000)");
module_param(win_mb, ulong, 0444);
MODULE_PARM_DESC(win_mb, "size of the new window in MB (default 1024)");
module_param(program_hw, bool, 0444);
MODULE_PARM_DESC(program_hw, "write the bridge registers as well (default yes)");

static struct pci_dev *rp;

/*
 * The bridge's prefetchable window registers: bits 15:4 of each 16-bit
 * register hold address bits 31:20, and the low nibble is read-only and
 * reports 64-bit support. The upper 32 bits have their own 32-bit registers.
 * The limit is inclusive, with the low 20 bits implicitly 0xfffff.
 */
static void egpu_program_window(struct pci_dev *bridge, struct resource *res)
{
	u16 lo;

	pci_write_config_dword(bridge, PCI_PREF_BASE_UPPER32,
			       upper_32_bits(res->start));
	pci_write_config_dword(bridge, PCI_PREF_LIMIT_UPPER32,
			       upper_32_bits(res->end));

	lo = (u16)((lower_32_bits(res->start) >> 16) & 0xfff0) |
	     PCI_PREF_RANGE_TYPE_64;
	pci_write_config_word(bridge, PCI_PREF_MEMORY_BASE, lo);

	lo = (u16)((lower_32_bits(res->end) >> 16) & 0xfff0) |
	     PCI_PREF_RANGE_TYPE_64;
	pci_write_config_word(bridge, PCI_PREF_MEMORY_LIMIT, lo);
}

static int __init egpu_rp_window_init(void)
{
	resource_size_t size = (resource_size_t)win_mb << 20;
	struct resource *res;
	int ret;

	rp = pci_get_domain_bus_and_slot(0, rp_bus, PCI_DEVFN(rp_dev, rp_fn));
	if (!rp) {
		pr_err("egpu_rp_window: could not find 0000:%02x:%02x.%x\n",
		       rp_bus, rp_dev, rp_fn);
		return -ENODEV;
	}

	if (rp->hdr_type != PCI_HEADER_TYPE_BRIDGE) {
		pci_err(rp, "egpu_rp_window: not a bridge\n");
		ret = -EINVAL;
		goto out;
	}

	res = &rp->resource[PREF_IDX];
	pci_info(rp, "egpu_rp_window: pref window before: %pR (flags=%#lx)\n",
		 res, res->flags);

	if (!(res->flags & IORESOURCE_MEM)) {
		pci_err(rp, "egpu_rp_window: pref window is not a MEM resource\n");
		ret = -EINVAL;
		goto out;
	}

	/* Children in the window = subtree still present. Moving it would cut them off. */
	if (res->child) {
		pci_err(rp, "egpu_rp_window: window has assigned children. First run:\n");
		pci_err(rp, "  echo 1 > /sys/bus/pci/devices/0000:02:00.0/remove\n");
		ret = -EBUSY;
		goto out;
	}

	/* Detaches the resource from the root bus tree and sets IORESOURCE_UNSET. */
	pci_release_resource(rp, PREF_IDX);

	res->start = (resource_size_t)win_base;
	res->end   = (resource_size_t)win_base + size - 1;
	res->flags |= IORESOURCE_MEM | IORESOURCE_PREFETCH | IORESOURCE_MEM_64;
	res->flags &= ~IORESOURCE_UNSET;	/* pci_claim_resource requires this */

	ret = pci_claim_resource(rp, PREF_IDX);
	if (ret) {
		pci_err(rp, "egpu_rp_window: pci_claim_resource(%pR) = %d\n",
			res, ret);
		pci_err(rp, "egpu_rp_window: window left unattached - reboot\n");
		goto out;
	}

	pci_info(rp, "egpu_rp_window: pref window after: %pR\n", res);

	if (res->start < 0x100000000ULL)
		pci_warn(rp, "egpu_rp_window: WARNING - window is still below 4 GB\n");

	if (program_hw) {
		egpu_program_window(rp, res);
		pci_info(rp, "egpu_rp_window: bridge registers programmed\n");
	} else {
		pci_info(rp, "egpu_rp_window: program_hw=0, leaving the registers alone\n");
	}

	pci_info(rp, "egpu_rp_window: done. Now rescan:\n");
	pci_info(rp, "  echo 1 > /sys/bus/pci/devices/%s/rescan\n", pci_name(rp));
	return 0;

out:
	pci_dev_put(rp);
	rp = NULL;
	return ret;
}

static void __exit egpu_rp_window_exit(void)
{
	if (!rp)
		return;
	pci_warn(rp, "egpu_rp_window: rmmod does NOT restore the old window.\n");
	pci_warn(rp, "egpu_rp_window: returning to the firmware state = reboot.\n");
	pci_dev_put(rp);
	rp = NULL;
}

module_init(egpu_rp_window_init);
module_exit(egpu_rp_window_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Moves a Thunderbolt root port prefetchable window above 4 GB");
