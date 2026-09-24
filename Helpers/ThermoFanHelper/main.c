#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <math.h>
#include <mach/mach_error.h>
#include <pthread.h>
#include <signal.h>
#include <stddef.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#include "ThermoFanEngine.h"
#include "ThermoFanSafetyPolicy.h"

#define SMC_KERNEL_INDEX 2
#define SMC_READ_BYTES 5
#define SMC_WRITE_BYTES 6
#define SMC_READ_KEY_INFO 9
#define THERMOFAN_STRINGIFY_INNER(value) #value
#define THERMOFAN_STRINGIFY(value) THERMOFAN_STRINGIFY_INNER(value)
#define HELPER_VERSION THERMOFAN_STRINGIFY(THERMOFAN_ENGINE_PROTOCOL_VERSION)
// State and lock files live in a root-only subdirectory. The parent is only
// trusted to hold that directory entry: Darwin's /var/run is group-writable
// for the daemon group, so nothing ThermoFan relies on is stored directly in it.
#define FAN_STATE_PARENT_DIRECTORY "/var/run"
#define FAN_STATE_PARENT_DIRECTORY_GROUP 1
#define FAN_STATE_DIRECTORY_NAME "thermofan"
#define FAN_STATE_DIRECTORY_MODE 0700
#define FAN_STATE_BASENAME "fan.state"
#define FAN_LOCK_BASENAME "fan.lock"
// Earlier builds (the setuid v8 helper and earlier protocol 9 daemons) kept
// their ownership record and lock directly in the parent. A record found there
// is recovered to Auto and then removed; that lock is only used to serialize
// with a v8 helper process that may still be running.
#define LEGACY_FAN_STATE_BASENAME "io.github.girginomer10.ThermoFan.fan.state"
#define LEGACY_FAN_LOCK_BASENAME "io.github.girginomer10.ThermoFan.fan.lock"
#define FAN_STATE_MAGIC 0x54464638u
#define FAN_STATE_VERSION 2u
#define FAN_STATE_FTST_OWNED 0x1u
#define FAN_STATE_ALLOWED_FLAGS FAN_STATE_FTST_OWNED
#define FAN_STATE_MAX_FANS 8
#define FAN_SAFE_MAX_RPM 20000
#define EXIT_RECOVERY_REQUIRED THERMOFAN_ENGINE_RECOVERY_REQUIRED
#define STATE_TEMP_ATTEMPTS 32
#define EXIT_WATCH_CONSUME_TIMEOUT_SECONDS 1.0
#define LEGACY_HELPER_DIRECTORY "/Library/PrivilegedHelperTools"
// A v8 fan transaction is bounded at roughly 66 seconds in the worst case
// (stale recovery of eight fans at 5 s each plus a 5 s Ftst reset, a 10 s
// manual deadline, and a 10.5 s verified rollback). The legacy lock is never
// waited on longer than this margin above that bound.
#define LEGACY_LOCK_WAIT_SECONDS 90.0
#define LEGACY_LOCK_POLL_MILLISECONDS 50

// FS! is a legacy Intel/T2 force bitmask. It exists only in non-arm64 builds:
// the Apple Silicon helper contains neither the key string nor any code that
// reads or writes it, so fan-control discovery on an M-series Mac can only use
// a verified per-fan mode key or fail closed to monitoring.
#if !defined(__arm64__) && !defined(__aarch64__)
#define THERMOFAN_FORCE_MASK_SUPPORTED 1
#define FAN_FORCE_MASK_KEY "FS!"
#else
#define THERMOFAN_FORCE_MASK_SUPPORTED 0
#endif

typedef struct {
    uint8_t major;
    uint8_t minor;
    uint8_t build;
    uint8_t reserved;
    uint16_t release;
} SMCVersion;

typedef struct {
    uint16_t version;
    uint16_t length;
    uint32_t cpuPLimit;
    uint32_t gpuPLimit;
    uint32_t memPLimit;
} SMCPLimitData;

typedef struct {
    uint32_t dataSize;
    uint32_t dataType;
    uint8_t dataAttributes;
    uint8_t padding0;
    uint8_t padding1;
    uint8_t padding2;
} SMCKeyInfo;

typedef struct {
    uint32_t key;
    SMCVersion vers;
    SMCPLimitData pLimitData;
    SMCKeyInfo keyInfo;
    uint8_t result;
    uint8_t status;
    uint8_t data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCKeyData;

_Static_assert(sizeof(SMCKeyData) == 80, "SMCKeyData must be 80 bytes");

static uint32_t key_code(const char *key) {
    uint8_t bytes[4] = {' ', ' ', ' ', ' '};
    size_t length = strlen(key);
    if (length > 4) {
        length = 4;
    }
    memcpy(bytes, key, length);
    return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
}

static void type_string(uint32_t type, char out[5]) {
    out[0] = (char)((type >> 24) & 0xff);
    out[1] = (char)((type >> 16) & 0xff);
    out[2] = (char)((type >> 8) & 0xff);
    out[3] = (char)(type & 0xff);
    out[4] = '\0';
    for (int i = 3; i >= 0 && out[i] == ' '; i--) {
        out[i] = '\0';
    }
}

static io_service_t matching_service(void) {
    const char *names[] = {"AppleSMC", "AppleSMCKeysEndpoint"};
    for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(names[i]));
        if (service != IO_OBJECT_NULL) {
            return service;
        }
    }
    return IO_OBJECT_NULL;
}

static kern_return_t smc_call(io_connect_t connection, SMCKeyData *input, SMCKeyData *output) {
    size_t output_size = sizeof(SMCKeyData);
    return IOConnectCallStructMethod(
        connection,
        SMC_KERNEL_INDEX,
        input,
        sizeof(SMCKeyData),
        output,
        &output_size
    );
}

static int check_smc_result(const SMCKeyData *output) {
    if (output->result != 0) {
        fprintf(stderr, "SMC returned error 0x%02x.\n", output->result);
        return 1;
    }
    return 0;
}

static int read_info_internal(io_connect_t connection, const char *key, SMCKeyInfo *info, int quiet) {
    SMCKeyData input;
    SMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key_code(key);
    input.data8 = SMC_READ_KEY_INFO;

    kern_return_t result = smc_call(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        if (!quiet) {
            fprintf(stderr, "SMC info call failed for %s: %s.\n", key, mach_error_string(result));
        }
        return 1;
    }
    if (output.result != 0) {
        if (!quiet) {
            (void)check_smc_result(&output);
        }
        return 1;
    }

    *info = output.keyInfo;
    return 0;
}

static int read_raw_internal(io_connect_t connection, const char *key, SMCKeyInfo *info, uint8_t bytes[32], int quiet) {
    if (read_info_internal(connection, key, info, quiet) != 0) {
        return 1;
    }

    SMCKeyData input;
    SMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key_code(key);
    input.keyInfo = *info;
    input.data8 = SMC_READ_BYTES;

    kern_return_t result = smc_call(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        if (!quiet) {
            fprintf(stderr, "SMC read failed for %s: %s.\n", key, mach_error_string(result));
        }
        return 1;
    }
    if (output.result != 0) {
        if (!quiet) {
            (void)check_smc_result(&output);
        }
        return 1;
    }

    memset(bytes, 0, 32);
    size_t size = info->dataSize;
    if (size > 32) {
        size = 32;
    }
    memcpy(bytes, output.bytes, size);
    return 0;
}

static double decode_number(const SMCKeyInfo *info, const uint8_t bytes[32]) {
    char type[5];
    type_string(info->dataType, type);

    if (strcmp(type, "flt") == 0 && info->dataSize >= 4) {
        uint32_t raw = ((uint32_t)bytes[0]) | ((uint32_t)bytes[1] << 8) | ((uint32_t)bytes[2] << 16) | ((uint32_t)bytes[3] << 24);
        float value = 0;
        memcpy(&value, &raw, sizeof(value));
        return value;
    }
    if (strcmp(type, "fpe2") == 0 && info->dataSize >= 2) {
        uint16_t raw = ((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1];
        return (double)raw / 4.0;
    }
    if (strcmp(type, "ui8") == 0 && info->dataSize >= 1) {
        return bytes[0];
    }
    if (strcmp(type, "ui16") == 0 && info->dataSize >= 2) {
        return ((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1];
    }
    if (strcmp(type, "ui32") == 0 && info->dataSize >= 4) {
        return ((uint32_t)bytes[0] << 24) | ((uint32_t)bytes[1] << 16) | ((uint32_t)bytes[2] << 8) | (uint32_t)bytes[3];
    }
    return NAN;
}

static int read_number_internal(io_connect_t connection, const char *key, double *value, int quiet) {
    SMCKeyInfo info;
    uint8_t bytes[32];
    if (read_raw_internal(connection, key, &info, bytes, quiet) != 0) {
        return 1;
    }
    *value = decode_number(&info, bytes);
    return isfinite(*value) ? 0 : 1;
}

static int read_number(io_connect_t connection, const char *key, double *value) {
    return read_number_internal(connection, key, value, 0);
}

static int read_number_quiet(io_connect_t connection, const char *key, double *value) {
    return read_number_internal(connection, key, value, 1);
}

static int encode_number(const SMCKeyInfo *info, double value, uint8_t bytes[32]) {
    char type[5];
    type_string(info->dataType, type);
    memset(bytes, 0, 32);

    if (strcmp(type, "flt") == 0 && info->dataSize >= 4) {
        float float_value = (float)value;
        uint32_t raw = 0;
        memcpy(&raw, &float_value, sizeof(raw));
        bytes[0] = raw & 0xff;
        bytes[1] = (raw >> 8) & 0xff;
        bytes[2] = (raw >> 16) & 0xff;
        bytes[3] = (raw >> 24) & 0xff;
        return 0;
    }
    if (strcmp(type, "fpe2") == 0 && info->dataSize >= 2) {
        // 14.2 fixed point: the on-wire value is RPM * 4 (used by Intel fan keys).
        if (value < 0) value = 0;
        double scaled = round(value * 4.0);
        if (scaled > 65535) scaled = 65535;
        uint16_t raw = (uint16_t)scaled;
        bytes[0] = (raw >> 8) & 0xff;
        bytes[1] = raw & 0xff;
        return 0;
    }
    if (strcmp(type, "ui8") == 0 && info->dataSize >= 1) {
        if (value < 0) value = 0;
        if (value > 255) value = 255;
        bytes[0] = (uint8_t)value;
        return 0;
    }
    if (strcmp(type, "ui16") == 0 && info->dataSize >= 2) {
        if (value < 0) value = 0;
        if (value > 65535) value = 65535;
        uint16_t raw = (uint16_t)value;
        bytes[0] = (raw >> 8) & 0xff;
        bytes[1] = raw & 0xff;
        return 0;
    }
    if (strcmp(type, "ui32") == 0 && info->dataSize >= 4) {
        if (value < 0) value = 0;
        uint32_t raw = (uint32_t)value;
        bytes[0] = (raw >> 24) & 0xff;
        bytes[1] = (raw >> 16) & 0xff;
        bytes[2] = (raw >> 8) & 0xff;
        bytes[3] = raw & 0xff;
        return 0;
    }

    fprintf(stderr, "Unsupported SMC write type '%s'.\n", type);
    return 1;
}

static int write_number_internal(io_connect_t connection, const char *key, double value, int quiet) {
    SMCKeyInfo info;
    if (read_info_internal(connection, key, &info, quiet) != 0) {
        return 1;
    }

    uint8_t encoded[32];
    if (encode_number(&info, value, encoded) != 0) {
        return 1;
    }

    SMCKeyData input;
    SMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key_code(key);
    input.keyInfo = info;
    input.data8 = SMC_WRITE_BYTES;
    memcpy(input.bytes, encoded, 32);

    kern_return_t result = smc_call(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        if (!quiet) {
            fprintf(stderr, "SMC write failed for %s: %s.\n", key, mach_error_string(result));
        }
        return 1;
    }
    if (output.result != 0) {
        if (!quiet) {
            (void)check_smc_result(&output);
        }
        return 1;
    }
    return 0;
}

static int write_number(io_connect_t connection, const char *key, double value) {
    return write_number_internal(connection, key, value, 0);
}

static int write_number_quiet(io_connect_t connection, const char *key, double value) {
    return write_number_internal(connection, key, value, 1);
}

static int open_smc(io_connect_t *connection) {
    io_service_t service = matching_service();
    if (service == IO_OBJECT_NULL) {
        fprintf(stderr, "Apple SMC service is unavailable.\n");
        return 1;
    }

    kern_return_t result = IOServiceOpen(service, mach_task_self(), 0, connection);
    IOObjectRelease(service);
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "Could not open Apple SMC: %s.\n", mach_error_string(result));
        return 1;
    }
    return 0;
}

typedef enum {
    FAN_CONTROL_NONE = 0,
    FAN_CONTROL_PER_FAN_MODE,
#if THERMOFAN_FORCE_MASK_SUPPORTED
    FAN_CONTROL_FORCE_MASK,
#endif
} FanControlKind;

typedef struct {
    FanControlKind kind;
    char mode_key[5];
} FanControlEndpoint;

typedef ThermoFanProcessIdentity ProcessIdentity;

typedef struct {
    uint32_t magic;
    uint32_t version;
    int32_t owner_pid;
    uint32_t identity_reserved;
    uint64_t owner_start_seconds;
    uint64_t owner_start_microseconds;
    uint32_t touched_mask;
    uint32_t refcount;
    uint32_t flags;
    uint32_t checksum;
} FanControlState;

static _Atomic int startup_recovery_succeeded = 0;
static _Atomic int manual_writes_ready = 0;
// Set when legacy retirement finds a pre-v9 helper executable. Those helpers
// kept no durable record ThermoFan can rely on, so the final recovery also
// scans every fan's mode key. The flag survives failed attempts for the
// daemon's lifetime and is cleared only by a verified scan that follows a
// completed drain of legacy helper processes.
static _Atomic int legacy_manual_scan_pending = 0;

static int is_apple_silicon_build(void) {
#if defined(__arm64__) || defined(__aarch64__)
    return 1;
#else
    return 0;
#endif
}

static uint32_t fan_bit(int fan_index) {
    return (uint32_t)1u << (uint32_t)fan_index;
}

static uint32_t count_fan_bits(uint32_t mask) {
    uint32_t count = 0;
    while (mask != 0) {
        count += mask & 1u;
        mask >>= 1u;
    }
    return count;
}

static uint32_t fan_state_checksum(const FanControlState *state) {
    const uint8_t *bytes = (const uint8_t *)state;
    uint32_t hash = 2166136261u;
    for (size_t index = 0; index < offsetof(FanControlState, checksum); index++) {
        hash ^= bytes[index];
        hash *= 16777619u;
    }
    return hash;
}

int thermofan_engine_read_process_identity(pid_t pid, ProcessIdentity *identity) {
    if (pid <= 1 || identity == NULL) {
        return 1;
    }

    struct proc_bsdinfo process_info;
    memset(&process_info, 0, sizeof(process_info));
    int result = proc_pidinfo(
        pid,
        PROC_PIDTBSDINFO,
        0,
        &process_info,
        (int)sizeof(process_info)
    );
    if (result != (int)sizeof(process_info)
        || process_info.pbi_pid != (uint32_t)pid
        || process_info.pbi_start_tvsec == 0
        || process_info.pbi_start_tvusec >= 1000000) {
        return 1;
    }

    identity->pid = (int32_t)pid;
    identity->start_seconds = process_info.pbi_start_tvsec;
    identity->start_microseconds = process_info.pbi_start_tvusec;
    return 0;
}

static int state_owner_matches_identity(
    const FanControlState *state,
    const ProcessIdentity *identity
) {
    if (state == NULL || identity == NULL) {
        return 0;
    }
    return thermofan_process_identity_matches(
        state->owner_pid,
        state->owner_start_seconds,
        state->owner_start_microseconds,
        identity->pid,
        identity->start_seconds,
        identity->start_microseconds
    );
}

static int process_identity_is_current(const ProcessIdentity *identity) {
    if (identity == NULL) {
        return 0;
    }
    ProcessIdentity current;
    return thermofan_engine_read_process_identity((pid_t)identity->pid, &current) == 0
        && thermofan_process_identity_matches(
            identity->pid,
            identity->start_seconds,
            identity->start_microseconds,
            current.pid,
            current.start_seconds,
            current.start_microseconds
        );
}

static int state_owner_process_is_current(const FanControlState *state) {
    if (state == NULL) {
        return 0;
    }
    ProcessIdentity owner = {
        .pid = state->owner_pid,
        .start_seconds = state->owner_start_seconds,
        .start_microseconds = state->owner_start_microseconds
    };
    return process_identity_is_current(&owner);
}

static void initialize_fan_state(FanControlState *state, const ProcessIdentity *owner) {
    memset(state, 0, sizeof(*state));
    state->magic = FAN_STATE_MAGIC;
    state->version = FAN_STATE_VERSION;
    state->owner_pid = owner->pid;
    state->owner_start_seconds = owner->start_seconds;
    state->owner_start_microseconds = owner->start_microseconds;
    state->checksum = fan_state_checksum(state);
}

static int fan_state_is_valid(const FanControlState *state) {
    const uint32_t allowed_mask = (1u << FAN_STATE_MAX_FANS) - 1u;
    if (state->magic != FAN_STATE_MAGIC
        || state->version != FAN_STATE_VERSION
        || state->owner_pid <= 1
        || state->identity_reserved != 0
        || state->owner_start_seconds == 0
        || state->owner_start_microseconds >= 1000000
        || (state->touched_mask & ~allowed_mask) != 0
        || state->refcount != count_fan_bits(state->touched_mask)
        || (state->flags & ~FAN_STATE_ALLOWED_FLAGS) != 0
        || (state->touched_mask == 0 && state->flags == 0)) {
        return 0;
    }
    return state->checksum == fan_state_checksum(state);
}

typedef struct {
    const char *name;
    const char *absolute_path;
    int is_executable;
} LegacyHelperPath;

static const LegacyHelperPath legacy_helper_paths[] = {
    {
        "io.github.girginomer10.ThermoFan.helper",
        "/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper",
        1
    },
    // A v8 install staged a root-owned setuid copy here before renaming it
    // into place; an interrupted install can leave it behind.
    {
        "io.github.girginomer10.ThermoFan.helper.installing",
        "/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper.installing",
        1
    },
    {
        "io.github.girginomer10.ThermoFan.helper.version",
        "/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper.version",
        0
    },
    {
        "local.codex.ThermoFan.helper",
        "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper",
        1
    },
    {
        "local.codex.ThermoFan.helper.version",
        "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper.version",
        0
    }
};

#define LEGACY_HELPER_COUNT \
    (sizeof(legacy_helper_paths) / sizeof(legacy_helper_paths[0]))

static int attributes_identify_same_inode(
    const struct stat *left,
    const struct stat *right
) {
    return left != NULL
        && right != NULL
        && left->st_dev == right->st_dev
        && left->st_ino == right->st_ino;
}

// Plain fsync() on Darwin does not ask the drive to flush its write cache;
// F_FULLFSYNC does. Only a file system that cannot honor it (ENOTSUP or
// EINVAL) falls back to fsync(); every other failure is reported.
static int full_fsync(int descriptor) {
    for (;;) {
        if (fcntl(descriptor, F_FULLFSYNC) == 0) {
            return 0;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == ENOTSUP || errno == EOPNOTSUPP || errno == EINVAL) {
            break;
        }
        return -1;
    }
    for (;;) {
        if (fsync(descriptor) == 0) {
            return 0;
        }
        if (errno != EINTR) {
            return -1;
        }
    }
}

static int flock_exclusive(int descriptor) {
    for (;;) {
        if (flock(descriptor, LOCK_EX) == 0) {
            return 0;
        }
        if (errno != EINTR) {
            return -1;
        }
    }
}

static int open_root_owned_file_at(int directory_fd, const char *name) {
    int descriptor = openat(
        directory_fd,
        name,
        O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW,
        0600
    );
    if (descriptor < 0) {
        fprintf(stderr, "Could not open privileged fan file %s: %s.\n", name, strerror(errno));
        return -1;
    }

    struct stat attributes;
    if (fstat(descriptor, &attributes) != 0
        || !S_ISREG(attributes.st_mode)
        || attributes.st_uid != 0
        || attributes.st_nlink != 1
        || (attributes.st_mode & 077) != 0) {
        fprintf(stderr, "Privileged fan file %s has unsafe ownership or permissions.\n", name);
        close(descriptor);
        return -1;
    }
    if (fchown(descriptor, 0, 0) != 0 || fchmod(descriptor, 0600) != 0) {
        fprintf(stderr, "Could not secure privileged fan file %s: %s.\n", name, strerror(errno));
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static int open_state_parent_directory(void) {
    int descriptor = open(
        FAN_STATE_PARENT_DIRECTORY,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    );
    if (descriptor < 0) {
        fprintf(stderr, "Could not open the privileged state parent directory: %s.\n", strerror(errno));
        return -1;
    }

    // Darwin's /private/var/run is intentionally root:daemon (gid 1), 0775.
    // It must be root-owned and never world-writable; group write is accepted
    // only for that system group. It is trusted to hold the root-only state
    // directory entry, never ThermoFan's current state or lock.
    struct stat attributes;
    if (fstat(descriptor, &attributes) != 0
        || !S_ISDIR(attributes.st_mode)
        || attributes.st_uid != 0
        || (attributes.st_mode & 0002) != 0
        || ((attributes.st_mode & 0020) != 0
            && attributes.st_gid != FAN_STATE_PARENT_DIRECTORY_GROUP)) {
        fprintf(stderr, "Privileged state parent directory has unsafe ownership or permissions.\n");
        close(descriptor);
        return -1;
    }
    return descriptor;
}

// Opens the root-only state directory, creating it on first use. State and
// lock files are resolved only through the returned descriptor, so a later
// rename of the path by a daemon-group process cannot redirect them.
static int open_state_directory(void) {
    int parent_fd = open_state_parent_directory();
    if (parent_fd < 0) {
        return -1;
    }

    int created = 0;
    if (mkdirat(parent_fd, FAN_STATE_DIRECTORY_NAME, FAN_STATE_DIRECTORY_MODE) == 0) {
        created = 1;
    } else if (errno != EEXIST) {
        fprintf(stderr, "Could not create the privileged state directory: %s.\n", strerror(errno));
        close(parent_fd);
        return -1;
    }

    int descriptor = openat(
        parent_fd,
        FAN_STATE_DIRECTORY_NAME,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    );
    if (descriptor < 0) {
        // ELOOP or ENOTDIR: the entry is a symlink or not a directory.
        fprintf(stderr, "Could not open the privileged state directory safely: %s.\n", strerror(errno));
        close(parent_fd);
        return -1;
    }

    struct stat attributes;
    if (fstat(descriptor, &attributes) != 0
        || !S_ISDIR(attributes.st_mode)
        || attributes.st_uid != 0) {
        fprintf(stderr, "Privileged state directory is not a root-owned directory.\n");
        goto fail;
    }
    if (created
        && (fchown(descriptor, 0, 0) != 0
            || fchmod(descriptor, FAN_STATE_DIRECTORY_MODE) != 0
            || fstat(descriptor, &attributes) != 0)) {
        fprintf(stderr, "Could not restrict the new privileged state directory: %s.\n", strerror(errno));
        goto fail;
    }
    // A pre-existing directory is never loosened or tightened here: anything
    // other than exactly 0700 was not created by this code.
    if ((attributes.st_mode & 07777) != FAN_STATE_DIRECTORY_MODE) {
        fprintf(stderr, "Privileged state directory has unsafe permissions.\n");
        goto fail;
    }
    // mkdir inherits the parent's daemon group. A root-only 0700 directory
    // whose creation was interrupted before fchown is normalized to wheel.
    if (attributes.st_gid != 0
        && (fchown(descriptor, 0, 0) != 0
            || fstat(descriptor, &attributes) != 0
            || attributes.st_uid != 0
            || attributes.st_gid != 0)) {
        fprintf(stderr, "Could not restrict the privileged state directory to root:wheel.\n");
        goto fail;
    }
    if (created && full_fsync(parent_fd) != 0) {
        fprintf(stderr, "Could not durably create the privileged state directory: %s.\n", strerror(errno));
        goto fail;
    }
    close(parent_fd);
    return descriptor;

fail:
    close(descriptor);
    close(parent_fd);
    return -1;
}

// Reports whether a legacy helper executable is still installed. Any error
// other than ENOENT is reported as installed so callers stay conservative.
static int legacy_helper_executable_may_exist(void) {
    for (size_t index = 0; index < LEGACY_HELPER_COUNT; index++) {
        if (!legacy_helper_paths[index].is_executable) {
            continue;
        }
        struct stat attributes;
        if (lstat(legacy_helper_paths[index].absolute_path, &attributes) == 0
            || errno != ENOENT) {
            return 1;
        }
    }
    return 0;
}

static double monotonic_seconds(void);
static void sleep_before_deadline(double deadline, long maximum_milliseconds);

// A v8 helper serializes its fan transactions and ownership record through
// the legacy lock in the parent directory. While such a helper may still run,
// holding that lock too keeps its transactions and ours mutually exclusive.
// It is created only while a legacy executable is installed (exactly as the
// v8 helper would create it) and otherwise used only if it already exists.
// v8 refuses any lock that is not a root-owned, single-link, owner-only
// regular file, so such an object cannot serialize a v8 transaction and is
// skipped rather than trusted. The wait is bounded: a lock held past any v8
// transaction's duration belongs to a hung helper or to an unrelated root file
// moved onto this name in the daemon-group-writable parent, and must never
// stall recovery.
static int acquire_legacy_fan_lock(int parent_fd, int *legacy_lock_fd) {
    *legacy_lock_fd = -1;
    int flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK;
    if (legacy_helper_executable_may_exist()) {
        flags |= O_CREAT;
    }
    int descriptor = openat(parent_fd, LEGACY_FAN_LOCK_BASENAME, flags, 0600);
    if (descriptor < 0) {
        if (errno == ENOENT || errno == ELOOP || errno == EISDIR) {
            return 0;
        }
        fprintf(stderr, "Could not open the legacy fan lock: %s.\n", strerror(errno));
        return 1;
    }

    struct stat attributes;
    if (fstat(descriptor, &attributes) != 0) {
        close(descriptor);
        return 1;
    }
    if (!S_ISREG(attributes.st_mode)
        || attributes.st_uid != 0
        || attributes.st_nlink != 1
        || (attributes.st_mode & 077) != 0) {
        close(descriptor);
        return 0;
    }
    const double deadline = monotonic_seconds() + LEGACY_LOCK_WAIT_SECONDS;
    for (;;) {
        if (flock(descriptor, LOCK_EX | LOCK_NB) == 0) {
            *legacy_lock_fd = descriptor;
            return 0;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno != EWOULDBLOCK) {
            fprintf(stderr, "Could not serialize with legacy fan helpers: %s.\n", strerror(errno));
            close(descriptor);
            return 1;
        }
        if (monotonic_seconds() >= deadline) {
            fprintf(stderr, "The legacy fan lock stayed held past any legacy transaction; continuing without it.\n");
            close(descriptor);
            return 0;
        }
        sleep_before_deadline(deadline, LEGACY_LOCK_POLL_MILLISECONDS);
    }
}

typedef struct {
    int lock_fd;
    int legacy_lock_fd;
} FanLocks;

static void release_fan_locks(FanLocks *locks) {
    if (locks->legacy_lock_fd >= 0) {
        (void)flock(locks->legacy_lock_fd, LOCK_UN);
        close(locks->legacy_lock_fd);
        locks->legacy_lock_fd = -1;
    }
    if (locks->lock_fd >= 0) {
        (void)flock(locks->lock_fd, LOCK_UN);
        close(locks->lock_fd);
        locks->lock_fd = -1;
    }
}

// Lock order is always the root-only lock first, then the legacy lock. A v8
// helper takes only the legacy lock, so the order cannot deadlock.
static int acquire_fan_locks(FanLocks *locks) {
    locks->lock_fd = -1;
    locks->legacy_lock_fd = -1;

    int directory_fd = open_state_directory();
    if (directory_fd < 0) {
        return 1;
    }
    int lock_fd = open_root_owned_file_at(directory_fd, FAN_LOCK_BASENAME);
    close(directory_fd);
    if (lock_fd < 0) {
        return 1;
    }
    if (flock_exclusive(lock_fd) != 0) {
        fprintf(stderr, "Could not lock privileged fan state: %s.\n", strerror(errno));
        close(lock_fd);
        return 1;
    }
    locks->lock_fd = lock_fd;

    int parent_fd = open_state_parent_directory();
    if (parent_fd < 0) {
        release_fan_locks(locks);
        return 1;
    }
    int legacy_status = acquire_legacy_fan_lock(parent_fd, &locks->legacy_lock_fd);
    close(parent_fd);
    if (legacy_status != 0) {
        release_fan_locks(locks);
        return 1;
    }
    return 0;
}

// Returns 1 when a safe state file exists, 0 when absent, and -1 when the
// expected path is occupied by an unsafe object.
static int validate_state_path(int directory_fd, struct stat *attributes) {
    struct stat local_attributes;
    if (attributes == NULL) {
        attributes = &local_attributes;
    }
    if (fstatat(
            directory_fd,
            FAN_STATE_BASENAME,
            attributes,
            AT_SYMLINK_NOFOLLOW
        ) != 0) {
        return errno == ENOENT ? 0 : -1;
    }
    if (!S_ISREG(attributes->st_mode)
        || attributes->st_uid != 0
        || attributes->st_nlink != 1
        || (attributes->st_mode & 077) != 0) {
        return -1;
    }
    return 1;
}

// Parses an open, already validated record. Returns 2 for a valid v1 record
// requiring fail-safe Auto migration, 1 for a current record, 0 for an empty
// file, and -1 for a malformed record.
static int parse_fan_state_file(int state_fd, off_t size, FanControlState *state) {
    if (size == 0) {
        memset(state, 0, sizeof(*state));
        return 0;
    }
    if (size == (off_t)THERMOFAN_LEGACY_FAN_STATE_SIZE) {
        uint8_t legacy_bytes[THERMOFAN_LEGACY_FAN_STATE_SIZE];
        ssize_t legacy_count = pread(state_fd, legacy_bytes, sizeof(legacy_bytes), 0);
        ThermoFanLegacyFanState legacy;
        if (legacy_count != (ssize_t)sizeof(legacy_bytes)
            || !thermofan_decode_legacy_fan_state(
                legacy_bytes,
                sizeof(legacy_bytes),
                &legacy
            )) {
            return -1;
        }
        memset(state, 0, sizeof(*state));
        state->owner_pid = legacy.owner_pid;
        state->touched_mask = legacy.touched_mask;
        state->refcount = legacy.refcount;
        state->flags = legacy.flags;
        return 2;
    }
    if (size != (off_t)sizeof(*state)) {
        return -1;
    }

    ssize_t count = pread(state_fd, state, sizeof(*state), 0);
    if (count != (ssize_t)sizeof(*state) || !fan_state_is_valid(state)) {
        return -1;
    }
    return 1;
}

// Returns 2 for a valid v1 state requiring fail-safe Auto migration, 1 for a
// current state, 0 for an empty state, and -1 for malformed state.
static int load_fan_state(FanControlState *state) {
    int directory_fd = open_state_directory();
    if (directory_fd < 0) {
        return -1;
    }

    struct stat path_attributes;
    int path_status = validate_state_path(directory_fd, &path_attributes);
    if (path_status <= 0) {
        close(directory_fd);
        if (path_status == 0) {
            memset(state, 0, sizeof(*state));
        } else {
            fprintf(stderr, "Privileged fan state path is unsafe.\n");
        }
        return path_status;
    }

    int state_fd = openat(
        directory_fd,
        FAN_STATE_BASENAME,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW
    );
    close(directory_fd);
    if (state_fd < 0) {
        return -1;
    }

    struct stat attributes;
    if (fstat(state_fd, &attributes) != 0
        || !S_ISREG(attributes.st_mode)
        || attributes.st_uid != 0
        || attributes.st_nlink != 1
        || (attributes.st_mode & 077) != 0
        || !attributes_identify_same_inode(&attributes, &path_attributes)) {
        close(state_fd);
        return -1;
    }

    int status = parse_fan_state_file(state_fd, attributes.st_size, state);
    close(state_fd);
    return status;
}

// Loads an ownership record left in the parent directory by the setuid v8
// helper or an earlier protocol 9 daemon. Returns 2 (v1 layout), 1 (current
// layout), 0 (nothing to recover) or -1 (a root-owned record exists but cannot
// be read or validated, so recovery is uncertain). On 0, 1 or 2 from a
// root-owned file, *identity describes it for a later same-file unlink;
// identity->st_ino stays 0 when there is nothing to unlink.
static int load_legacy_location_state(
    int parent_fd,
    FanControlState *state,
    struct stat *identity
) {
    memset(state, 0, sizeof(*state));
    memset(identity, 0, sizeof(*identity));

    struct stat path_attributes;
    if (fstatat(
            parent_fd,
            LEGACY_FAN_STATE_BASENAME,
            &path_attributes,
            AT_SYMLINK_NOFOLLOW
        ) != 0) {
        return errno == ENOENT ? 0 : -1;
    }
    // Every ThermoFan build wrote this record as a root-owned regular file.
    // Anything else was not written by ThermoFan, carries no recovery
    // obligation, and is left untouched. Recovery acts only toward Auto, so a
    // root-owned record is honored even if its mode or link count drifted.
    if (!S_ISREG(path_attributes.st_mode) || path_attributes.st_uid != 0) {
        fprintf(stderr, "Ignoring a non-ThermoFan object at the legacy fan state location.\n");
        return 0;
    }

    int state_fd = openat(
        parent_fd,
        LEGACY_FAN_STATE_BASENAME,
        O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    );
    if (state_fd < 0) {
        return -1;
    }
    struct stat attributes;
    if (fstat(state_fd, &attributes) != 0
        || !S_ISREG(attributes.st_mode)
        || attributes.st_uid != 0
        || !attributes_identify_same_inode(&attributes, &path_attributes)) {
        close(state_fd);
        return -1;
    }

    int status = parse_fan_state_file(state_fd, attributes.st_size, state);
    close(state_fd);
    if (status >= 0) {
        *identity = attributes;
    }
    return status;
}

// Removes the legacy-location record only if it is still the exact file that
// was read (same device, inode and size); otherwise the next pass re-reads it.
static int remove_legacy_location_state(
    int parent_fd,
    const struct stat *identity
) {
    struct stat current;
    if (fstatat(
            parent_fd,
            LEGACY_FAN_STATE_BASENAME,
            &current,
            AT_SYMLINK_NOFOLLOW
        ) != 0) {
        return errno == ENOENT ? 0 : 1;
    }
    if (!S_ISREG(current.st_mode)
        || current.st_uid != 0
        || !attributes_identify_same_inode(identity, &current)
        || current.st_size != identity->st_size) {
        fprintf(stderr, "The legacy fan state location changed during migration.\n");
        return 1;
    }
    if (unlinkat(parent_fd, LEGACY_FAN_STATE_BASENAME, 0) != 0
        || full_fsync(parent_fd) != 0) {
        fprintf(stderr, "Could not remove migrated legacy fan state: %s.\n", strerror(errno));
        return 1;
    }
    return 0;
}

// Returns 1 while a legacy-location record still awaits recovery, 0 when none
// exists, and -1 when that cannot be determined.
static int legacy_location_record_status(void) {
    int parent_fd = open_state_parent_directory();
    if (parent_fd < 0) {
        return -1;
    }
    FanControlState legacy_state;
    struct stat legacy_identity;
    int status = load_legacy_location_state(parent_fd, &legacy_state, &legacy_identity);
    close(parent_fd);
    if (status < 0) {
        return -1;
    }
    return status > 0 ? 1 : 0;
}

static int write_all(int descriptor, const void *bytes, size_t length) {
    const uint8_t *cursor = bytes;
    size_t written = 0;
    while (written < length) {
        ssize_t count = write(descriptor, cursor + written, length - written);
        if (count > 0) {
            written += (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR) {
            continue;
        }
        return 1;
    }
    return 0;
}

static int save_fan_state(FanControlState *state) {
    state->refcount = count_fan_bits(state->touched_mask);
    state->checksum = fan_state_checksum(state);
    if (!fan_state_is_valid(state)) {
        fprintf(stderr, "Refusing to persist malformed fan ownership state.\n");
        return 1;
    }

    int directory_fd = open_state_directory();
    if (directory_fd < 0) {
        return 1;
    }

    if (validate_state_path(directory_fd, NULL) < 0) {
        fprintf(stderr, "Refusing to replace an unsafe privileged fan state path.\n");
        close(directory_fd);
        return 1;
    }

    int temporary_fd = -1;
    char temporary_name[128];
    for (int attempt = 0; attempt < STATE_TEMP_ATTEMPTS; attempt++) {
        int length = snprintf(
            temporary_name,
            sizeof(temporary_name),
            ".%s.%d.%08x.tmp",
            FAN_STATE_BASENAME,
            (int)getpid(),
            arc4random()
        );
        if (length <= 0 || length >= (int)sizeof(temporary_name)) {
            close(directory_fd);
            return 1;
        }
        temporary_fd = openat(
            directory_fd,
            temporary_name,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            0600
        );
        if (temporary_fd >= 0 || errno != EEXIST) {
            break;
        }
    }
    if (temporary_fd < 0) {
        fprintf(stderr, "Could not create atomic fan state: %s.\n", strerror(errno));
        close(directory_fd);
        return 1;
    }

    int status = 1;
    if (fchown(temporary_fd, 0, 0) != 0
        || fchmod(temporary_fd, 0600) != 0
        || write_all(temporary_fd, state, sizeof(*state)) != 0
        || full_fsync(temporary_fd) != 0) {
        fprintf(stderr, "Could not persist privileged fan ownership state: %s.\n", strerror(errno));
        goto done;
    }
    if (close(temporary_fd) != 0) {
        temporary_fd = -1;
        fprintf(stderr, "Could not close atomic fan state: %s.\n", strerror(errno));
        goto done;
    }
    temporary_fd = -1;

    if (renameat(
            directory_fd,
            temporary_name,
            directory_fd,
            FAN_STATE_BASENAME
        ) != 0) {
        fprintf(stderr, "Could not atomically publish fan ownership state: %s.\n", strerror(errno));
        goto done;
    }
    temporary_name[0] = '\0';
    if (full_fsync(directory_fd) != 0) {
        fprintf(stderr, "Could not durably publish fan ownership state: %s.\n", strerror(errno));
        goto done;
    }
    status = 0;

done:
    if (temporary_fd >= 0) {
        close(temporary_fd);
    }
    if (temporary_name[0] != '\0') {
        (void)unlinkat(directory_fd, temporary_name, 0);
    }
    close(directory_fd);
    return status;
}

static int clear_fan_state(void) {
    int directory_fd = open_state_directory();
    if (directory_fd < 0) {
        return 1;
    }
    int path_status = validate_state_path(directory_fd, NULL);
    if (path_status < 0) {
        fprintf(stderr, "Refusing to clear an unsafe privileged fan state path.\n");
        close(directory_fd);
        return 1;
    }
    if (path_status == 0) {
        close(directory_fd);
        return 0;
    }
    if (unlinkat(directory_fd, FAN_STATE_BASENAME, 0) != 0
        || full_fsync(directory_fd) != 0) {
        fprintf(stderr, "Could not durably clear privileged fan ownership state: %s.\n", strerror(errno));
        close(directory_fd);
        return 1;
    }
    close(directory_fd);
    return 0;
}

static double monotonic_seconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0;
    }
    return (double)now.tv_sec + ((double)now.tv_nsec / 1000000000.0);
}

static void sleep_milliseconds(long milliseconds) {
    struct timespec delay;
    delay.tv_sec = milliseconds / 1000;
    delay.tv_nsec = (milliseconds % 1000) * 1000000L;
    while (nanosleep(&delay, &delay) != 0 && errno == EINTR) {
    }
}

static void sleep_before_deadline(double deadline, long maximum_milliseconds) {
    double remaining_seconds = deadline - monotonic_seconds();
    if (remaining_seconds <= 0) {
        return;
    }

    long remaining_milliseconds = (long)floor(remaining_seconds * 1000.0);
    if (remaining_milliseconds <= 0) {
        return;
    }
    if (remaining_milliseconds > maximum_milliseconds) {
        remaining_milliseconds = maximum_milliseconds;
    }
    sleep_milliseconds(remaining_milliseconds);
}

static int fan_mode_value_is_supported(double value) {
    return isfinite(value) && (value == 0.0 || value == 1.0 || value == 3.0);
}

static int detect_fan_control_endpoint(io_connect_t connection, int fan_index, FanControlEndpoint *endpoint) {
    memset(endpoint, 0, sizeof(*endpoint));
    double mode_value = 0;

    snprintf(endpoint->mode_key, sizeof(endpoint->mode_key), "F%dMd", fan_index);
    if (read_number_quiet(connection, endpoint->mode_key, &mode_value) == 0
        && fan_mode_value_is_supported(mode_value)) {
        endpoint->kind = FAN_CONTROL_PER_FAN_MODE;
        return 0;
    }

    snprintf(endpoint->mode_key, sizeof(endpoint->mode_key), "F%dmd", fan_index);
    if (read_number_quiet(connection, endpoint->mode_key, &mode_value) == 0
        && fan_mode_value_is_supported(mode_value)) {
        endpoint->kind = FAN_CONTROL_PER_FAN_MODE;
        return 0;
    }
    endpoint->mode_key[0] = '\0';

#if THERMOFAN_FORCE_MASK_SUPPORTED
    // Intel/T2 builds only; see FAN_FORCE_MASK_KEY.
    if (read_number_quiet(connection, FAN_FORCE_MASK_KEY, &mode_value) == 0
        && isfinite(mode_value)) {
        endpoint->kind = FAN_CONTROL_FORCE_MASK;
        return 0;
    }
#endif

    // Without a verified per-fan mode key the fan stays monitoring-only.
    endpoint->kind = FAN_CONTROL_NONE;
    return 1;
}

static int write_fan_manual_state(io_connect_t connection, int fan_index, const FanControlEndpoint *endpoint, int enabled) {
    if (endpoint->kind == FAN_CONTROL_PER_FAN_MODE) {
        return write_number_quiet(connection, endpoint->mode_key, enabled ? 1 : 0);
    }
#if THERMOFAN_FORCE_MASK_SUPPORTED
    if (endpoint->kind == FAN_CONTROL_FORCE_MASK) {
        double mask_value = 0;
        if (read_number_quiet(connection, FAN_FORCE_MASK_KEY, &mask_value) != 0 || !isfinite(mask_value)) {
            return 1;
        }
        int mask = (int)mask_value;
        if (enabled) {
            mask |= 1 << fan_index;
        } else {
            mask &= ~(1 << fan_index);
        }
        return write_number_quiet(connection, FAN_FORCE_MASK_KEY, mask);
    }
#else
    (void)fan_index;
#endif
    return 1;
}

static int fan_manual_state_matches(io_connect_t connection, int fan_index, const FanControlEndpoint *endpoint, int expected_manual) {
    double value = 0;
    if (endpoint->kind == FAN_CONTROL_PER_FAN_MODE) {
        if (read_number_quiet(connection, endpoint->mode_key, &value) != 0 || !isfinite(value)) {
            return 0;
        }
        if (expected_manual) {
            return value == 1.0;
        }
        // Apple Silicon reports either Auto (0) or System (3) after control is
        // returned to macOS. Mode 3 must never be mistaken for Manual.
        return value == 0.0 || value == 3.0;
    }
#if THERMOFAN_FORCE_MASK_SUPPORTED
    if (endpoint->kind == FAN_CONTROL_FORCE_MASK
        && read_number_quiet(connection, FAN_FORCE_MASK_KEY, &value) == 0
        && isfinite(value)) {
        return (((((int)value) & (1 << fan_index)) != 0) ? 1 : 0) == expected_manual;
    }
#else
    (void)fan_index;
#endif
    return 0;
}

static int wait_for_fan_state(
    io_connect_t connection,
    int fan_index,
    const FanControlEndpoint *endpoint,
    int expected_manual,
    int attempts,
    long delay_milliseconds
) {
    for (int attempt = 0; attempt < attempts; attempt++) {
        if (fan_manual_state_matches(connection, fan_index, endpoint, expected_manual)) {
            return 0;
        }
        if (attempt + 1 < attempts) {
            sleep_milliseconds(delay_milliseconds);
        }
    }
    return 1;
}

static int read_ftst(io_connect_t connection, int *available, int *enabled) {
    double value = 0;
    *available = 0;
    *enabled = 0;
    if (!is_apple_silicon_build() || read_number_quiet(connection, "Ftst", &value) != 0) {
        return 0;
    }
    *available = 1;
    if (!isfinite(value)) {
        fprintf(stderr, "Ftst returned a non-finite value; refusing fan control.\n");
        return 1;
    }
    if (value == 0.0) {
        return 0;
    }
    if (value == 1.0) {
        *enabled = 1;
        return 0;
    }
    fprintf(stderr, "Ftst returned an unsupported value; refusing fan control.\n");
    return 1;
}

static int wait_for_ftst(io_connect_t connection, int expected_enabled, double deadline) {
    while (monotonic_seconds() < deadline) {
        int available = 0;
        int enabled = 0;
        if (read_ftst(connection, &available, &enabled) == 0
            && available
            && enabled == expected_enabled) {
            return 0;
        }
        sleep_before_deadline(deadline, 50);
    }
    return 1;
}

// Hands a ThermoFan-raised Ftst unlock back to macOS and verifies it. The
// write does not depend on a preceding successful read: durable state proves
// ThermoFan raised the flag, and clearing it can only return fan control to
// the system thermal manager. Builds that never raise Ftst never write it.
static int reset_owned_ftst(io_connect_t connection) {
    if (!is_apple_silicon_build()) {
        fprintf(stderr, "Durable state records a Ftst unlock, but this build never controls Ftst.\n");
        return 1;
    }
    (void)write_number_quiet(connection, "Ftst", 0);
    if (wait_for_ftst(connection, 0, monotonic_seconds() + 5.0) != 0) {
        fprintf(stderr, "Could not verify that the Ftst thermal-manager unlock returned to macOS.\n");
        return 1;
    }
    return 0;
}

static int return_fan_to_auto(io_connect_t connection, int fan_index, const FanControlEndpoint *endpoint) {
    // Readback is authoritative: some SMC writes return an error even when the
    // requested value was applied.
    (void)write_fan_manual_state(connection, fan_index, endpoint, 0);
    return wait_for_fan_state(connection, fan_index, endpoint, 0, 10, 50);
}

static int release_fan_ownership(
    io_connect_t connection,
    int fan_index,
    const FanControlEndpoint *endpoint,
    FanControlState *state,
    int *state_present
) {
    const uint32_t bit = fan_bit(fan_index);
    const int owns_fan = *state_present && (state->touched_mask & bit) != 0;
    const int is_last_owned_fan = owns_fan && state->touched_mask == bit;
    int automatic = return_fan_to_auto(connection, fan_index, endpoint) == 0;

    if (is_last_owned_fan && (state->flags & FAN_STATE_FTST_OWNED) != 0) {
        (void)write_number_quiet(connection, "Ftst", 0);
        double reclaim_deadline = monotonic_seconds() + 5.0;
        if (wait_for_ftst(connection, 0, reclaim_deadline) != 0) {
            fprintf(stderr, "Could not return the thermal manager unlock to macOS.\n");
            return 1;
        }
        automatic = wait_for_fan_state(connection, fan_index, endpoint, 0, 50, 100) == 0;
    }

    if (!automatic) {
        fprintf(stderr, "Fan %d did not return to automatic or system mode.\n", fan_index + 1);
        return 1;
    }
    if (!owns_fan) {
        return 0;
    }

    FanControlState next = *state;
    next.touched_mask &= ~bit;
    if (next.touched_mask == 0) {
        if (clear_fan_state() != 0) {
            return 1;
        }
        memset(state, 0, sizeof(*state));
        *state_present = 0;
        return 0;
    }
    if (save_fan_state(&next) != 0) {
        return 1;
    }
    *state = next;
    return 0;
}

// Returns every fan in a durable record to Auto and, when the record says
// ThermoFan raised Ftst, hands that unlock back to macOS. Every recorded fan
// is attempted even after another one fails, and no exit path skips the Ftst
// reset, so a partially unrecoverable record still releases all it can.
static int recover_fans_to_auto(
    io_connect_t connection,
    const FanControlState *state,
    int fan_count
) {
    FanControlEndpoint endpoints[FAN_STATE_MAX_FANS];
    int endpoint_available[FAN_STATE_MAX_FANS] = {0};
    const int ftst_owned = (state->flags & FAN_STATE_FTST_OWNED) != 0;
    int ftst_reset_attempted = 0;
    int failed = 0;
    int status = 1;

    for (int fan = 0; fan < FAN_STATE_MAX_FANS; fan++) {
        if ((state->touched_mask & fan_bit(fan)) == 0) {
            continue;
        }
        if (fan >= fan_count || detect_fan_control_endpoint(connection, fan, &endpoints[fan]) != 0) {
            fprintf(stderr, "Could not safely recover recorded fan %d ownership.\n", fan + 1);
            failed = 1;
            continue;
        }
        endpoint_available[fan] = 1;
        (void)write_fan_manual_state(connection, fan, &endpoints[fan], 0);
    }

    // Clear Ftst after the per-fan Auto writes and before verifying them, as
    // release_fan_ownership does: firmware that needed the unlock returns its
    // fans to macOS only once the unlock itself is released.
    if (ftst_owned) {
        ftst_reset_attempted = 1;
        if (reset_owned_ftst(connection) != 0) {
            fprintf(stderr, "Could not clear recorded Ftst ownership.\n");
            failed = 1;
        }
    }
    if (failed) {
        goto cleanup;
    }

    for (int fan = 0; fan < FAN_STATE_MAX_FANS; fan++) {
        if (!endpoint_available[fan]) {
            continue;
        }
        if (wait_for_fan_state(connection, fan, &endpoints[fan], 0, 50, 100) != 0) {
            fprintf(stderr, "Fan %d remained outside automatic/system mode during recovery.\n", fan + 1);
            goto cleanup;
        }
    }
    status = 0;

cleanup:
    // Invariant for every exit: a record that says ThermoFan raised Ftst never
    // leaves this function without an attempt to hand the unlock back.
    if (ftst_owned && !ftst_reset_attempted) {
        if (reset_owned_ftst(connection) != 0) {
            status = 1;
        }
    }
    return status;
}

static int recover_stale_owner(
    io_connect_t connection,
    FanControlState *state,
    int fan_count
) {
    if (recover_fans_to_auto(connection, state, fan_count) != 0) {
        return 1;
    }
    if (clear_fan_state() != 0) {
        return 1;
    }
    fprintf(stderr, "Recovered durable fan ownership recorded for process %d.\n", state->owner_pid);
    memset(state, 0, sizeof(*state));
    return 0;
}

// Pre-v9 helpers kept no durable record this engine can rely on, so after one
// was retired the only evidence of a fan it left in Manual is the per-fan mode
// key itself. Every fan whose verified mode key reads exactly Manual (1) is
// written back to Auto and read back. A fan without a verified per-fan mode
// key is skipped: outside an owned transaction this engine writes through no
// other interface. Run only after a legacy helper executable was retired,
// because on an ordinary start another tool may legitimately hold Manual.
static int return_legacy_manual_fans_to_auto(io_connect_t connection, int fan_count) {
    int failed = 0;
    for (int fan = 0; fan < fan_count; fan++) {
        FanControlEndpoint endpoint;
        int detected = 0;
        for (int attempt = 0; attempt < 3 && !detected; attempt++) {
            if (attempt > 0) {
                sleep_milliseconds(100);
            }
            detected = detect_fan_control_endpoint(connection, fan, &endpoint) == 0;
        }
        if (!detected || endpoint.kind != FAN_CONTROL_PER_FAN_MODE) {
            continue;
        }

        double mode_value = 0;
        if (read_number_quiet(connection, endpoint.mode_key, &mode_value) != 0
            || !isfinite(mode_value)) {
            fprintf(stderr, "Fan %d mode could not be read after legacy helper retirement.\n", fan + 1);
            failed = 1;
            continue;
        }
        if (mode_value != 1.0) {
            continue;
        }

        fprintf(stderr, "Fan %d was left in Manual mode after legacy helper retirement; returning it to automatic control.\n", fan + 1);
        (void)write_fan_manual_state(connection, fan, &endpoint, 0);
        if (wait_for_fan_state(connection, fan, &endpoint, 0, 50, 100) != 0) {
            fprintf(stderr, "Fan %d did not return to automatic or system mode after legacy helper retirement.\n", fan + 1);
            failed = 1;
        }
    }
    return failed;
}

static int enable_manual_mode(
    io_connect_t connection,
    int fan_index,
    const FanControlEndpoint *endpoint,
    int ftst_available,
    int ftst_enabled,
    FanControlState *state
) {
    const double deadline = monotonic_seconds() + 10.0;

    // M1 and M5 accept a direct mode write. M3/M4 commonly reject it while
    // thermalmonitord reports System mode (3), in which case Ftst is the only
    // verified fallback.
    (void)write_fan_manual_state(connection, fan_index, endpoint, 1);
    for (int attempt = 0; attempt < 5 && monotonic_seconds() < deadline; attempt++) {
        if (fan_manual_state_matches(connection, fan_index, endpoint, 1)) {
            return 0;
        }
        sleep_before_deadline(deadline, 50);
    }

    if (!ftst_available) {
        return 1;
    }

    // apply_fan re-validated after its last Ftst read that an enabled flag is
    // backed by FAN_STATE_FTST_OWNED, so an enabled Ftst here is ThermoFan's.
    if (!ftst_enabled) {
        // Persist ownership before the global diagnostic flag is changed. If
        // this process dies between the state write and SMC write, a later
        // helper can prove ownership and recover to Auto.
        FanControlState next = *state;
        next.flags |= FAN_STATE_FTST_OWNED;
        if (save_fan_state(&next) != 0) {
            return 1;
        }
        *state = next;
        (void)write_number_quiet(connection, "Ftst", 1);
        if (wait_for_ftst(connection, 1, deadline) != 0) {
            return 1;
        }
    }

    while (monotonic_seconds() < deadline) {
        (void)write_fan_manual_state(connection, fan_index, endpoint, 1);
        if (fan_manual_state_matches(connection, fan_index, endpoint, 1)) {
            return 0;
        }
        sleep_before_deadline(deadline, 100);
    }
    return 1;
}

// An enabled Ftst is acceptable only when durable state proves ThermoFan
// raised it. enable_manual_mode relies on this having been checked after the
// last Ftst read of the transaction.
static int ftst_matches_durable_ownership(
    int ftst_available,
    int ftst_enabled,
    int state_present,
    const FanControlState *state
) {
    return !(ftst_available
        && ftst_enabled
        && (state_present != 1 || (state->flags & FAN_STATE_FTST_OWNED) == 0));
}

static int apply_fan(
    int fan_index,
    const char *mode,
    int rpm,
    const ProcessIdentity *owner_identity,
    int require_owned_fan
) {
    io_connect_t connection = IO_OBJECT_NULL;
    FanLocks locks = {-1, -1};
    int lock_failed = 0;
    int status = 1;
    const int automatic_request = strcmp(mode, "automatic") == 0;

    if (acquire_fan_locks(&locks) != 0) {
        fprintf(stderr, "Could not serialize fan hardware access.\n");
        lock_failed = 1;
        goto done;
    }
    // While a record written by an earlier helper awaits recovery, that
    // helper may still own a fan, so no new Manual claim is started.
    if (!automatic_request && legacy_location_record_status() != 0) {
        fprintf(stderr, "Fan ownership recorded by an earlier ThermoFan helper still awaits automatic recovery; refusing manual writes.\n");
        goto done;
    }
    if (open_smc(&connection) != 0) {
        goto done;
    }

    double fan_count_value = 0;
    if (read_number(connection, "FNum", &fan_count_value) != 0
        || !isfinite(fan_count_value)
        || fan_count_value < 0
        || fan_count_value > FAN_STATE_MAX_FANS
        || fan_count_value != floor(fan_count_value)
        || fan_index < 0
        || fan_index >= (int)fan_count_value) {
        fprintf(stderr, "Fan %d does not exist; SMC reports %.0f fan(s).\n", fan_index + 1, fan_count_value);
        goto done;
    }
    const int fan_count = (int)fan_count_value;

    FanControlEndpoint endpoint;
    if (detect_fan_control_endpoint(connection, fan_index, &endpoint) != 0) {
        fprintf(stderr, "Fan %d is readable, but no verified fan-control interface is available.\n", fan_index + 1);
        goto done;
    }

    char min_key[5];
    char max_key[5];
    char actual_key[5];
    char target_key[5];
    snprintf(min_key, sizeof(min_key), "F%dMn", fan_index);
    snprintf(max_key, sizeof(max_key), "F%dMx", fan_index);
    snprintf(actual_key, sizeof(actual_key), "F%dAc", fan_index);
    snprintf(target_key, sizeof(target_key), "F%dTg", fan_index);

    double min_rpm = 0;
    double max_rpm = 0;
    if (read_number(connection, min_key, &min_rpm) != 0
        || read_number(connection, max_key, &max_rpm) != 0
        || !isfinite(min_rpm)
        || !isfinite(max_rpm)
        || min_rpm < 0
        || max_rpm <= min_rpm
        || max_rpm < 1000
        || max_rpm > FAN_SAFE_MAX_RPM) {
        fprintf(stderr, "Fan %d RPM range could not be read safely from SMC.\n", fan_index + 1);
        goto done;
    }

    double actual_rpm = 0;
    double current_target_rpm = 0;
    const double consistency_ceiling = max_rpm + 500.0;
    if (read_number(connection, actual_key, &actual_rpm) != 0
        || !isfinite(actual_rpm)
        || actual_rpm < 0
        || actual_rpm > consistency_ceiling) {
        fprintf(stderr, "Fan %d actual RPM is outside the verified hardware range.\n", fan_index + 1);
        goto done;
    }
    // Zero is a valid target while firmware is in Auto/System mode, but an
    // implausibly high target means this key layout is not safe to control.
    if (read_number(connection, target_key, &current_target_rpm) != 0
        || !isfinite(current_target_rpm)
        || current_target_rpm < 0
        || current_target_rpm > consistency_ceiling) {
        fprintf(stderr, "Fan %d target RPM is outside the verified hardware range.\n", fan_index + 1);
        goto done;
    }

    FanControlState state;
    int state_present = load_fan_state(&state);
    int ftst_available = 0;
    int ftst_enabled = 0;
    if (read_ftst(connection, &ftst_available, &ftst_enabled) != 0) {
        goto done;
    }

    if (state_present == 2) {
        fprintf(stderr, "Migrating legacy fan ownership through verified automatic recovery.\n");
        const int automatic_recovery_verified =
            recover_stale_owner(connection, &state, fan_count) == 0;
        if (!thermofan_legacy_migration_allows_new_write(automatic_recovery_verified)) {
            fprintf(stderr, "Legacy fan ownership could not be migrated safely; refusing new writes.\n");
            goto done;
        }
        state_present = 0;
        ftst_available = 0;
        ftst_enabled = 0;
        if (read_ftst(connection, &ftst_available, &ftst_enabled) != 0) {
            goto done;
        }
    }

    if (state_present < 0) {
        fprintf(stderr, "ThermoFan ownership state is malformed; refusing hardware writes.\n");
        goto done;
    }

    // Validate the global flag against durable ownership before attempting
    // stale recovery. A stale record that never owned Ftst is not authority to
    // modify a diagnostic flag enabled by another process.
    if (!ftst_matches_durable_ownership(ftst_available, ftst_enabled, state_present, &state)) {
        fprintf(stderr, "Ftst is active without matching ThermoFan ownership; refusing hardware writes.\n");
        goto done;
    }
    if (state_present == 1
        && (state.flags & FAN_STATE_FTST_OWNED) != 0
        && !ftst_available) {
        fprintf(stderr, "ThermoFan ownership requires Ftst, but this firmware no longer exposes it.\n");
        goto done;
    }

    // require_owned_fan limits this call to a fan that durable state proves
    // this exact owner (PID plus process start time) holds. Anything else is
    // reported as THERMOFAN_ENGINE_FAN_NOT_OWNED before any hardware write, so
    // a caller can never mistake "nothing was done" for verified success.
    if (require_owned_fan
        && (state_present != 1
            || !state_owner_matches_identity(&state, owner_identity)
            || (state.touched_mask & fan_bit(fan_index)) == 0)) {
        fprintf(stderr, "Fan %d is not durably owned by the requesting process; no hardware write was attempted.\n", fan_index + 1);
        status = THERMOFAN_ENGINE_FAN_NOT_OWNED;
        goto done;
    }

    if (state_present == 1) {
        if (!state_owner_process_is_current(&state)) {
            if (recover_stale_owner(connection, &state, fan_count) != 0) {
                goto done;
            }
            state_present = 0;
            ftst_available = 0;
            ftst_enabled = 0;
            if (read_ftst(connection, &ftst_available, &ftst_enabled) != 0) {
                goto done;
            }
            // Recovery changed Ftst, so re-establish the invariant against
            // this final read before any further hardware write.
            if (!ftst_matches_durable_ownership(ftst_available, ftst_enabled, state_present, &state)) {
                fprintf(stderr, "Ftst is active without matching ThermoFan ownership after stale recovery; refusing hardware writes.\n");
                goto done;
            }
        } else if (!state_owner_matches_identity(&state, owner_identity)) {
            fprintf(stderr, "Fan control is owned by another live process; refusing hardware writes.\n");
            goto done;
        }
    }

    if (automatic_request) {
        if (release_fan_ownership(
                connection,
                fan_index,
                &endpoint,
                &state,
                &state_present
            ) != 0) {
            // Leave this as an ordinary failure unless the durable state check
            // below proves that this process still owns this exact fan. Auto
            // requests for an unowned fan create no recovery obligation.
            status = 1;
            goto done;
        }
        printf("Fan %d returned to automatic hardware control.\n", fan_index + 1);
        status = 0;
        goto done;
    }

    if (!process_identity_is_current(owner_identity)) {
        fprintf(stderr, "The launching application is unavailable; refusing manual fan control.\n");
        goto done;
    }
    if (rpm < (int)min_rpm) rpm = (int)min_rpm;
    if (rpm > (int)max_rpm) rpm = (int)max_rpm;

    if (state_present == 0) {
        initialize_fan_state(&state, owner_identity);
        state_present = 1;
    }
    const uint32_t bit = fan_bit(fan_index);
    if ((state.touched_mask & bit) == 0) {
        FanControlState next = state;
        next.touched_mask |= bit;
        if (save_fan_state(&next) != 0) {
            goto done;
        }
        state = next;
    }

    if (enable_manual_mode(
            connection,
            fan_index,
            &endpoint,
            ftst_available,
            ftst_enabled,
            &state
        ) != 0) {
        fprintf(stderr, "Fan %d did not enter exact manual mode within the safety deadline; returning it to automatic mode.\n", fan_index + 1);
        if (release_fan_ownership(connection, fan_index, &endpoint, &state, &state_present) != 0) {
            fprintf(stderr, "CRITICAL: ThermoFan engine status 75 (unverified hardware state): fan %d rollback to automatic control could not be verified; durable ownership was retained for daemon recovery.\n", fan_index + 1);
            status = EXIT_RECOVERY_REQUIRED;
        }
        goto done;
    }

    // Write return codes alone are not authoritative: error 0x87 has been
    // observed even when F*Tg was applied. Verify the target by readback.
    (void)write_number(connection, target_key, rpm);
    double applied_rpm = 0;
    int target_verified = 0;
    for (int attempt = 0; attempt < 6; attempt++) {
        sleep_milliseconds(50);
        if (read_number(connection, target_key, &applied_rpm) == 0
            && isfinite(applied_rpm)
            && applied_rpm >= 0
            && applied_rpm <= consistency_ceiling
            && fabs(applied_rpm - rpm) <= 25) {
            target_verified = 1;
            break;
        }
        if (attempt == 2) {
            (void)write_number_quiet(connection, target_key, rpm);
        }
    }
    if (!target_verified
        || !fan_manual_state_matches(connection, fan_index, &endpoint, 1)) {
        fprintf(stderr, "Fan %d target verification failed; requested %d RPM, SMC reports %.0f RPM. Returning to automatic mode.\n", fan_index + 1, rpm, applied_rpm);
        if (release_fan_ownership(connection, fan_index, &endpoint, &state, &state_present) != 0) {
            fprintf(stderr, "CRITICAL: ThermoFan engine status 75 (unverified hardware state): fan %d rollback to automatic control could not be verified; durable ownership was retained for daemon recovery.\n", fan_index + 1);
            status = EXIT_RECOVERY_REQUIRED;
        }
        goto done;
    }

    printf("Fan %d target verified on hardware: %.0f RPM.\n", fan_index + 1, applied_rpm);
    status = 0;

done:
    // Any non-success that leaves this client's durable ownership bit behind
    // means the fan may still be Manual/unknown. Surface the dedicated result
    // even if the failure occurred before the explicit rollback branch (for
    // example, a transient SMC read failure during a later Auto request, or a
    // lock failure). When the lock failed and durable ownership cannot even be
    // read, ownership is unknown and is treated the same way.
    if (status != 0
        && status != EXIT_RECOVERY_REQUIRED
        && status != THERMOFAN_ENGINE_FAN_NOT_OWNED) {
        FanControlState persisted_state;
        int persisted_state_present = load_fan_state(&persisted_state);
        const int owner_matches = persisted_state_present == 1
            && state_owner_matches_identity(&persisted_state, owner_identity);
        const int fan_owned = persisted_state_present == 1
            && (persisted_state.touched_mask & fan_bit(fan_index)) != 0;
        status = thermofan_status_after_persisted_ownership_check(
            status,
            EXIT_RECOVERY_REQUIRED,
            persisted_state_present == 1,
            owner_matches,
            fan_owned
        );
        if (status == EXIT_RECOVERY_REQUIRED) {
            fprintf(stderr, "ThermoFan engine status 75 (unverified hardware state): fan %d is still durably owned by this client after a failed operation.\n", fan_index + 1);
        } else if (lock_failed && persisted_state_present < 0) {
            fprintf(stderr, "ThermoFan engine status 75 (unverified hardware state): fan access could not be serialized and durable ownership could not be read.\n");
            status = EXIT_RECOVERY_REQUIRED;
        }
    }
    if (connection != IO_OBJECT_NULL) {
        IOServiceClose(connection);
    }
    release_fan_locks(&locks);
    return status;
}

const char *thermofan_engine_version(void) {
    return HELPER_VERSION;
}

static int engine_is_privileged(void) {
    if (geteuid() != 0) {
        fprintf(stderr, "ThermoFan's fan-control engine requires a root launch daemon.\n");
        return 0;
    }
    return 1;
}

int thermofan_engine_apply(
    int fan_index,
    int mode,
    int rpm,
    const ProcessIdentity *owner_identity,
    int require_owned_fan
) {
    static const char *mode_names[] = {"automatic", "fixed", "curve"};
    if (!engine_is_privileged()
        || fan_index < 0
        || fan_index >= FAN_STATE_MAX_FANS
        || mode < 0
        || mode > 2
        || owner_identity == NULL
        || owner_identity->pid <= 1
        || owner_identity->start_seconds == 0
        || owner_identity->start_microseconds >= 1000000
        || (require_owned_fan != 0 && require_owned_fan != 1)
        || (mode == 0 && rpm != 0)
        || (mode != 0 && (rpm < 0 || rpm > FAN_SAFE_MAX_RPM))) {
        return 1;
    }
    if (mode != 0
        && atomic_load_explicit(
            &manual_writes_ready,
            memory_order_acquire
        ) != 1) {
        fprintf(stderr, "ThermoFan engine status 75 (write barrier): manual fan writes stay blocked until startup recovery and legacy helper retirement are verified; no hardware was accessed.\n");
        return EXIT_RECOVERY_REQUIRED;
    }
    return apply_fan(
        fan_index,
        mode_names[mode],
        rpm,
        owner_identity,
        require_owned_fan
    );
}

static int read_verified_fan_count(io_connect_t connection, int *fan_count) {
    double fan_count_value = 0;
    if (fan_count == NULL
        || read_number(connection, "FNum", &fan_count_value) != 0
        || !isfinite(fan_count_value)
        || fan_count_value < 0
        || fan_count_value > FAN_STATE_MAX_FANS
        || fan_count_value != floor(fan_count_value)) {
        fprintf(stderr, "The SMC fan count is outside the verified range.\n");
        return 1;
    }
    *fan_count = (int)fan_count_value;
    return 0;
}

static int recover_recorded_state(
    const ProcessIdentity *owner_identity,
    int require_exact_owner,
    int scan_for_legacy_manual_fans
) {
    if (!engine_is_privileged()) {
        return 1;
    }

    FanLocks locks = {-1, -1};
    if (acquire_fan_locks(&locks) != 0) {
        fprintf(stderr, "ThermoFan engine status 75 (unverified hardware state): fan recovery could not be serialized.\n");
        return EXIT_RECOVERY_REQUIRED;
    }

    // Every recovery obligation is attempted even when another one cannot be
    // met, so one unrecoverable record never keeps a different record's fans
    // out of Auto. Any failure still makes the whole result 75.
    int status = EXIT_RECOVERY_REQUIRED;
    int failed = 0;
    io_connect_t connection = IO_OBJECT_NULL;
    int parent_fd = -1;
    int fan_count = 0;
    int legacy_present = 0;
    int state_present = 0;
    int recover_current = 0;
    FanControlState legacy_state;
    FanControlState state;
    struct stat legacy_identity;
    memset(&legacy_state, 0, sizeof(legacy_state));
    memset(&legacy_identity, 0, sizeof(legacy_identity));

    parent_fd = open_state_parent_directory();
    if (parent_fd < 0) {
        failed = 1;
    } else {
        legacy_present = load_legacy_location_state(parent_fd, &legacy_state, &legacy_identity);
        if (legacy_present < 0) {
            fprintf(stderr, "A fan ownership record at the legacy location is unreadable or malformed; automatic recovery is uncertain.\n");
            failed = 1;
        }
    }

    state_present = load_fan_state(&state);
    if (state_present < 0) {
        fprintf(stderr, "ThermoFan ownership state is malformed; automatic recovery is uncertain.\n");
        failed = 1;
    }
    recover_current = state_present > 0;
    if (recover_current && require_exact_owner) {
        // The v1 layout has no process start time. PID alone is not cleanup
        // authority because the PID may have been reused.
        if (state_present != 1
            || owner_identity == NULL
            || !state_owner_matches_identity(&state, owner_identity)) {
            recover_current = 0;
        }
    }
    const int recover_legacy = legacy_present > 0;
    // An empty legacy-location file carries no obligation and is retired.
    const int remove_empty_legacy = legacy_present == 0 && legacy_identity.st_ino != 0;

    if (!recover_legacy && !recover_current && !scan_for_legacy_manual_fans) {
        if (remove_empty_legacy
            && remove_legacy_location_state(parent_fd, &legacy_identity) != 0) {
            failed = 1;
        }
        status = failed ? EXIT_RECOVERY_REQUIRED : 0;
        goto done;
    }

    if (open_smc(&connection) != 0) {
        goto done;
    }
    if (read_verified_fan_count(connection, &fan_count) != 0) {
        goto done;
    }
    // A record at the legacy location is never adopted: whichever earlier
    // helper wrote it, returning its fans to Auto is the only safe migration.
    // It is removed only after that recovery was verified.
    if (recover_legacy) {
        fprintf(stderr, "Migrating fan ownership recorded at the legacy location through verified automatic recovery.\n");
        if (recover_fans_to_auto(connection, &legacy_state, fan_count) != 0
            || remove_legacy_location_state(parent_fd, &legacy_identity) != 0) {
            failed = 1;
        }
    } else if (remove_empty_legacy
        && remove_legacy_location_state(parent_fd, &legacy_identity) != 0) {
        failed = 1;
    }
    if (recover_current && recover_stale_owner(connection, &state, fan_count) != 0) {
        failed = 1;
    }
    if (scan_for_legacy_manual_fans
        && return_legacy_manual_fans_to_auto(connection, fan_count) != 0) {
        failed = 1;
    }
    status = failed ? EXIT_RECOVERY_REQUIRED : 0;

done:
    if (connection != IO_OBJECT_NULL) {
        IOServiceClose(connection);
    }
    if (parent_fd >= 0) {
        close(parent_fd);
    }
    release_fan_locks(&locks);
    return status;
}

int thermofan_engine_recover_startup(void) {
    atomic_store_explicit(&startup_recovery_succeeded, 0, memory_order_release);
    atomic_store_explicit(&manual_writes_ready, 0, memory_order_release);
    // A manual-mode scan left pending by an incomplete legacy retirement is
    // repeated here, so re-verification before service removal or shutdown
    // covers it as well. Only a completed retirement clears it, because a
    // legacy process that has not been drained could still change a fan.
    int status = recover_recorded_state(
        NULL,
        0,
        atomic_load_explicit(&legacy_manual_scan_pending, memory_order_acquire)
    );
    if (status == 0) {
        atomic_store_explicit(&startup_recovery_succeeded, 1, memory_order_release);
    }
    return status;
}

int thermofan_engine_return_all(const ProcessIdentity *owner_identity) {
    if (owner_identity == NULL
        || owner_identity->pid <= 1
        || owner_identity->start_seconds == 0
        || owner_identity->start_microseconds >= 1000000) {
        return 1;
    }
    return recover_recorded_state(owner_identity, 1, 0);
}

int thermofan_engine_open_process_exit_watch(const ProcessIdentity *identity) {
    if (identity == NULL || !process_identity_is_current(identity)) {
        return -1;
    }

    int queue = kqueue();
    if (queue < 0) {
        return -1;
    }
    struct kevent change;
    EV_SET(
        &change,
        (uintptr_t)identity->pid,
        EVFILT_PROC,
        EV_ADD | EV_ENABLE | EV_ONESHOT,
        NOTE_EXIT,
        0,
        NULL
    );
    if (kevent(queue, &change, 1, NULL, 0, NULL) != 0
        || !process_identity_is_current(identity)) {
        close(queue);
        return -1;
    }
    return queue;
}

int thermofan_engine_consume_process_exit_watch(int watch_fd) {
    if (watch_fd < 0) {
        return 1;
    }
    // Bounded: the caller drains this from a serial queue that also runs
    // recovery, so a spurious readiness notification must never block it.
    const double deadline = monotonic_seconds() + EXIT_WATCH_CONSUME_TIMEOUT_SECONDS;
    for (;;) {
        double remaining = deadline - monotonic_seconds();
        if (remaining <= 0) {
            return THERMOFAN_ENGINE_EXIT_NOT_CONFIRMED;
        }
        if (remaining > EXIT_WATCH_CONSUME_TIMEOUT_SECONDS) {
            remaining = EXIT_WATCH_CONSUME_TIMEOUT_SECONDS;
        }
        struct timespec timeout;
        timeout.tv_sec = (time_t)remaining;
        timeout.tv_nsec = (long)((remaining - (double)timeout.tv_sec) * 1000000000.0);
        if (timeout.tv_nsec < 0) {
            timeout.tv_nsec = 0;
        } else if (timeout.tv_nsec > 999999999L) {
            timeout.tv_nsec = 999999999L;
        }

        struct kevent event;
        memset(&event, 0, sizeof(event));
        int result = kevent(watch_fd, NULL, 0, &event, 1, &timeout);
        if (result > 0) {
            // Only an exact NOTE_EXIT proves the watched process ended.
            return event.filter == EVFILT_PROC
                && (event.flags & EV_ERROR) == 0
                && (event.fflags & NOTE_EXIT) != 0
                ? 0
                : 1;
        }
        if (result == 0) {
            return THERMOFAN_ENGINE_EXIT_NOT_CONFIRMED;
        }
        if (errno != EINTR) {
            return 1;
        }
    }
}

#define LEGACY_PROCESS_DRAIN_SECONDS 5.0
#define LEGACY_PROCESS_DRAIN_POLL_MILLISECONDS 50
#define LEGACY_PROCESS_DRAIN_CLEAR_SCANS 3

typedef struct {
    int file_descriptor;
    struct stat attributes;
} LegacyHelperInode;

typedef struct {
    ProcessIdentity *items;
    size_t count;
    size_t capacity;
} LegacyProcessSet;

// Legacy helper processes observed during retirement, identified by PID and
// start time. They are kept for the daemon's lifetime so a retry after a
// failed drain waits for these exact processes: once an executable has been
// unlinked, proc_pidpath can no longer be relied on to rediscover them.
static LegacyProcessSet retained_legacy_processes = {NULL, 0, 0};
static pthread_mutex_t legacy_retirement_mutex = PTHREAD_MUTEX_INITIALIZER;

static int legacy_helper_attributes_are_safe(const struct stat *attributes) {
    return attributes != NULL
        && S_ISREG(attributes->st_mode)
        && attributes->st_uid == 0
        && attributes->st_nlink == 1
        && (attributes->st_mode & 0022) == 0;
}

static void close_legacy_helper_inodes(LegacyHelperInode inodes[LEGACY_HELPER_COUNT]) {
    for (size_t index = 0; index < LEGACY_HELPER_COUNT; index++) {
        if (inodes[index].file_descriptor >= 0) {
            close(inodes[index].file_descriptor);
            inodes[index].file_descriptor = -1;
        }
    }
}

static int exact_legacy_executable_path(const char *path) {
    if (path == NULL) {
        return 0;
    }
    for (size_t index = 0; index < LEGACY_HELPER_COUNT; index++) {
        if (strcmp(path, legacy_helper_paths[index].absolute_path) == 0) {
            return 1;
        }
    }
    return 0;
}

static int legacy_process_set_add(
    LegacyProcessSet *processes,
    const ProcessIdentity *identity
) {
    if (processes == NULL || identity == NULL) {
        return 1;
    }
    for (size_t index = 0; index < processes->count; index++) {
        if (thermofan_process_identity_matches(
                processes->items[index].pid,
                processes->items[index].start_seconds,
                processes->items[index].start_microseconds,
                identity->pid,
                identity->start_seconds,
                identity->start_microseconds
            )) {
            return 0;
        }
    }
    if (processes->count == processes->capacity) {
        size_t new_capacity = processes->capacity == 0
            ? 4
            : processes->capacity * 2;
        if (new_capacity < processes->capacity
            || new_capacity > SIZE_MAX / sizeof(*processes->items)) {
            return 1;
        }
        ProcessIdentity *new_items = realloc(
            processes->items,
            new_capacity * sizeof(*new_items)
        );
        if (new_items == NULL) {
            return 1;
        }
        processes->items = new_items;
        processes->capacity = new_capacity;
    }
    processes->items[processes->count++] = *identity;
    return 0;
}

// Matches an executable path that is a legacy helper, either by its exact
// installed path or, while the verified legacy inodes are open, by device and
// inode, which also covers aliases of the same file such as the Data-volume
// firmlink path. stat() is only called for paths whose file name is a legacy
// executable name, so unrelated (possibly slow network) paths are untouched.
static int legacy_executable_path_matches(
    const char *path,
    const LegacyHelperInode *inodes
) {
    if (exact_legacy_executable_path(path)) {
        return 1;
    }
    if (inodes == NULL) {
        return 0;
    }

    const char *separator = strrchr(path, '/');
    const char *file_name = separator == NULL ? path : separator + 1;
    int name_matches = 0;
    for (size_t index = 0; index < LEGACY_HELPER_COUNT; index++) {
        if (legacy_helper_paths[index].is_executable
            && strcmp(file_name, legacy_helper_paths[index].name) == 0) {
            name_matches = 1;
            break;
        }
    }
    if (!name_matches) {
        return 0;
    }

    struct stat attributes;
    if (stat(path, &attributes) != 0) {
        return 0;
    }
    for (size_t index = 0; index < LEGACY_HELPER_COUNT; index++) {
        if (inodes[index].file_descriptor >= 0
            && attributes_identify_same_inode(&inodes[index].attributes, &attributes)) {
            return 1;
        }
    }
    return 0;
}

static int legacy_process_matches(pid_t process_id, const LegacyHelperInode *inodes) {
    char executable_path[PROC_PIDPATHINFO_MAXSIZE];
    memset(executable_path, 0, sizeof(executable_path));
    int path_length = proc_pidpath(
        process_id,
        executable_path,
        (uint32_t)sizeof(executable_path)
    );
    if (path_length <= 0) {
        return 0;
    }
    executable_path[sizeof(executable_path) - 1] = '\0';
    return legacy_executable_path_matches(executable_path, inodes);
}

static void legacy_process_set_prune_exited(LegacyProcessSet *processes) {
    size_t kept = 0;
    for (size_t index = 0; index < processes->count; index++) {
        if (process_identity_is_current(&processes->items[index])) {
            processes->items[kept++] = processes->items[index];
        }
    }
    processes->count = kept;
}

static void legacy_process_set_clear(LegacyProcessSet *processes) {
    free(processes->items);
    processes->items = NULL;
    processes->count = 0;
    processes->capacity = 0;
}

// Adds every process currently running a legacy helper executable to the set.
// inodes, when not NULL, holds the verified legacy files that are still linked.
static int snapshot_exact_legacy_processes(
    LegacyProcessSet *processes,
    const LegacyHelperInode *inodes
) {
    if (processes == NULL) {
        return 1;
    }

    int required_bytes = proc_listpids(PROC_ALL_PIDS, 0, NULL, 0);
    if (required_bytes <= 0) {
        fprintf(stderr, "Could not enumerate processes while retiring legacy helpers.\n");
        return 1;
    }

    pid_t *process_ids = NULL;
    int used_bytes = 0;
    int buffer_bytes = required_bytes;
    for (int attempt = 0; attempt < 4; attempt++) {
        const int headroom = 256 * (int)sizeof(pid_t);
        if (buffer_bytes > INT_MAX - headroom) {
            free(process_ids);
            return 1;
        }
        buffer_bytes += headroom;
        pid_t *larger_buffer = realloc(process_ids, (size_t)buffer_bytes);
        if (larger_buffer == NULL) {
            free(process_ids);
            return 1;
        }
        process_ids = larger_buffer;
        memset(process_ids, 0, (size_t)buffer_bytes);
        used_bytes = proc_listpids(
            PROC_ALL_PIDS,
            0,
            process_ids,
            buffer_bytes
        );
        if (used_bytes < 0 || used_bytes > buffer_bytes) {
            free(process_ids);
            return 1;
        }
        if (used_bytes < buffer_bytes) {
            break;
        }
        if (attempt == 3) {
            free(process_ids);
            fprintf(stderr, "Process enumeration remained truncated during legacy retirement.\n");
            return 1;
        }
    }
    if (used_bytes == 0 || used_bytes % (int)sizeof(pid_t) != 0) {
        free(process_ids);
        return 1;
    }

    size_t process_count = (size_t)used_bytes / sizeof(pid_t);
    for (size_t index = 0; index < process_count; index++) {
        pid_t process_id = process_ids[index];
        if (process_id <= 1) {
            continue;
        }
        if (!legacy_process_matches(process_id, inodes)) {
            continue;
        }

        ProcessIdentity identity;
        if (thermofan_engine_read_process_identity(process_id, &identity) != 0) {
            // An exit between proc_pidpath and proc_pidinfo is harmless. Any
            // still-running legacy helper process must remain identifiable.
            if (legacy_process_matches(process_id, inodes)) {
                free(process_ids);
                fprintf(stderr, "Could not identify an active legacy helper process safely.\n");
                return 1;
            }
            continue;
        }
        if (legacy_process_set_add(processes, &identity) != 0) {
            free(process_ids);
            return 1;
        }
    }
    free(process_ids);
    return 0;
}

static int legacy_process_set_has_current_processes(
    const LegacyProcessSet *processes
) {
    if (processes == NULL) {
        return 1;
    }
    for (size_t index = 0; index < processes->count; index++) {
        if (process_identity_is_current(&processes->items[index])) {
            return 1;
        }
    }
    return 0;
}

static int drain_exact_legacy_processes(LegacyProcessSet *processes) {
    struct timespec started;
    if (processes == NULL
        || clock_gettime(CLOCK_MONOTONIC, &started) != 0) {
        return 1;
    }

    int consecutive_clear_scans = 0;
    for (;;) {
        if (snapshot_exact_legacy_processes(processes, NULL) != 0) {
            return 1;
        }
        if (legacy_process_set_has_current_processes(processes)) {
            consecutive_clear_scans = 0;
        } else {
            consecutive_clear_scans++;
            if (consecutive_clear_scans >= LEGACY_PROCESS_DRAIN_CLEAR_SCANS) {
                return 0;
            }
        }

        struct timespec now;
        if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
            return 1;
        }
        double elapsed = (double)(now.tv_sec - started.tv_sec)
            + ((double)(now.tv_nsec - started.tv_nsec) / 1000000000.0);
        if (elapsed >= LEGACY_PROCESS_DRAIN_SECONDS) {
            fprintf(stderr, "Timed out waiting for an exact legacy helper process to exit.\n");
            return 1;
        }
        sleep_milliseconds(LEGACY_PROCESS_DRAIN_POLL_MILLISECONDS);
    }
}

static int open_and_verify_legacy_helpers(
    int directory_fd,
    LegacyHelperInode inodes[LEGACY_HELPER_COUNT]
) {
    for (size_t index = 0; index < LEGACY_HELPER_COUNT; index++) {
        struct stat path_attributes;
        if (fstatat(
                directory_fd,
                legacy_helper_paths[index].name,
                &path_attributes,
                AT_SYMLINK_NOFOLLOW
            ) != 0) {
            if (errno == ENOENT) {
                continue;
            }
            return 1;
        }
        if (!legacy_helper_attributes_are_safe(&path_attributes)) {
            fprintf(stderr, "Refusing to retire unsafe legacy helper path %s.\n", legacy_helper_paths[index].name);
            return 1;
        }

        int file_descriptor = openat(
            directory_fd,
            legacy_helper_paths[index].name,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        );
        if (file_descriptor < 0) {
            return 1;
        }
        struct stat descriptor_attributes;
        if (fstat(file_descriptor, &descriptor_attributes) != 0
            || !legacy_helper_attributes_are_safe(&descriptor_attributes)
            || !attributes_identify_same_inode(
                &path_attributes,
                &descriptor_attributes
            )) {
            close(file_descriptor);
            fprintf(stderr, "Legacy helper path changed during safe retirement.\n");
            return 1;
        }
        inodes[index].file_descriptor = file_descriptor;
        inodes[index].attributes = descriptor_attributes;
    }
    return 0;
}

static int revoke_legacy_helper_execution(
    LegacyHelperInode inodes[LEGACY_HELPER_COUNT]
) {
    const mode_t forbidden_mode = S_ISUID | S_ISGID
        | S_IXUSR | S_IXGRP | S_IXOTH;
    for (size_t index = 0; index < LEGACY_HELPER_COUNT; index++) {
        int file_descriptor = inodes[index].file_descriptor;
        if (file_descriptor < 0) {
            continue;
        }
        mode_t safe_mode = inodes[index].attributes.st_mode & 07777;
        safe_mode &= ~forbidden_mode;
        if (fchmod(file_descriptor, safe_mode) != 0
            || full_fsync(file_descriptor) != 0) {
            fprintf(stderr, "Could not revoke legacy helper execution safely.\n");
            return 1;
        }
        struct stat revoked_attributes;
        if (fstat(file_descriptor, &revoked_attributes) != 0
            || !legacy_helper_attributes_are_safe(&revoked_attributes)
            || !attributes_identify_same_inode(
                &inodes[index].attributes,
                &revoked_attributes
            )
            || (revoked_attributes.st_mode & forbidden_mode) != 0) {
            fprintf(stderr, "Legacy helper execution revocation could not be verified.\n");
            return 1;
        }
        inodes[index].attributes = revoked_attributes;
    }
    return 0;
}

static int unlink_revoked_legacy_helpers(
    int directory_fd,
    LegacyHelperInode inodes[LEGACY_HELPER_COUNT]
) {
    int removed_any = 0;
    for (size_t index = 0; index < LEGACY_HELPER_COUNT; index++) {
        int file_descriptor = inodes[index].file_descriptor;
        if (file_descriptor < 0) {
            continue;
        }
        struct stat path_attributes;
        if (fstatat(
                directory_fd,
                legacy_helper_paths[index].name,
                &path_attributes,
                AT_SYMLINK_NOFOLLOW
            ) != 0
            || !legacy_helper_attributes_are_safe(&path_attributes)
            || !attributes_identify_same_inode(
                &inodes[index].attributes,
                &path_attributes
            )
            || (path_attributes.st_mode
                & (S_ISUID | S_ISGID | S_IXUSR | S_IXGRP | S_IXOTH)) != 0) {
            fprintf(stderr, "Legacy helper path changed before unlink.\n");
            return 1;
        }
        if (unlinkat(directory_fd, legacy_helper_paths[index].name, 0) != 0) {
            return 1;
        }
        struct stat unlinked_attributes;
        if (fstat(file_descriptor, &unlinked_attributes) != 0
            || unlinked_attributes.st_nlink != 0
            || !attributes_identify_same_inode(
                &inodes[index].attributes,
                &unlinked_attributes
            )) {
            fprintf(stderr, "Legacy helper unlink could not be verified.\n");
            return 1;
        }
        removed_any = 1;
    }
    if (removed_any && full_fsync(directory_fd) != 0) {
        return 1;
    }
    return 0;
}

static int legacy_helper_inodes_include_executable(
    const LegacyHelperInode inodes[LEGACY_HELPER_COUNT]
) {
    for (size_t index = 0; index < LEGACY_HELPER_COUNT; index++) {
        if (inodes[index].file_descriptor >= 0
            && legacy_helper_paths[index].is_executable) {
            return 1;
        }
    }
    return 0;
}

// Caller holds legacy_retirement_mutex.
static int remove_legacy_helpers_serialized(void) {
    atomic_store_explicit(&manual_writes_ready, 0, memory_order_release);
    int expected_recovery_state = 1;
    if (!atomic_compare_exchange_strong_explicit(
            &startup_recovery_succeeded,
            &expected_recovery_state,
            0,
            memory_order_acq_rel,
            memory_order_acquire
        )) {
        fprintf(stderr, "Legacy helper cleanup requires successful startup recovery.\n");
        return 1;
    }

    LegacyHelperInode inodes[LEGACY_HELPER_COUNT];
    for (size_t index = 0; index < LEGACY_HELPER_COUNT; index++) {
        memset(&inodes[index], 0, sizeof(inodes[index]));
        inodes[index].file_descriptor = -1;
    }
    int directory_fd = open(
        LEGACY_HELPER_DIRECTORY,
        O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW
    );
    if (directory_fd < 0) {
        if (errno != ENOENT) {
            return 1;
        }
    } else {
        struct stat directory_attributes;
        if (fstat(directory_fd, &directory_attributes) != 0
            || !S_ISDIR(directory_attributes.st_mode)
            || directory_attributes.st_uid != 0
            || (directory_attributes.st_mode & 0022) != 0) {
            fprintf(stderr, "Legacy helper directory has unsafe ownership or permissions.\n");
            close(directory_fd);
            return 1;
        }
        if (open_and_verify_legacy_helpers(directory_fd, inodes) != 0) {
            close_legacy_helper_inodes(inodes);
            close(directory_fd);
            return 1;
        }
        if (legacy_helper_inodes_include_executable(inodes)) {
            atomic_store_explicit(&legacy_manual_scan_pending, 1, memory_order_release);
        }
        // Execution is revoked first so no new legacy process can start; the
        // processes already running a verified legacy inode are then recorded
        // by PID and start time while the paths can still be resolved.
        if (revoke_legacy_helper_execution(inodes) != 0
            || snapshot_exact_legacy_processes(&retained_legacy_processes, inodes) != 0
            || unlink_revoked_legacy_helpers(directory_fd, inodes) != 0) {
            close_legacy_helper_inodes(inodes);
            close(directory_fd);
            legacy_process_set_prune_exited(&retained_legacy_processes);
            return 1;
        }
        close_legacy_helper_inodes(inodes);
        close(directory_fd);
    }

    // Scan once more by exact path after retirement, then wait for every
    // retained identity, including those recorded by an earlier failed call
    // whose executables were already unlinked.
    int status = snapshot_exact_legacy_processes(&retained_legacy_processes, NULL);
    if (status == 0) {
        status = drain_exact_legacy_processes(&retained_legacy_processes);
    }
    if (status != 0) {
        legacy_process_set_prune_exited(&retained_legacy_processes);
        return 1;
    }
    legacy_process_set_clear(&retained_legacy_processes);

    const int scan_for_manual_fans =
        atomic_load_explicit(&legacy_manual_scan_pending, memory_order_acquire);
    if (recover_recorded_state(NULL, 0, scan_for_manual_fans) != 0) {
        fprintf(stderr, "Final automatic recovery after legacy retirement failed.\n");
        return 1;
    }
    if (scan_for_manual_fans) {
        atomic_store_explicit(&legacy_manual_scan_pending, 0, memory_order_release);
    }
    atomic_store_explicit(&startup_recovery_succeeded, 1, memory_order_release);
    atomic_store_explicit(&manual_writes_ready, 1, memory_order_release);
    return 0;
}

int thermofan_engine_remove_legacy_helpers(void) {
    if (!engine_is_privileged()) {
        return 1;
    }
    if (pthread_mutex_lock(&legacy_retirement_mutex) != 0) {
        return 1;
    }
    int status = remove_legacy_helpers_serialized();
    (void)pthread_mutex_unlock(&legacy_retirement_mutex);
    return status;
}
