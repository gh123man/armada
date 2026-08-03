# Deep-sleep charger wake on Qualcomm handhelds

## Why the wake source is broad

SM8550-class devices do not deliver USB-C charger attachment to Linux through
the DWC3 gadget PHY while the PHY is powered down. Type-C and charging state are
owned by Qualcomm's `charger_pd` firmware on the ADSP and reach Linux through
the `PMIC_RTR_ADSP_APPS` GLINK service.

This is also how published Android kernels for the same SoC are structured:

- The OnePlus SM8550 Kalama device tree places the battery charger and UCSI
  clients under PMIC GLINK on the ADSP:
  <https://github.com/OnePlusOSS/android_kernel_modules_and_devicetree_oneplus_sm8550/blob/0241347436d48df011e2a6f6fe2d8740c26a379c/kernel_platform/qcom/proprietary/devicetree/qcom/kalama.dtsi>
- Qualcomm's downstream IPCC driver enables the shared parent IRQ as a wake
  source:
  <https://github.com/OnePlusOSS/android_kernel_oneplus_sm8550/blob/c462ef8ffab7a58e035ee04705b16cdfced494b1/drivers/mailbox/qcom-ipcc.c#L240-L247>
- Its GLINK transport calls `pm_system_wakeup()` on the first GLINK packet
  received during suspend, before the packet's client channel is decoded:
  <https://github.com/OnePlusOSS/android_kernel_oneplus_sm8550/blob/c462ef8ffab7a58e035ee04705b16cdfced494b1/drivers/rpmsg/qcom_glink_native.c#L1482-L1491>
- The battery client subsequently publishes the decoded power-supply change and
  takes a short wake lock so userspace can process it:
  <https://github.com/OnePlusOSS/android_kernel_oneplus_sm8550/blob/c462ef8ffab7a58e035ee04705b16cdfced494b1/drivers/power/supply/qti_battery_charger.c#L836-L885>

Motorola's published Qualcomm kernel uses the same unconditional IPCC parent
wake, and another SM8550 Android tree contains the same first-packet GLINK wake
logic:

- <https://github.com/MotorolaMobilityLLC/kernel-msm/blob/0450c5076a8ec9415a10888c8c183ef6ff5f91b8/drivers/mailbox/qcom-ipcc.c>
- <https://github.com/samsung-sm8550/android_kernel_samsung_sm8550/blob/cdb041119cfd53132ecd2ae1eb91a680473f5fc9/drivers/rpmsg/qcom_glink_native.c>

The interrupt controller therefore cannot select charger packets while the AP
is asleep. It only knows that the ADSP has queued GLINK data. Packet semantics
become available after the AP has started resuming.

ROCKNIX PR #2954 identified a concrete source of background traffic on the RP6:
the ADSP charger firmware sends an unsolicited `BATTMGR_NOTIFICATION` (opcode
`0x7`) shortly after suspend entry. Its IPCC patch removes `IRQF_NO_SUSPEND` so
that notification is deferred instead of being handled against suspended
devices. Armada carries that fix. Charger-attach support then deliberately
marks the selected ADSP GLINK edge wake-capable, so a separate wake policy is
still required to distinguish a real offline-to-online transition from those
unsolicited transport notifications:

<https://github.com/ROCKNIX/distribution/pull/2954>

## Why Android does not expose every transport wake

Android combines this broad kernel wake source with a continuously running
autosuspend policy. AOSP's SystemSuspend service repeatedly uses
`/sys/power/wakeup_count` and `/sys/power/state` whenever no wake lock requires
the system to remain awake:

<https://source.android.com/docs/core/power/systemsuspend>

When external power actually changes, Android's PowerManagerService can turn
that background resume into an intentional, visible wake:

<https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android13-release/services/core/java/com/android/server/power/PowerManagerService.java>

Armada uses systemd's one-shot suspend transaction instead. Without an
additional policy, every GLINK interrupt ends that transaction and thaws the
graphical session, including unrelated ADSP traffic.

## Armada implementation

The kernel side deliberately follows the Qualcomm architecture:

1. Propagate wake configuration from the selected ADSP GLINK child IRQ through
   the shared IPCC parent.
2. Mark only the Retroid Pocket 6 ADSP GLINK edge as a wake source.
3. Defer GLINK callbacks until orderly device resume instead of using
   `IRQF_NO_SUSPEND`.

The userspace side fills Android's wake-policy role while systemd-sleep still
has `user.slice` frozen:

1. Snapshot external-power state and the physical power-key interrupt count
   before entering suspend. Keep the external-power snapshot updated across
   hidden background resumes, so unplug followed by replug is recognized as a
   new offline-to-online transition within the same suspend transaction.
2. Read the standard kernel wake IRQ record from `/sys/power/pm_wakeup_irq`,
   enabled by `CONFIG_PM_SLEEP_DEBUG`, and resolve it through `/proc/interrupts`
   in the system-sleep hook.
3. Accept an increased physical power-key count or a real external-power
   transition from offline to online.
4. For a positively identified GLINK/IPCC transport wake with no charger
   transition, use the atomic `wakeup_count` protocol and return directly to
   `mem` sleep.
5. If another notification races the `wakeup_count`/`power/state` handshake and
   the kernel rejects the resuspend with `-EBUSY`, re-check the power key and
   charger state and retry the already-classified background transaction. The
   retry count is bounded so a persistent kernel failure still resumes safely.
6. Treat missing or unrecognized data as a normal resume. Classification must
   fail open so diagnostics or future kernel changes cannot trap the device in
   suspend.

This does not recursively invoke systemd, manipulate Gamescope, or run display
commands during resume. Pre/post system-sleep hooks run inside the existing
systemd-sleep process-freeze boundary.

### Why the standard wake IRQ record is sufficient

Hardware traces on the Retroid Pocket 6 show that the GIC IPCC summary IRQ 13
returns the SoC from firmware deep sleep. Linux then dispatches the nested
GLINK child IRQ 230 after noirq device resume. The generic IRQ wakeup code
records IRQ 13, which is enough for policy: both `ipcc_0` and `glink-smem` are
transport wakes whose packet meaning is only available later in resume.

`/sys/power/pm_wakeup_irq` is compiled only when `CONFIG_PM_DEBUG=y`, which
derives `CONFIG_PM_SLEEP_DEBUG=y`. Armada uses these options for the standard
wake-reason attribute; verbose `pm_debug_messages` and `pm_print_times` remain
off. An early test kernel omitted the options, so the attribute did not exist
and the deliberately fail-open policy classified every transport wake as
`unknown`. Enabling the interface is sufficient; no custom IPCC wake-reason
patch is required.

The attribute has been documented in Linux's sysfs ABI since April 2015, with
the explicit purpose of reporting the first armed IRQ seen during the most
recent suspend/resume cycle:

<https://github.com/torvalds/linux/blob/master/Documentation/ABI/testing/sysfs-power>

It remains in the `ABI/testing` category rather than `ABI/stable`, so the
userspace policy checks for its presence and fails open to a normal resume if
it is unavailable. Armada does not enable `PM_ADVANCED_DEBUG`, `PM_TEST_SUSPEND`,
or the PM watchdog.

The relevant upstream implementations are:

- generic IRQ wake accounting:
  <https://github.com/torvalds/linux/blob/master/kernel/irq/pm.c>
- wake IRQ storage and access:
  <https://github.com/torvalds/linux/blob/master/drivers/base/power/wakeup.c>
- the sysfs attribute and its Kconfig guard:
  <https://github.com/torvalds/linux/blob/master/kernel/power/main.c>

The userspace policy also compares the physical power-key interrupt counter
because power-button resume can have unrelated GLINK traffic queued by the time
the IPCC handler runs.

## Rejected alternatives

- **DWC3 device-mode PHY wake IRQs:** the IRQs could be armed, but physical
  charger attachment did not assert them while the PHY was powered down.
- **Cable-orientation GPIO:** the exposed GPIO changes with plug orientation,
  not attachment, and is therefore not a usable VBUS signal.
- **Recursive suspend plus compositor blanking:** this exposed part of the
  graphical resume path, produced display flashes, and broke ordinary resume.
- **Charger-only filtering in the interrupt handler:** the GLINK packet owner
  and opcode are not known until after the shared IPCC wake has resumed the AP.
