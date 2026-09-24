#ifndef THERMOFAN_ENGINE_H
#define THERMOFAN_ENGINE_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define THERMOFAN_ENGINE_PROTOCOL_VERSION 9
#define THERMOFAN_ENGINE_RECOVERY_REQUIRED 75

/// Returned by thermofan_engine_consume_process_exit_watch() when its bounded
/// one-second wait ends without an event: no exit is confirmed yet and the
/// watch stays armed.
#define THERMOFAN_ENGINE_EXIT_NOT_CONFIRMED 2

/// Returned by thermofan_engine_apply() when require_owned_fan is 1 and durable
/// state does not show owner_identity holding that fan. No hardware write was
/// attempted and no recovery obligation exists.
#define THERMOFAN_ENGINE_FAN_NOT_OWNED 3

typedef struct {
    int32_t pid;
    uint64_t start_seconds;
    uint64_t start_microseconds;
} ThermoFanProcessIdentity;

/// Returns the decimal protocol version string (currently "9").
const char *thermofan_engine_version(void);

/// Reads a PID plus its kernel-reported start time so PID reuse is detectable.
int thermofan_engine_read_process_identity(
    pid_t pid,
    ThermoFanProcessIdentity *identity
);

/// Applies one bounded fan command. mode is 0 Auto, 1 Fixed, or 2 Curve.
/// The identity must have been derived from the authenticated XPC peer.
/// require_owned_fan (0 or 1) limits the call to a fan that durable state shows
/// owner_identity (PID plus start time) holding.
///
/// Returns:
/// - 0: the command was verified on hardware by readback.
/// - 1: rejected or failed; durable state does not show this owner holding
///   the fan, so the failure created no recovery obligation.
/// - THERMOFAN_ENGINE_FAN_NOT_OWNED: see above; nothing was written.
/// - THERMOFAN_ENGINE_RECOVERY_REQUIRED (75), with two distinct meanings that
///   are logged differently so diagnostics can tell them apart:
///   - "status 75 (write barrier)": a Fixed or Curve command arrived before
///     startup recovery and legacy helper retirement were verified. No
///     hardware was accessed.
///   - "status 75 (unverified hardware state)": the fan may be outside Auto
///     because a rollback could not be verified, the fan is still durably
///     owned by this client after a failure, or fan access could not be
///     serialized while durable ownership was unreadable.
///   In both cases the caller must keep recovery active and manual writes
///   blocked until recovery succeeds.
int thermofan_engine_apply(
    int fan_index,
    int mode,
    int rpm,
    const ThermoFanProcessIdentity *owner_identity,
    int require_owned_fan
);

/// Unconditionally returns every durably recorded ThermoFan-owned fan to Auto.
/// Records that earlier helpers left directly in /var/run are recovered to
/// Auto and then removed; current state lives in the root-only /var/run/thermofan.
/// A daemon must call this successfully before accepting any manual write. Each
/// call also blocks manual writes until thermofan_engine_remove_legacy_helpers()
/// succeeds again. Returns 0, THERMOFAN_ENGINE_RECOVERY_REQUIRED, or 1 when not
/// running as root.
int thermofan_engine_recover_startup(void);

/// Returns all fans to Auto only when the durable owner exactly matches identity.
/// A record left by an earlier helper at the legacy /var/run location is also
/// recovered to Auto and removed. Returns 0, THERMOFAN_ENGINE_RECOVERY_REQUIRED,
/// or 1 for an invalid identity or a non-root caller.
int thermofan_engine_return_all(
    const ThermoFanProcessIdentity *owner_identity
);

/// Quiesces and removes only the five known root-owned legacy helper paths
/// (three executables, including the v8 ".installing" staging copy, and two
/// version files), drains legacy helper processes boundedly, then repeats
/// automatic recovery. Processes found running a legacy executable are kept by
/// PID and start time for the daemon's lifetime, and later calls wait for those
/// exact processes. When a legacy executable was found, the final recovery
/// also returns every fan whose per-fan mode key reads Manual to Auto, because
/// pre-v9 helpers kept no usable durable record; that scan stays pending across
/// failed calls. Each call consumes the proof from
/// thermofan_engine_recover_startup(): after a failed call, startup recovery
/// must succeed again before a retry. Returns 0 only when everything was
/// verified; any failure leaves subsequent manual writes blocked.
int thermofan_engine_remove_legacy_helpers(void);

/// Registers an exact-process NOTE_EXIT watch. The caller owns the returned fd.
/// A nonnegative result proves the watch was armed before the function returned.
int thermofan_engine_open_process_exit_watch(
    const ThermoFanProcessIdentity *identity
);

/// Waits at most one second for the registered event. Returns 0 only for an
/// exact NOTE_EXIT, which proves the watched process exited.
/// THERMOFAN_ENGINE_EXIT_NOT_CONFIRMED means no event arrived within the bound:
/// no exit is confirmed yet and the watch stays armed. 1 means an invalid
/// descriptor, a kevent failure, or an event other than an exact NOTE_EXIT;
/// the exit is not confirmed and the watch may no longer be armed. Every
/// nonzero result must be treated as "exit not confirmed".
int thermofan_engine_consume_process_exit_watch(int watch_fd);

#ifdef __cplusplus
}
#endif

#endif
