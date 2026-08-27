#include "ThermoFanSafetyPolicy.h"

#include <stddef.h>
#include <string.h>

#define THERMOFAN_LEGACY_FAN_STATE_MAGIC 0x54464636u
#define THERMOFAN_LEGACY_FAN_STATE_VERSION 1u
#define THERMOFAN_LEGACY_FAN_STATE_ALLOWED_FLAGS 0x1u
#define THERMOFAN_LEGACY_FAN_STATE_MAX_FANS 8u

_Static_assert(
    sizeof(ThermoFanLegacyFanState) == THERMOFAN_LEGACY_FAN_STATE_SIZE,
    "Legacy fan state layout must remain stable"
);

static uint32_t thermofan_count_bits(uint32_t value) {
    uint32_t count = 0;
    while (value != 0) {
        count += value & 1u;
        value >>= 1u;
    }
    return count;
}

static uint32_t thermofan_legacy_fan_state_checksum(
    const ThermoFanLegacyFanState *state
) {
    const uint8_t *bytes = (const uint8_t *)state;
    uint32_t hash = 2166136261u;
    for (size_t index = 0; index < offsetof(ThermoFanLegacyFanState, checksum); index++) {
        hash ^= bytes[index];
        hash *= 16777619u;
    }
    return hash;
}

int32_t thermofan_status_after_persisted_ownership_check(
    int32_t status,
    int32_t recovery_exit_code,
    int32_t state_present,
    int32_t owner_matches,
    int32_t fan_owned
) {
    if (status != 0
        && status != recovery_exit_code
        && state_present == 1
        && owner_matches == 1
        && fan_owned == 1) {
        return recovery_exit_code;
    }
    return status;
}

int32_t thermofan_process_identity_matches(
    int32_t stored_pid,
    uint64_t stored_start_seconds,
    uint64_t stored_start_microseconds,
    int32_t candidate_pid,
    uint64_t candidate_start_seconds,
    uint64_t candidate_start_microseconds
) {
    return stored_pid > 1
        && stored_pid == candidate_pid
        && stored_start_seconds != 0
        && stored_start_seconds == candidate_start_seconds
        && stored_start_microseconds == candidate_start_microseconds;
}

int32_t thermofan_decode_legacy_fan_state(
    const uint8_t *bytes,
    size_t length,
    ThermoFanLegacyFanState *out_state
) {
    if (bytes == NULL || length != sizeof(ThermoFanLegacyFanState)) {
        return 0;
    }

    ThermoFanLegacyFanState state;
    memcpy(&state, bytes, sizeof(state));
    const uint32_t allowed_mask = (1u << THERMOFAN_LEGACY_FAN_STATE_MAX_FANS) - 1u;
    if (state.magic != THERMOFAN_LEGACY_FAN_STATE_MAGIC
        || state.version != THERMOFAN_LEGACY_FAN_STATE_VERSION
        || state.owner_pid <= 1
        || (state.touched_mask & ~allowed_mask) != 0
        || state.refcount != thermofan_count_bits(state.touched_mask)
        || (state.flags & ~THERMOFAN_LEGACY_FAN_STATE_ALLOWED_FLAGS) != 0
        || (state.touched_mask == 0 && state.flags == 0)
        || state.checksum != thermofan_legacy_fan_state_checksum(&state)) {
        return 0;
    }

    if (out_state != NULL) {
        *out_state = state;
    }
    return 1;
}

int32_t thermofan_legacy_migration_allows_new_write(
    int32_t automatic_recovery_verified
) {
    return automatic_recovery_verified == 1;
}
