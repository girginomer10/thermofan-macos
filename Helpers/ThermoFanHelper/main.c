#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <errno.h>
#include <math.h>
#include <mach/mach_error.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/event.h>
#include <unistd.h>

#define SMC_KERNEL_INDEX 2
#define SMC_READ_BYTES 5
#define SMC_WRITE_BYTES 6
#define SMC_READ_KEY_INFO 9
#define HELPER_VERSION "5"

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

static int read_info(io_connect_t connection, const char *key, SMCKeyInfo *info) {
    SMCKeyData input;
    SMCKeyData output;
    memset(&input, 0, sizeof(input));
    memset(&output, 0, sizeof(output));
    input.key = key_code(key);
    input.data8 = SMC_READ_KEY_INFO;

    kern_return_t result = smc_call(connection, &input, &output);
    if (result != KERN_SUCCESS) {
        fprintf(stderr, "SMC info call failed for %s: %s.\n", key, mach_error_string(result));
        return 1;
    }
    if (check_smc_result(&output) != 0) {
        return 1;
    }

    *info = output.keyInfo;
    return 0;
}

static int read_raw(io_connect_t connection, const char *key, SMCKeyInfo *info, uint8_t bytes[32]) {
    if (read_info(connection, key, info) != 0) {
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
        fprintf(stderr, "SMC read failed for %s: %s.\n", key, mach_error_string(result));
        return 1;
    }
    if (check_smc_result(&output) != 0) {
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

static int read_number(io_connect_t connection, const char *key, double *value) {
    SMCKeyInfo info;
    uint8_t bytes[32];
    if (read_raw(connection, key, &info, bytes) != 0) {
        return 1;
    }
    *value = decode_number(&info, bytes);
    return isfinite(*value) ? 0 : 1;
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

static int write_number(io_connect_t connection, const char *key, double value) {
    SMCKeyInfo info;
    if (read_info(connection, key, &info) != 0) {
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
        fprintf(stderr, "SMC write failed for %s: %s.\n", key, mach_error_string(result));
        return 1;
    }
    return check_smc_result(&output);
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

static int set_manual_state(io_connect_t connection, int fan_index, const char *mode_key, int supports_per_fan_mode, int enabled) {
    if (supports_per_fan_mode) {
        return write_number(connection, mode_key, enabled ? 1 : 0);
    }

    double mask_value = 0;
    if (read_number(connection, "FS!", &mask_value) != 0) {
        return 1;
    }
    int mask = (int)mask_value;
    if (enabled) {
        mask |= (1 << fan_index);
    } else {
        mask &= ~(1 << fan_index);
    }
    return write_number(connection, "FS!", mask);
}

static int manual_state_matches(io_connect_t connection, int fan_index, const char *mode_key, int supports_per_fan_mode, int expected) {
    double value = 0;
    if (supports_per_fan_mode) {
        if (read_number(connection, mode_key, &value) != 0) {
            return 0;
        }
        return (value >= 0.5) == expected;
    }

    if (read_number(connection, "FS!", &value) != 0) {
        return 0;
    }
    return ((((int)value) & (1 << fan_index)) != 0) == expected;
}

static int wait_for_manual_state(io_connect_t connection, int fan_index, const char *mode_key, int supports_per_fan_mode, int expected) {
    for (int attempt = 0; attempt < 10; attempt++) {
        if (manual_state_matches(connection, fan_index, mode_key, supports_per_fan_mode, expected)) {
            return 0;
        }
        usleep(50000);
    }
    return 1;
}

static int apply_fan(int fan_index, const char *mode, int rpm) {
    io_connect_t connection = IO_OBJECT_NULL;
    if (open_smc(&connection) != 0) {
        return 1;
    }

    int status = 1;
    double fan_count = 0;
    if (read_number(connection, "FNum", &fan_count) != 0 || fan_index < 0 || fan_index >= (int)fan_count) {
        fprintf(stderr, "Fan %d does not exist; SMC reports %.0f fan(s).\n", fan_index + 1, fan_count);
        goto done;
    }

    char prefix[3];
    snprintf(prefix, sizeof(prefix), "F%d", fan_index);
    char min_key[5], max_key[5], target_key[5], mode_key[5];
    snprintf(min_key, sizeof(min_key), "%sMn", prefix);
    snprintf(max_key, sizeof(max_key), "%sMx", prefix);
    snprintf(target_key, sizeof(target_key), "%sTg", prefix);
    snprintf(mode_key, sizeof(mode_key), "%sMd", prefix);

    double min_rpm = 0;
    double max_rpm = 0;
    if (read_number(connection, min_key, &min_rpm) != 0 || read_number(connection, max_key, &max_rpm) != 0 || max_rpm <= min_rpm || max_rpm < 1000) {
        fprintf(stderr, "Fan %d RPM range could not be read safely from SMC.\n", fan_index + 1);
        goto done;
    }

    int supports_per_fan_mode = 0;
    double ignored_mode = 0;
    if (read_number(connection, mode_key, &ignored_mode) == 0) {
        supports_per_fan_mode = 1;
    }

    if (strcmp(mode, "automatic") == 0 || strcmp(mode, "auto") == 0) {
        if (set_manual_state(connection, fan_index, mode_key, supports_per_fan_mode, 0) != 0) {
            goto done;
        }
        if (wait_for_manual_state(connection, fan_index, mode_key, supports_per_fan_mode, 0) != 0) {
            fprintf(stderr, "Fan %d did not return to automatic mode after the SMC write.\n", fan_index + 1);
            goto done;
        }
        printf("Fan %d returned to automatic hardware control.\n", fan_index + 1);
        status = 0;
        goto done;
    }

    if (rpm < (int)min_rpm) rpm = (int)min_rpm;
    if (rpm > (int)max_rpm) rpm = (int)max_rpm;

    // Apple Silicon can overwrite F*Tg while the fan is still in automatic
    // mode. Enter manual mode first, then write and verify the target.
    if (set_manual_state(connection, fan_index, mode_key, supports_per_fan_mode, 1) != 0) {
        goto done;
    }
    if (wait_for_manual_state(connection, fan_index, mode_key, supports_per_fan_mode, 1) != 0) {
        // Some Apple Silicon SMC revisions acknowledge the first mode write
        // asynchronously. Retry it once before giving up.
        if (set_manual_state(connection, fan_index, mode_key, supports_per_fan_mode, 1) != 0
            || wait_for_manual_state(connection, fan_index, mode_key, supports_per_fan_mode, 1) != 0) {
            fprintf(stderr, "Fan %d did not enter manual mode. Returning to automatic mode.\n", fan_index + 1);
            (void)set_manual_state(connection, fan_index, mode_key, supports_per_fan_mode, 0);
            goto done;
        }
    }
    if (write_number(connection, target_key, rpm) != 0) {
        (void)set_manual_state(connection, fan_index, mode_key, supports_per_fan_mode, 0);
        goto done;
    }

    double applied_rpm = 0;
    int target_verified = 0;
    for (int attempt = 0; attempt < 6; attempt++) {
        usleep(50000);
        if (read_number(connection, target_key, &applied_rpm) == 0 && fabs(applied_rpm - rpm) <= 25) {
            target_verified = 1;
            break;
        }
        if (attempt == 2 && write_number(connection, target_key, rpm) != 0) {
            break;
        }
    }
    if (!target_verified
        || wait_for_manual_state(connection, fan_index, mode_key, supports_per_fan_mode, 1) != 0) {
        fprintf(stderr, "Fan %d target verification failed; requested %d RPM, SMC reports %.0f RPM. Returning to automatic mode.\n", fan_index + 1, rpm, applied_rpm);
        (void)set_manual_state(connection, fan_index, mode_key, supports_per_fan_mode, 0);
        (void)wait_for_manual_state(connection, fan_index, mode_key, supports_per_fan_mode, 0);
        goto done;
    }

    printf("Fan %d target verified on hardware: %.0f RPM.\n", fan_index + 1, applied_rpm);
    status = 0;

done:
    if (connection != IO_OBJECT_NULL) {
        IOServiceClose(connection);
    }
    return status;
}

static int parse_int(const char *value, int *out) {
    char *end = NULL;
    errno = 0;
    long parsed = strtol(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed < 0 || parsed > 100000) {
        return 1;
    }
    *out = (int)parsed;
    return 0;
}

static int become_root(void) {
    if (geteuid() != 0) {
        fprintf(stderr, "ThermoFanHelper must be installed before it can control hardware.\n");
        return 1;
    }
    if (setgid(0) != 0 || setuid(0) != 0) {
        fprintf(stderr, "Could not activate helper privileges: %s.\n", strerror(errno));
        return 1;
    }
    return 0;
}

static void wait_for_process_exit(pid_t pid) {
    int queue = kqueue();
    if (queue >= 0) {
        struct kevent change;
        struct kevent event;
        EV_SET(&change, (uintptr_t)pid, EVFILT_PROC, EV_ADD | EV_ENABLE | EV_ONESHOT, NOTE_EXIT, 0, NULL);
        if (kevent(queue, &change, 1, NULL, 0, NULL) == 0) {
            while (kevent(queue, NULL, 0, &event, 1, NULL) < 0 && errno == EINTR) {
            }
            close(queue);
            return;
        }
        close(queue);
    }

    while (kill(pid, 0) == 0 || errno == EPERM) {
        sleep(2);
    }
}

int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        printf("%s\n", HELPER_VERSION);
        return 0;
    }

    if (argc == 4 && strcmp(argv[1], "--watch") == 0) {
        int parent_pid = 0;
        int fan_index = 0;
        if (parse_int(argv[2], &parent_pid) != 0 || parent_pid <= 1 || parent_pid != getppid()) {
            fprintf(stderr, "The watchdog may only monitor its launching application.\n");
            return 64;
        }
        if (parse_int(argv[3], &fan_index) != 0 || fan_index > 7) {
            fprintf(stderr, "Invalid fan index.\n");
            return 64;
        }
        if (become_root() != 0) {
            return 1;
        }
        wait_for_process_exit((pid_t)parent_pid);
        return apply_fan(fan_index, "automatic", 0);
    }

    if (argc < 4 || strcmp(argv[1], "--fanctl") != 0) {
        fprintf(stderr, "Usage: ThermoFanHelper --fanctl <fan-index> <automatic|fixed|curve> [rpm]\n");
        return 64;
    }

    int fan_index = 0;
    if (parse_int(argv[2], &fan_index) != 0 || fan_index > 7) {
        fprintf(stderr, "Invalid fan index.\n");
        return 64;
    }

    const char *mode = argv[3];
    if (strcmp(mode, "automatic") != 0 && strcmp(mode, "auto") != 0 && strcmp(mode, "fixed") != 0 && strcmp(mode, "curve") != 0) {
        fprintf(stderr, "Invalid fan mode.\n");
        return 64;
    }
    int rpm = 0;
    if (strcmp(mode, "automatic") != 0 && strcmp(mode, "auto") != 0) {
        if (argc != 5 || parse_int(argv[4], &rpm) != 0) {
            fprintf(stderr, "RPM is required for fixed or curve mode.\n");
            return 64;
        }
    } else if (argc != 4) {
        fprintf(stderr, "Automatic mode does not accept an RPM.\n");
        return 64;
    }

    if (become_root() != 0) {
        return 1;
    }

    return apply_fan(fan_index, mode, rpm);
}
