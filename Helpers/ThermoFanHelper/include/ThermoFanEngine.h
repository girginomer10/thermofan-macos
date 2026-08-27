#ifndef THERMOFAN_ENGINE_H
#define THERMOFAN_ENGINE_H

#include <stdint.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define THERMOFAN_ENGINE_PROTOCOL_VERSION 9
#define THERMOFAN_ENGINE_RECOVERY_REQUIRED 75

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
int thermofan_engine_apply(
    int fan_index,
    int mode,
    int rpm,
    const ThermoFanProcessIdentity *owner_identity,
    int require_owned_fan
);

/// Unconditionally returns every durably recorded ThermoFan-owned fan to Auto.
/// A daemon must call this successfully before accepting any XPC request.
int thermofan_engine_recover_startup(void);

/// Returns all fans to Auto only when the durable owner exactly matches identity.
int thermofan_engine_return_all(
    const ThermoFanProcessIdentity *owner_identity
);

/// Quiesces and removes only the four known root-owned legacy helper paths,
/// drains exact-path processes boundedly, then repeats automatic recovery.
/// This is refused until thermofan_engine_recover_startup() succeeded in-process;
/// any failure leaves subsequent manual writes blocked.
int thermofan_engine_remove_legacy_helpers(void);

/// Registers an exact-process NOTE_EXIT watch. The caller owns the returned fd.
/// A nonnegative result proves the watch was armed before the function returned.
int thermofan_engine_open_process_exit_watch(
    const ThermoFanProcessIdentity *identity
);

/// Blocks for the registered event and succeeds only for an exact NOTE_EXIT.
int thermofan_engine_consume_process_exit_watch(int watch_fd);

#ifdef __cplusplus
}
#endif

#endif
