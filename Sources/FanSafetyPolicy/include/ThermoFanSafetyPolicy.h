#ifndef THERMOFAN_SAFETY_POLICY_H
#define THERMOFAN_SAFETY_POLICY_H

#include <stddef.h>
#include <stdint.h>
#include <mach/mach_types.h>

#define THERMOFAN_LEGACY_FAN_STATE_SIZE 28u

typedef struct {
    uint32_t magic;
    uint32_t version;
    int32_t owner_pid;
    uint32_t touched_mask;
    uint32_t refcount;
    uint32_t flags;
    uint32_t checksum;
} ThermoFanLegacyFanState;

int32_t thermofan_status_after_persisted_ownership_check(
    int32_t status,
    int32_t recovery_exit_code,
    int32_t state_present,
    int32_t owner_matches,
    int32_t fan_owned
);

int32_t thermofan_process_identity_matches(
    int32_t stored_pid,
    uint64_t stored_start_seconds,
    uint64_t stored_start_microseconds,
    int32_t candidate_pid,
    uint64_t candidate_start_seconds,
    uint64_t candidate_start_microseconds
);

int32_t thermofan_decode_legacy_fan_state(
    const uint8_t *bytes,
    size_t length,
    ThermoFanLegacyFanState *out_state
);

int32_t thermofan_legacy_migration_allows_new_write(
    int32_t automatic_recovery_verified
);

/// Returns the caller's Mach task port through C so Swift 6.0 does not import
/// the SDK's mutable mach_task_self_ compatibility global directly.
mach_port_t thermofan_current_task_port(void);

#endif
