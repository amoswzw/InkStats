#pragma once

#include <stdbool.h>

/// One temperature reported by the HID sensor hub.
typedef struct {
    char name[64];
    double celsius;
} ISTemperature;

/// Energy used since the previous call, in joules. A field is negative when the
/// machine does not report that channel.
typedef struct {
    double cpu;
    double gpu;
    double ane;
    double dram;
} ISEnergy;

/// NVMe SMART health of one drive.
typedef struct {
    double celsius;
    int availableSpare;
    int percentageUsed;
    int criticalWarning;
    double bytesRead;
    double bytesWritten;
    double powerOnHours;
    double powerCycles;
    double unsafeShutdowns;
    double mediaErrors;
} ISSmart;

/// Fills `out` with up to `max` drives that support NVMe SMART; returns how many.
int is_nvme_smart(ISSmart *out, int max);

/// Reads a numeric SMC key such as "PSTR" or "F0Ac". Returns false when the key
/// is missing or uses a data type this reader does not understand.
bool is_smc_read(const char *key, double *value);

/// Looks up an SMC key's four-character data type (e.g. "flt ", "ui8 ") and size.
bool is_smc_key_info(const char *key, char type[5], int *size);

/// Writes raw bytes to an SMC key. Needs root. `size` must match the key's size.
bool is_smc_write(const char *key, const unsigned char *bytes, int size);

/// Fills `out` with up to `max` temperature readings and returns how many were written.
int is_hid_temperatures(ISTemperature *out, int max);

/// Samples the IOReport "Energy Model" group. Returns false on the first call
/// (no previous sample to diff against) or when the group is unavailable.
bool is_energy_sample(ISEnergy *out);
