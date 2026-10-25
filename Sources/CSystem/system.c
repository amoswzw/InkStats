#include "CSystem.h"

#include <string.h>
#include <mach/mach.h>
#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

#define FCC(a, b, c, d) (((UInt32)(a) << 24) | ((UInt32)(b) << 16) | ((UInt32)(c) << 8) | (UInt32)(d))

// MARK: - SMC

typedef struct { char major, minor, build, reserved; UInt16 release; } SMCVersion;
typedef struct { UInt16 version, length; UInt32 cpuLimit, gpuLimit, memLimit; } SMCPowerLimit;
typedef struct { UInt32 size, type; char attributes; } SMCKeyInfo;
typedef struct {
    UInt32 key;
    SMCVersion version;
    SMCPowerLimit limit;
    SMCKeyInfo info;
    char result, status, command;
    UInt32 data32;
    unsigned char bytes[32];
} SMCMessage;

// The kernel side expects exactly this layout.
_Static_assert(sizeof(SMCMessage) == 80, "unexpected SMC message size");

enum { kSMCHandleYPCEvent = 2, kSMCReadKey = 5, kSMCWriteKey = 6, kSMCGetKeyInfo = 9 };

static io_connect_t smc;

static bool smc_open(void) {
    if (smc) return true;
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
    if (!service) return false;
    kern_return_t kr = IOServiceOpen(service, mach_task_self(), 0, &smc);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS) {
        smc = 0;
        return false;
    }
    return true;
}

static bool smc_call(SMCMessage *in, SMCMessage *out) {
    size_t size = sizeof(SMCMessage);
    memset(out, 0, sizeof(SMCMessage));
    kern_return_t kr = IOConnectCallStructMethod(smc, kSMCHandleYPCEvent, in, sizeof(SMCMessage), out, &size);
    return kr == KERN_SUCCESS && out->result == 0;
}

bool is_smc_read(const char *key, double *value) {
    if (!key || strlen(key) != 4 || !smc_open()) return false;

    SMCMessage in = {0}, out;
    in.key = FCC(key[0], key[1], key[2], key[3]);
    in.command = kSMCGetKeyInfo;
    if (!smc_call(&in, &out)) return false;

    SMCKeyInfo info = out.info;
    in.info = info;
    in.command = kSMCReadKey;
    if (!smc_call(&in, &out)) return false;

    const unsigned char *b = out.bytes;
    switch (info.type) {
    case FCC('f', 'l', 't', ' '): {
        float f;
        memcpy(&f, b, sizeof f);
        *value = f;
        return true;
    }
    case FCC('u', 'i', '8', ' '):
        *value = b[0];
        return true;
    case FCC('u', 'i', '1', '6'):
        *value = (b[0] << 8) | b[1];
        return true;
    case FCC('u', 'i', '3', '2'):
        *value = ((UInt32)b[0] << 24) | ((UInt32)b[1] << 16) | ((UInt32)b[2] << 8) | b[3];
        return true;
    case FCC('s', 'p', '7', '8'):
        *value = (int16_t)((b[0] << 8) | b[1]) / 256.0;
        return true;
    case FCC('f', 'p', 'e', '2'):
        *value = ((b[0] << 8) | b[1]) / 4.0;
        return true;
    default:
        return false;
    }
}

static bool smc_info(const char *key, SMCKeyInfo *info) {
    if (!key || strlen(key) != 4 || !smc_open()) return false;
    SMCMessage in = {0}, out;
    in.key = FCC(key[0], key[1], key[2], key[3]);
    in.command = kSMCGetKeyInfo;
    if (!smc_call(&in, &out)) return false;
    *info = out.info;
    return true;
}

bool is_smc_key_info(const char *key, char type[5], int *size) {
    SMCKeyInfo info;
    if (!smc_info(key, &info)) return false;
    type[0] = (char)(info.type >> 24);
    type[1] = (char)(info.type >> 16);
    type[2] = (char)(info.type >> 8);
    type[3] = (char)info.type;
    type[4] = 0;
    *size = (int)info.size;
    return true;
}

bool is_smc_write(const char *key, const unsigned char *bytes, int size) {
    SMCKeyInfo info;
    if (!smc_info(key, &info) || size != (int)info.size || size > 32) return false;
    SMCMessage in = {0}, out;
    in.key = FCC(key[0], key[1], key[2], key[3]);
    in.command = kSMCWriteKey;
    in.info = info;
    memcpy(in.bytes, bytes, size);
    return smc_call(&in, &out);
}

// MARK: - HID temperature sensors (not in the public SDK headers)

typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef struct __IOHIDServiceClient *IOHIDServiceClientRef;
typedef struct __IOHIDEvent *IOHIDEventRef;

extern IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(IOHIDEventSystemClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(IOHIDEventSystemClientRef client);
extern CFTypeRef IOHIDServiceClientCopyProperty(IOHIDServiceClientRef service, CFStringRef key);
extern IOHIDEventRef IOHIDServiceClientCopyEvent(IOHIDServiceClientRef service, int64_t type, int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(IOHIDEventRef event, int32_t field);

enum { kHIDPageAppleVendor = 0xff00, kHIDUsageTemperatureSensor = 5, kHIDEventTypeTemperature = 15 };

static IOHIDEventSystemClientRef hidClient;
static CFArrayRef hidServices;

static void hid_open(void) {
    if (hidClient) return;
    hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (!hidClient) return;

    int page = kHIDPageAppleVendor, usage = kHIDUsageTemperatureSensor;
    CFNumberRef pageRef = CFNumberCreate(NULL, kCFNumberIntType, &page);
    CFNumberRef usageRef = CFNumberCreate(NULL, kCFNumberIntType, &usage);
    const void *keys[] = {CFSTR("PrimaryUsagePage"), CFSTR("PrimaryUsage")};
    const void *values[] = {pageRef, usageRef};
    CFDictionaryRef matching = CFDictionaryCreate(NULL, keys, values, 2, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    IOHIDEventSystemClientSetMatching(hidClient, matching);
    CFRelease(matching);
    CFRelease(pageRef);
    CFRelease(usageRef);

    hidServices = IOHIDEventSystemClientCopyServices(hidClient);
}

enum { kMaxHIDServices = 512 };
// Some sensors only ever return placeholder values (around -9200 °C). Each read is a
// round trip to the HID server, so those are remembered and skipped.
static bool hidBogus[kMaxHIDServices];

int is_hid_temperatures(ISTemperature *out, int max) {
    hid_open();
    if (!hidServices) return 0;

    int count = 0;
    CFIndex total = CFArrayGetCount(hidServices);
    for (CFIndex i = 0; i < total && count < max; i++) {
        if (i < kMaxHIDServices && hidBogus[i]) continue;
        IOHIDServiceClientRef service = (IOHIDServiceClientRef)CFArrayGetValueAtIndex(hidServices, i);
        IOHIDEventRef event = IOHIDServiceClientCopyEvent(service, kHIDEventTypeTemperature, 0, 0);
        if (!event) continue;

        ISTemperature *t = &out[count];
        t->celsius = IOHIDEventGetFloatValue(event, kHIDEventTypeTemperature << 16);
        if (t->celsius < -200 || t->celsius > 300) {
            if (i < kMaxHIDServices) hidBogus[i] = true;
            CFRelease(event);
            continue;
        }
        t->name[0] = 0;
        CFTypeRef name = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
        if (name) {
            if (CFGetTypeID(name) == CFStringGetTypeID())
                CFStringGetCString((CFStringRef)name, t->name, sizeof t->name, kCFStringEncodingUTF8);
            CFRelease(name);
        }
        CFRelease(event);
        count++;
    }
    return count;
}

// MARK: - IOReport energy counters (libIOReport has no public header)

typedef struct IOReportSubscription *IOReportSubscriptionRef;

extern CFMutableDictionaryRef IOReportCopyChannelsInGroup(CFStringRef group, CFStringRef subgroup, uint64_t a, uint64_t b, uint64_t c);
extern IOReportSubscriptionRef IOReportCreateSubscription(void *allocator, CFMutableDictionaryRef channels, CFMutableDictionaryRef *subscribed, uint64_t channelID, CFTypeRef options);
extern CFDictionaryRef IOReportCreateSamples(IOReportSubscriptionRef subscription, CFMutableDictionaryRef subscribed, CFTypeRef options);
extern CFDictionaryRef IOReportCreateSamplesDelta(CFDictionaryRef previous, CFDictionaryRef current, CFTypeRef options);
extern CFStringRef IOReportChannelGetChannelName(CFDictionaryRef channel);
extern CFStringRef IOReportChannelGetUnitLabel(CFDictionaryRef channel);
extern int64_t IOReportSimpleGetIntegerValue(CFDictionaryRef channel, int32_t index);

static IOReportSubscriptionRef energySubscription;
static CFMutableDictionaryRef energyChannels;
static CFDictionaryRef energyPrevious;

static double joules_per_unit(CFDictionaryRef channel) {
    char unit[16] = "";
    CFStringRef label = IOReportChannelGetUnitLabel(channel);
    if (label) CFStringGetCString(label, unit, sizeof unit, kCFStringEncodingUTF8);
    if (!strcmp(unit, "mJ")) return 1e-3;
    if (!strcmp(unit, "uJ") || !strcmp(unit, "\xC2\xB5J")) return 1e-6;
    if (!strcmp(unit, "nJ")) return 1e-9;
    if (!strcmp(unit, "J")) return 1;
    return 0;
}

bool is_energy_sample(ISEnergy *out) {
    if (!energySubscription) {
        CFMutableDictionaryRef group = IOReportCopyChannelsInGroup(CFSTR("Energy Model"), NULL, 0, 0, 0);
        if (!group) return false;
        energySubscription = IOReportCreateSubscription(NULL, group, &energyChannels, 0, NULL);
        CFRelease(group);
        if (!energySubscription) return false;
    }

    CFDictionaryRef now = IOReportCreateSamples(energySubscription, energyChannels, NULL);
    if (!now) return false;

    bool ok = false;
    if (energyPrevious) {
        CFDictionaryRef delta = IOReportCreateSamplesDelta(energyPrevious, now, NULL);
        if (delta) {
            *out = (ISEnergy){-1, -1, -1, -1};
            CFArrayRef channels = CFDictionaryGetValue(delta, CFSTR("IOReportChannels"));
            CFIndex n = channels ? CFArrayGetCount(channels) : 0;
            for (CFIndex i = 0; i < n; i++) {
                CFDictionaryRef channel = CFArrayGetValueAtIndex(channels, i);
                char name[64] = "";
                CFStringRef nameRef = IOReportChannelGetChannelName(channel);
                if (nameRef) CFStringGetCString(nameRef, name, sizeof name, kCFStringEncodingUTF8);

                double *slot = NULL;
                if (!strcmp(name, "CPU Energy")) slot = &out->cpu;
                else if (!strcmp(name, "GPU Energy")) slot = &out->gpu;
                else if (!strncmp(name, "ANE", 3)) slot = &out->ane;
                else if (!strncmp(name, "DRAM", 4)) slot = &out->dram;
                if (!slot) continue;

                double joules = (double)IOReportSimpleGetIntegerValue(channel, 0) * joules_per_unit(channel);
                *slot = (*slot < 0 ? 0 : *slot) + joules;
            }
            CFRelease(delta);
            ok = true;
        }
        CFRelease(energyPrevious);
    }
    energyPrevious = now;
    return ok;
}

// MARK: - NVMe SMART (public IOKit plug-in; no privileges needed)

int is_nvme_smart(ISSmart *out, int max) {
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IONVMeBlockStorageDevice"), &iterator) != KERN_SUCCESS) return 0;
    int count = 0;
    io_object_t service;
    while ((service = IOIteratorNext(iterator)) && count < max) {
        IOCFPlugInInterface **plugin = NULL;
        SInt32 score;
        if (IOCreatePlugInInterfaceForService(service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score) == KERN_SUCCESS) {
            IONVMeSMARTInterface **smart = NULL;
            (*plugin)->QueryInterface(plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
            NVMeSMARTData data;
            if (smart && (*smart)->SMARTReadData(smart, &data) == kIOReturnSuccess) {
                // Data units are thousands of 512-byte blocks; temperature is in kelvin.
                out[count++] = (ISSmart){
                    .celsius = (double)data.TEMPERATURE - 273.15,
                    .availableSpare = data.AVAILABLE_SPARE,
                    .percentageUsed = data.PERCENTAGE_USED,
                    .criticalWarning = data.CRITICAL_WARNING,
                    .bytesRead = (double)data.DATA_UNITS_READ[0] * 512000.0,
                    .bytesWritten = (double)data.DATA_UNITS_WRITTEN[0] * 512000.0,
                    .powerOnHours = (double)data.POWER_ON_HOURS[0],
                    .powerCycles = (double)data.POWER_CYCLES[0],
                    .unsafeShutdowns = (double)data.UNSAFE_SHUTDOWNS[0],
                    .mediaErrors = (double)data.MEDIA_ERRORS[0],
                };
            }
            if (smart) (*smart)->Release(smart);
            IODestroyPlugInInterface(plugin);
        }
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return count;
}
