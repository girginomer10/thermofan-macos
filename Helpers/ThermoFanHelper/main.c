#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <fcntl.h>
#include <libproc.h>
#include <limits.h>
#include <math.h>
#include <mach/mach_error.h>
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
#define FAN_STATE_DIRECTORY "/var/run"
#define FAN_STATE_DIRECTORY_GROUP 1
#define FAN_STATE_BASENAME "io.github.girginomer10.ThermoFan.fan.state"
#define FAN_LOCK_PATH "/var/run/io.github.girginomer10.ThermoFan.fan.lock"
#define FAN_STATE_MAGIC 0x54464638u
#define FAN_STATE_VERSION 2u
#define FAN_STATE_FTST_OWNED 0x1u
#define FAN_STATE_ALLOWED_FLAGS FAN_STATE_FTST_OWNED
#define FAN_STATE_MAX_FANS 8
#define FAN_SAFE_MAX_RPM 20000
#define EXIT_RECOVERY_REQUIRED THERMOFAN_ENGINE_RECOVERY_REQUIRED
#define STATE_TEMP_ATTEMPTS 32

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
    FAN_CONTROL_FORCE_MASK
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

static int open_root_owned_file(const char *path) {
    int descriptor = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (descriptor < 0) {
        fprintf(stderr, "Could not open privileged fan state at %s: %s.\n", path, strerror(errno));
        return -1;
    }

    struct stat attributes;
    if (fstat(descriptor, &attributes) != 0
        || !S_ISREG(attributes.st_mode)
        || attributes.st_uid != 0
        || attributes.st_nlink != 1
        || (attributes.st_mode & 077) != 0) {
        fprintf(stderr, "Privileged fan state at %s has unsafe ownership or permissions.\n", path);
        close(descriptor);
        return -1;
    }
    if (fchown(descriptor, 0, 0) != 0 || fchmod(descriptor, 0600) != 0) {
        fprintf(stderr, "Could not secure privileged fan state at %s: %s.\n", path, strerror(errno));
        close(descriptor);
        return -1;
    }
    return descriptor;
}

static int open_state_directory(void) {
    int descriptor = open(FAN_STATE_DIRECTORY, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (descriptor < 0) {
        fprintf(stderr, "Could not open privileged state directory: %s.\n", strerror(errno));
        return -1;
    }

    // Darwin's /private/var/run is intentionally root:daemon (gid 1), 0775.
    // Reject every other writable parent shape while accepting that system
    // directory; state objects themselves remain root-only and no-follow.
    struct stat attributes;
    if (fstat(descriptor, &attributes) != 0
        || !S_ISDIR(attributes.st_mode)
        || attributes.st_uid != 0
        || (attributes.st_mode & 0002) != 0
        || ((attributes.st_mode & 0020) != 0
            && attributes.st_gid != FAN_STATE_DIRECTORY_GROUP)) {
        fprintf(stderr, "Privileged state directory has unsafe ownership or permissions.\n");
        close(descriptor);
        return -1;
    }
    return descriptor;
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
    if (state_fd < 0) {
        close(directory_fd);
        return -1;
    }

    struct stat attributes;
    if (fstat(state_fd, &attributes) != 0
        || !S_ISREG(attributes.st_mode)
        || attributes.st_uid != 0
        || attributes.st_nlink != 1
        || (attributes.st_mode & 077) != 0
        || attributes.st_dev != path_attributes.st_dev
        || attributes.st_ino != path_attributes.st_ino) {
        close(state_fd);
        close(directory_fd);
        return -1;
    }
    close(directory_fd);

    if (attributes.st_size == 0) {
        memset(state, 0, sizeof(*state));
        close(state_fd);
        return 0;
    }
    if (attributes.st_size == (off_t)THERMOFAN_LEGACY_FAN_STATE_SIZE) {
        uint8_t legacy_bytes[THERMOFAN_LEGACY_FAN_STATE_SIZE];
        ssize_t legacy_count = pread(state_fd, legacy_bytes, sizeof(legacy_bytes), 0);
        ThermoFanLegacyFanState legacy;
        if (legacy_count != (ssize_t)sizeof(legacy_bytes)
            || !thermofan_decode_legacy_fan_state(
                legacy_bytes,
                sizeof(legacy_bytes),
                &legacy
            )) {
            close(state_fd);
            return -1;
        }
        close(state_fd);
        memset(state, 0, sizeof(*state));
        state->owner_pid = legacy.owner_pid;
        state->touched_mask = legacy.touched_mask;
        state->refcount = legacy.refcount;
        state->flags = legacy.flags;
        return 2;
    }
    if (attributes.st_size != (off_t)sizeof(*state)) {
        close(state_fd);
        return -1;
    }

    ssize_t count = pread(state_fd, state, sizeof(*state), 0);
    close(state_fd);
    if (count != (ssize_t)sizeof(*state) || !fan_state_is_valid(state)) {
        return -1;
    }
    return 1;
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
        || fsync(temporary_fd) != 0) {
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
    if (fsync(directory_fd) != 0) {
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
        || fsync(directory_fd) != 0) {
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

    // FS! is a legacy Intel/T2 bitmask. Falling back to it on an M-series Mac
    // would turn an unknown firmware layout into a privileged hardware write.
    if (!is_apple_silicon_build()
        && read_number_quiet(connection, "FS!", &mode_value) == 0
        && isfinite(mode_value)) {
        endpoint->kind = FAN_CONTROL_FORCE_MASK;
        endpoint->mode_key[0] = '\0';
        return 0;
    }

    endpoint->kind = FAN_CONTROL_NONE;
    return 1;
}

static int write_fan_manual_state(io_connect_t connection, int fan_index, const FanControlEndpoint *endpoint, int enabled) {
    if (endpoint->kind == FAN_CONTROL_PER_FAN_MODE) {
        return write_number_quiet(connection, endpoint->mode_key, enabled ? 1 : 0);
    }
    if (endpoint->kind != FAN_CONTROL_FORCE_MASK) {
        return 1;
    }

    double mask_value = 0;
    if (read_number_quiet(connection, "FS!", &mask_value) != 0 || !isfinite(mask_value)) {
        return 1;
    }
    int mask = (int)mask_value;
    if (enabled) {
        mask |= 1 << fan_index;
    } else {
        mask &= ~(1 << fan_index);
    }
    return write_number_quiet(connection, "FS!", mask);
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
    if (endpoint->kind != FAN_CONTROL_FORCE_MASK
        || read_number_quiet(connection, "FS!", &value) != 0
        || !isfinite(value)) {
        return 0;
    }
    return (((((int)value) & (1 << fan_index)) != 0) ? 1 : 0) == expected_manual;
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

static int recover_stale_owner(
    io_connect_t connection,
    FanControlState *state,
    int fan_count
) {
    FanControlEndpoint endpoints[FAN_STATE_MAX_FANS];
    int endpoint_available[FAN_STATE_MAX_FANS] = {0};

    for (int fan = 0; fan < FAN_STATE_MAX_FANS; fan++) {
        if ((state->touched_mask & fan_bit(fan)) == 0) {
            continue;
        }
        if (fan >= fan_count || detect_fan_control_endpoint(connection, fan, &endpoints[fan]) != 0) {
            fprintf(stderr, "Could not safely recover stale fan %d ownership.\n", fan + 1);
            return 1;
        }
        endpoint_available[fan] = 1;
        (void)write_fan_manual_state(connection, fan, &endpoints[fan], 0);
    }

    if ((state->flags & FAN_STATE_FTST_OWNED) != 0) {
        int available = 0;
        int enabled = 0;
        if (read_ftst(connection, &available, &enabled) != 0 || !available) {
            fprintf(stderr, "Stale ownership says Ftst was held, but the key is unavailable.\n");
            return 1;
        }
        (void)write_number_quiet(connection, "Ftst", 0);
        if (wait_for_ftst(connection, 0, monotonic_seconds() + 5.0) != 0) {
            fprintf(stderr, "Could not clear stale Ftst ownership.\n");
            return 1;
        }
    }

    for (int fan = 0; fan < FAN_STATE_MAX_FANS; fan++) {
        if (!endpoint_available[fan]) {
            continue;
        }
        if (wait_for_fan_state(connection, fan, &endpoints[fan], 0, 50, 100) != 0) {
            fprintf(stderr, "Fan %d remained outside automatic/system mode during stale recovery.\n", fan + 1);
            return 1;
        }
    }

    if (clear_fan_state() != 0) {
        return 1;
    }
    fprintf(stderr, "Recovered durable fan ownership recorded for process %d.\n", state->owner_pid);
    memset(state, 0, sizeof(*state));
    return 0;
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
    if (ftst_enabled && (state->flags & FAN_STATE_FTST_OWNED) == 0) {
        return 1;
    }

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

static int apply_fan(
    int fan_index,
    const char *mode,
    int rpm,
    const ProcessIdentity *owner_identity,
    int require_owned_fan
) {
    io_connect_t connection = IO_OBJECT_NULL;
    int lock_fd = -1;
    int status = 1;

    lock_fd = open_root_owned_file(FAN_LOCK_PATH);
    if (lock_fd < 0 || flock(lock_fd, LOCK_EX) != 0) {
        fprintf(stderr, "Could not serialize fan hardware access: %s.\n", strerror(errno));
        if (lock_fd >= 0) close(lock_fd);
        return 1;
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
    if (ftst_available && ftst_enabled
        && (state_present != 1 || (state.flags & FAN_STATE_FTST_OWNED) == 0)) {
        fprintf(stderr, "Ftst is active without matching ThermoFan ownership; refusing hardware writes.\n");
        goto done;
    }
    if (state_present == 1
        && (state.flags & FAN_STATE_FTST_OWNED) != 0
        && !ftst_available) {
        fprintf(stderr, "ThermoFan ownership requires Ftst, but this firmware no longer exposes it.\n");
        goto done;
    }

    // A watchdog is started before the first manual write. If that write never
    // happens, parent exit must not send Auto into hardware owned by macOS or a
    // different controller. Cleanup authority exists only for the exact owner
    // PID and fan bit recorded by a successful ThermoFan claim.
    if (require_owned_fan
        && (state_present != 1
            || !state_owner_matches_identity(&state, owner_identity)
            || (state.touched_mask & fan_bit(fan_index)) == 0)) {
        status = 0;
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
        } else if (!state_owner_matches_identity(&state, owner_identity)) {
            fprintf(stderr, "Fan control is owned by another live process; refusing hardware writes.\n");
            goto done;
        }
    }

    if (strcmp(mode, "automatic") == 0 || strcmp(mode, "auto") == 0) {
        if (release_fan_ownership(
                connection,
                fan_index,
                &endpoint,
                &state,
                &state_present
            ) != 0) {
            // Leave this as an ordinary failure unless the durable state check
            // below proves that this process still owns this exact fan. Auto
            // requests for an unowned fan have no watchdog to recover it.
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
            fprintf(stderr, "CRITICAL: Fan %d rollback could not be verified; ownership state was retained for watchdog recovery.\n", fan_index + 1);
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
            fprintf(stderr, "CRITICAL: Fan %d rollback could not be verified; ownership state was retained for watchdog recovery.\n", fan_index + 1);
            status = EXIT_RECOVERY_REQUIRED;
        }
        goto done;
    }

    printf("Fan %d target verified on hardware: %.0f RPM.\n", fan_index + 1, applied_rpm);
    status = 0;

done:
    // Any non-success that leaves this app's durable ownership bit behind means
    // the fan may still be Manual/unknown. Surface the dedicated result even if
    // the failure occurred before the explicit rollback branch (for example, a
    // transient SMC read failure during a later Auto request).
    if (status != 0 && status != EXIT_RECOVERY_REQUIRED) {
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
    }
    if (connection != IO_OBJECT_NULL) {
        IOServiceClose(connection);
    }
    if (lock_fd >= 0) {
        (void)flock(lock_fd, LOCK_UN);
        close(lock_fd);
    }
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
        fprintf(stderr, "Manual fan writes remain blocked until startup recovery and legacy retirement succeed.\n");
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
    int require_exact_owner
) {
    if (!engine_is_privileged()) {
        return 1;
    }

    int status = EXIT_RECOVERY_REQUIRED;
    int lock_fd = open_root_owned_file(FAN_LOCK_PATH);
    io_connect_t connection = IO_OBJECT_NULL;
    if (lock_fd < 0 || flock(lock_fd, LOCK_EX) != 0) {
        fprintf(stderr, "Could not serialize startup fan recovery: %s.\n", strerror(errno));
        if (lock_fd >= 0) {
            close(lock_fd);
        }
        return EXIT_RECOVERY_REQUIRED;
    }

    FanControlState state;
    int state_present = load_fan_state(&state);
    if (state_present == 0) {
        status = 0;
        goto done;
    }
    if (state_present < 0) {
        fprintf(stderr, "ThermoFan ownership state is malformed; automatic recovery is uncertain.\n");
        goto done;
    }
    if (require_exact_owner) {
        // The v1 layout has no process start time. PID alone is not cleanup
        // authority because the PID may have been reused.
        if (state_present != 1
            || owner_identity == NULL
            || !state_owner_matches_identity(&state, owner_identity)) {
            status = 0;
            goto done;
        }
    }

    if (open_smc(&connection) != 0) {
        goto done;
    }
    int fan_count = 0;
    if (read_verified_fan_count(connection, &fan_count) != 0) {
        goto done;
    }
    if (recover_stale_owner(connection, &state, fan_count) != 0) {
        goto done;
    }
    status = 0;

done:
    if (connection != IO_OBJECT_NULL) {
        IOServiceClose(connection);
    }
    (void)flock(lock_fd, LOCK_UN);
    close(lock_fd);
    return status;
}

int thermofan_engine_recover_startup(void) {
    atomic_store_explicit(&startup_recovery_succeeded, 0, memory_order_release);
    atomic_store_explicit(&manual_writes_ready, 0, memory_order_release);
    int status = recover_recorded_state(NULL, 0);
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
    return recover_recorded_state(owner_identity, 1);
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
    struct kevent event;
    for (;;) {
        int result = kevent(watch_fd, NULL, 0, &event, 1, NULL);
        if (result > 0) {
            return event.filter == EVFILT_PROC
                && (event.flags & EV_ERROR) == 0
                && (event.fflags & NOTE_EXIT) != 0
                ? 0
                : 1;
        }
        if (result < 0 && errno == EINTR) {
            continue;
        }
        return 1;
    }
}

typedef struct {
    const char *name;
    const char *absolute_path;
} LegacyHelperPath;

static const LegacyHelperPath legacy_helper_paths[] = {
    {
        "io.github.girginomer10.ThermoFan.helper",
        "/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper"
    },
    {
        "io.github.girginomer10.ThermoFan.helper.version",
        "/Library/PrivilegedHelperTools/io.github.girginomer10.ThermoFan.helper.version"
    },
    {
        "local.codex.ThermoFan.helper",
        "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper"
    },
    {
        "local.codex.ThermoFan.helper.version",
        "/Library/PrivilegedHelperTools/local.codex.ThermoFan.helper.version"
    }
};

#define LEGACY_HELPER_COUNT \
    (sizeof(legacy_helper_paths) / sizeof(legacy_helper_paths[0]))
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

static int legacy_helper_attributes_are_safe(const struct stat *attributes) {
    return attributes != NULL
        && S_ISREG(attributes->st_mode)
        && attributes->st_uid == 0
        && attributes->st_nlink == 1
        && (attributes->st_mode & 0022) == 0;
}

static int attributes_identify_same_inode(
    const struct stat *left,
    const struct stat *right
) {
    return left != NULL
        && right != NULL
        && left->st_dev == right->st_dev
        && left->st_ino == right->st_ino;
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

static int snapshot_exact_legacy_processes(LegacyProcessSet *processes) {
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
        char executable_path[PROC_PIDPATHINFO_MAXSIZE];
        memset(executable_path, 0, sizeof(executable_path));
        int path_length = proc_pidpath(
            process_id,
            executable_path,
            (uint32_t)sizeof(executable_path)
        );
        if (path_length <= 0) {
            continue;
        }
        executable_path[sizeof(executable_path) - 1] = '\0';
        if (!exact_legacy_executable_path(executable_path)) {
            continue;
        }

        ProcessIdentity identity;
        if (thermofan_engine_read_process_identity(process_id, &identity) != 0) {
            // An exit between proc_pidpath and proc_pidinfo is harmless. Any
            // still-running exact-path process must remain identifiable.
            memset(executable_path, 0, sizeof(executable_path));
            if (proc_pidpath(
                    process_id,
                    executable_path,
                    (uint32_t)sizeof(executable_path)
                ) > 0
                && exact_legacy_executable_path(executable_path)) {
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
        if (snapshot_exact_legacy_processes(processes) != 0) {
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
            || fsync(file_descriptor) != 0) {
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
    if (removed_any && fsync(directory_fd) != 0) {
        return 1;
    }
    return 0;
}

int thermofan_engine_remove_legacy_helpers(void) {
    if (!engine_is_privileged()) {
        return 1;
    }
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

    const char *directory_path = "/Library/PrivilegedHelperTools";
    LegacyHelperInode inodes[LEGACY_HELPER_COUNT];
    for (size_t index = 0; index < LEGACY_HELPER_COUNT; index++) {
        memset(&inodes[index], 0, sizeof(inodes[index]));
        inodes[index].file_descriptor = -1;
    }
    LegacyProcessSet legacy_processes = {0};
    int directory_fd = open(
        directory_path,
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
        if (open_and_verify_legacy_helpers(directory_fd, inodes) != 0
            || revoke_legacy_helper_execution(inodes) != 0
            || snapshot_exact_legacy_processes(&legacy_processes) != 0
            || unlink_revoked_legacy_helpers(directory_fd, inodes) != 0) {
            close_legacy_helper_inodes(inodes);
            close(directory_fd);
            free(legacy_processes.items);
            return 1;
        }
        close_legacy_helper_inodes(inodes);
        close(directory_fd);
    }

    // Scan once more after path retirement. This also covers a previous
    // fail-closed attempt that already removed the directory entry while an
    // exact legacy process was still exiting.
    int status = snapshot_exact_legacy_processes(&legacy_processes);
    if (status == 0) {
        status = drain_exact_legacy_processes(&legacy_processes);
    }
    free(legacy_processes.items);
    if (status != 0) {
        return 1;
    }
    if (recover_recorded_state(NULL, 0) != 0) {
        fprintf(stderr, "Final automatic recovery after legacy retirement failed.\n");
        return 1;
    }
    atomic_store_explicit(&startup_recovery_succeeded, 1, memory_order_release);
    atomic_store_explicit(&manual_writes_ready, 1, memory_order_release);
    return 0;
}
