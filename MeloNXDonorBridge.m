//
//  MeloNXDonorBridge.m
//
//  Lets MeloNX 2.7's RAM donors work while MeloNX runs as a LiveContainer guest.
//
//  A guest app is never installed, so iOS doesn't know about the MeloNXRamDonor extension inside
//  it. LiveContainer's own LiveProcess extension has the same shape, and can run custom code, so:
//
//    Guest side:  requests for the donor extension are redirected to LiveProcess, along with the
//                 path and entry point of this dylib.
//    Donor side:  LiveProcess dlopens this dylib and calls MLXDonorPayloadMain, which answers the
//                 same XPC protocol as MeloNX's MeloNXRamDonor/main.m.
//
//  The donor logic and protocol come from MeloNX (https://starforgejo.dev/projects/MeloNX), which
//  is GPLv3, so this file is GPLv3 too.
//

#import <Foundation/Foundation.h>
#import <TargetConditionals.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <mach-o/dyld.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>

#if TARGET_OS_IOS
#import <os/proc.h>
#endif

// Must match MLXRamDonorProtocol.h in MeloNX.
#define MLXDonorKeyOp        "op"
#define MLXDonorKeySize      "size"
#define MLXDonorKeyShmem     "shmem"
#define MLXDonorKeyError     "error"
#define MLXDonorKeyAvailable "available"
#define MLXDonorKeyPhysMem   "phys_footprint"

#define MLXDonorOpCreate     "create"
#define MLXDonorOpRelease    "release"
#define MLXDonorOpAvailable  "available"
#define MLXDonorOpPhysMem    "phys_footprint"

// Returned when LiveContainer has removed the guest's PlugIns folder, so MeloNX finds no donor.
static NSString *const MLXSyntheticDonorIdentifier = @"com.melonx.livecontainer.RamDonor";
static NSString *const MLXPayloadEntry = @"MLXDonorPayloadMain";

extern kern_return_t mach_vm_allocate(vm_map_t target, mach_vm_address_t *address,
                                      mach_vm_size_t size, int flags);
extern kern_return_t mach_vm_deallocate(vm_map_t target, mach_vm_address_t address,
                                        mach_vm_size_t size);

@interface NSExtension : NSObject
+ (instancetype)extensionWithIdentifier:(NSString *)identifier error:(NSError **)error;
- (void)beginExtensionRequestWithInputItems:(NSArray *)items completion:(void (^)(NSUUID *))callback;
@end

@interface NSXPCListenerEndpoint (MLXBridgePrivate)
@property (nonatomic, setter=_setEndpoint:) xpc_object_t _endpoint;
@end

static NSString *MLXSelfPath(void)
{
    static NSString *path;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        Dl_info info;

        if (dladdr((const void *)&MLXSelfPath, &info) && info.dli_fname)
        {
            path = @(info.dli_fname);
        }
    });

    return path;
}

// Goes to the system log, and to the guest's Documents folder so it can be shared from Files.
static void MLXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);
static void MLXLog(NSString *format, ...)
{
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

    NSLog(@"[MeloNXDonorBridge] %@", message);

#ifndef MLX_BRIDGE_TEST
    static dispatch_queue_t queue;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        queue = dispatch_queue_create("MeloNXDonorBridge.log", DISPATCH_QUEUE_SERIAL);
    });

    NSString *home = NSHomeDirectory();
    NSString *stamp = [NSDate.date description];

    dispatch_async(queue, ^{
        NSString *path = [home stringByAppendingPathComponent:@"Documents/MeloNXDonorBridge.log"];
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", stamp, message];
        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:path];

        if (!file)
        {
            [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil];
            return;
        }

        [file seekToEndOfFile];
        [file writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [file closeFile];
    });
#endif
}

#pragma mark - Donor side, running inside LiveProcess

static NSMutableArray<NSValue *> *gRegions;

static xpc_object_t MLXCreateRegion(uint64_t size, NSString **error)
{
    if (size == 0)
    {
        *error = @"Refusing to create a zero sized region";
        return nil;
    }

    mach_vm_address_t address = 0;
    kern_return_t kr = mach_vm_allocate(mach_task_self(), &address, size,
                                        VM_FLAGS_ANYWHERE | VM_FLAGS_PURGABLE);

    if (kr != KERN_SUCCESS)
    {
        *error = [NSString stringWithFormat:@"mach_vm_allocate failed: %s", mach_error_string(kr)];
        return nil;
    }

    xpc_object_t shmem = xpc_shmem_create((void *)address, (size_t)size);

    if (!shmem)
    {
        mach_vm_deallocate(mach_task_self(), address, size);
        *error = @"xpc_shmem_create returned NULL";
        return nil;
    }

    @synchronized (MLXSelfPath())
    {
        gRegions = gRegions ?: [NSMutableArray array];
        [gRegions addObject:[NSValue valueWithPointer:(void *)(uintptr_t)address]];
        [gRegions addObject:[NSValue valueWithPointer:(void *)(uintptr_t)size]];
    }

    return shmem;
}

static void MLXReleaseRegions(void)
{
    @synchronized (MLXSelfPath())
    {
        for (NSUInteger i = 0; i + 1 < gRegions.count; i += 2)
        {
            mach_vm_deallocate(mach_task_self(),
                               (mach_vm_address_t)(uintptr_t)gRegions[i].pointerValue,
                               (mach_vm_size_t)(uintptr_t)gRegions[i + 1].pointerValue);
        }

        [gRegions removeAllObjects];
    }
}

static uint64_t MLXAvailableMemory(void)
{
#if TARGET_OS_IOS
    return (uint64_t)os_proc_available_memory();
#else
    // os_proc_available_memory doesn't exist on macOS. Only the test harness gets here.
    const char *budget = getenv("MLX_TEST_DONOR_BUDGET");
    return budget ? strtoull(budget, NULL, 10) : 0;
#endif
}

static uint64_t MLXFootprint(void)
{
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;

    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
    {
        return 0;
    }

    return (uint64_t)info.phys_footprint;
}

static void MLXHandleMessage(xpc_connection_t channel, xpc_object_t message)
{
    if (xpc_get_type(message) != XPC_TYPE_DICTIONARY)
    {
        return;
    }

    const char *op = xpc_dictionary_get_string(message, MLXDonorKeyOp);

    if (!op)
    {
        return;
    }

    xpc_object_t reply = xpc_dictionary_create_reply(message);

    if (!reply)
    {
        return;
    }

    if (strcmp(op, MLXDonorOpCreate) == 0)
    {
        NSString *error = nil;
        xpc_object_t shmem = MLXCreateRegion(xpc_dictionary_get_uint64(message, MLXDonorKeySize), &error);

        if (shmem)
        {
            xpc_dictionary_set_value(reply, MLXDonorKeyShmem, shmem);
        }
        else
        {
            xpc_dictionary_set_string(reply, MLXDonorKeyError, error.UTF8String);
            NSLog(@"[MeloNXDonorBridge] Could not create a region: %@", error);
        }
    }
    else if (strcmp(op, MLXDonorOpRelease) == 0)
    {
        MLXReleaseRegions();
    }
    else if (strcmp(op, MLXDonorOpAvailable) == 0)
    {
        xpc_dictionary_set_uint64(reply, MLXDonorKeyAvailable, MLXAvailableMemory());
    }
    else if (strcmp(op, MLXDonorOpPhysMem) == 0)
    {
        xpc_dictionary_set_uint64(reply, MLXDonorKeyPhysMem, MLXFootprint());
    }
    else
    {
        xpc_dictionary_set_string(reply, MLXDonorKeyError, "Unknown operation");
    }

    xpc_connection_send_message(channel, reply);
}

static NSDictionary *MLXRetrievedAppInfo(void)
{
    Class handler = NSClassFromString(@"LiveProcessHandler");
    SEL selector = NSSelectorFromString(@"retrievedAppInfo");

    if (![handler respondsToSelector:selector])
    {
        return nil;
    }

    return ((NSDictionary *(*)(id, SEL))objc_msgSend)(handler, selector);
}

// Called by LiveProcess's main.m through customPayloadEntry. Never returns: a returned value would
// become the process's exit code, and the donor has to outlive this call.
__attribute__((visibility("default")))
int MLXDonorPayloadMain(int argc, char *argv[], char *envp[], char *apple[])
{
    id wrapper = MLXRetrievedAppInfo()[@"endpoint"];

    if (![wrapper isKindOfClass:NSXPCListenerEndpoint.class])
    {
        NSLog(@"[MeloNXDonorBridge] Donor started without a usable endpoint: %@", [wrapper class]);
        return 1;
    }

    xpc_object_t inner = ((NSXPCListenerEndpoint *)wrapper)._endpoint;

    if (!inner || xpc_get_type(inner) != XPC_TYPE_ENDPOINT)
    {
        NSLog(@"[MeloNXDonorBridge] Donor endpoint wrapper was empty");
        return 1;
    }

    xpc_connection_t channel = xpc_connection_create_from_endpoint((xpc_endpoint_t)inner);

    xpc_connection_set_event_handler(channel, ^(xpc_object_t event) {
        if (xpc_get_type(event) == XPC_TYPE_ERROR)
        {
            NSLog(@"[MeloNXDonorBridge] Channel closed, exiting: %s",
                  xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION));
            exit(0);
        }

        MLXHandleMessage(channel, event);
    });

    xpc_connection_resume(channel);

    // XPC connections are lazy, so the host only sees this one once a message is sent on it.
    xpc_object_t hello = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(hello, MLXDonorKeyOp, "hello");
    xpc_connection_send_message(channel, hello);

    NSLog(@"[MeloNXDonorBridge] Donor ready, pid %d", getpid());

    // LiveProcess stopped NSExtensionMain's run loop to reach us, so keep one going here.
    NSRunLoop *loop = NSRunLoop.currentRunLoop;
    [loop addPort:NSMachPort.port forMode:NSDefaultRunLoopMode];

    for (;;)
    {
        @autoreleasepool
        {
            [loop run];
        }

        sleep(1);
    }
}

#pragma mark - Guest side, running inside the MeloNX process

static NSString *MLXLiveProcessIdentifier(void)
{
    static NSString *identifier;
    static dispatch_once_t once;

    dispatch_once(&once, ^{
        // NSBundle.mainBundle is the guest here, so find LiveContainer relative to this dylib, at
        // LiveContainer.app/Frameworks/. Sideloading rewrites this plist with the real identifier.
        NSString *frameworks = MLXSelfPath().stringByDeletingLastPathComponent;
        NSString *plist = [frameworks stringByAppendingPathComponent:
                           @"../PlugIns/LiveProcess.appex/Info.plist"];

        identifier = [NSDictionary dictionaryWithContentsOfFile:plist][@"CFBundleIdentifier"];
    });

    return identifier;
}

static BOOL MLXIsDonorIdentifier(NSString *identifier)
{
    return [identifier rangeOfString:@"RamDonor" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static const void *MLXRedirectedKey = &MLXRedirectedKey;

static id (*orig_extensionWithIdentifier)(id, SEL, NSString *, NSError **);
static void (*orig_beginExtensionRequest)(id, SEL, NSArray *, id);
static NSString *(*orig_donorBundleIdentifier)(id, SEL);

static id hook_extensionWithIdentifier(id self, SEL _cmd, NSString *identifier, NSError **error)
{
    if (!MLXIsDonorIdentifier(identifier))
    {
        return orig_extensionWithIdentifier(self, _cmd, identifier, error);
    }

    NSString *liveProcess = MLXLiveProcessIdentifier();

    if (!liveProcess)
    {
        MLXLog(@"Could not read LiveProcess's bundle identifier, so donors can't start");
        return orig_extensionWithIdentifier(self, _cmd, identifier, error);
    }

    NSError *localError = nil;
    id extension = orig_extensionWithIdentifier(self, _cmd, liveProcess, &localError);

    MLXLog(@"Redirected donor %@ to %@: %@", identifier, liveProcess,
           extension ? @"ok" : localError.localizedDescription);

    if (error)
    {
        *error = localError;
    }

    if (extension)
    {
        objc_setAssociatedObject(extension, MLXRedirectedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    return extension;
}

static void hook_beginExtensionRequest(id self, SEL _cmd, NSArray *items, id completion)
{
    if (objc_getAssociatedObject(self, MLXRedirectedKey))
    {
        // LiveProcess's main.m reads these from the first item's userInfo.
        NSExtensionItem *item = items.firstObject;
        NSMutableDictionary *info = [item.userInfo mutableCopy] ?: [NSMutableDictionary dictionary];

        info[@"customPayloadDylib"] = MLXSelfPath();
        info[@"customPayloadEntry"] = MLXPayloadEntry;
        item.userInfo = info;

        MLXLog(@"Starting donor payload from %@", MLXSelfPath());
    }

    orig_beginExtensionRequest(self, _cmd, items, completion);
}

static NSString *hook_donorBundleIdentifier(id self, SEL _cmd)
{
    NSString *identifier = orig_donorBundleIdentifier(self, _cmd);

    return identifier ?: MLXSyntheticDonorIdentifier;
}

static dispatch_queue_t gWatchQueue;
static volatile bool gDonorClassHandled;

static void MLXCheckForDonorClass(void)
{
    if (gDonorClassHandled)
    {
        return;
    }

    Class donor = objc_getClass("MLXRamDonor");

    if (!donor)
    {
        return;
    }

    gDonorClassHandled = true;

    Method method = class_getClassMethod(donor, NSSelectorFromString(@"donorBundleIdentifier"));

    if (method)
    {
        orig_donorBundleIdentifier =
            (NSString *(*)(id, SEL))method_setImplementation(method, (IMP)hook_donorBundleIdentifier);
        MLXLog(@"Found MeloNX's RAM donor manager");
    }
    else
    {
        MLXLog(@"MLXRamDonor has no donorBundleIdentifier, is this MeloNX 2.7?");
    }
}

// This dylib loads with LiveContainer, before any guest. Hooking inside a dyld callback isn't safe,
// so check from a queue, and check again shortly after in case the class wasn't registered yet.
static void MLXImageAdded(const struct mach_header *header, intptr_t slide)
{
    if (gDonorClassHandled)
    {
        return;
    }

    dispatch_async(gWatchQueue, ^{
        MLXCheckForDonorClass();
    });

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), gWatchQueue, ^{
        MLXCheckForDonorClass();
    });
}

static void MLXWatchForDonorClass(void)
{
    gWatchQueue = dispatch_queue_create("MeloNXDonorBridge.watch", DISPATCH_QUEUE_SERIAL);
    _dyld_register_func_for_add_image(MLXImageAdded);
}

__attribute__((constructor))
static void MLXBridgeInit(void)
{
    // Cache this now: LiveContainer can hide its own images from a guest later on.
    MLXSelfPath();

    // This also runs in LiveProcess, including donors, where the hooks are never used.

    Class extension = NSClassFromString(@"NSExtension");
    Method factory = class_getClassMethod(extension, @selector(extensionWithIdentifier:error:));
    Method begin = class_getInstanceMethod(extension, @selector(beginExtensionRequestWithInputItems:completion:));

    if (!factory || !begin)
    {
        NSLog(@"[MeloNXDonorBridge] NSExtension is missing the expected methods, not hooking");
        return;
    }

    orig_extensionWithIdentifier =
        (id (*)(id, SEL, NSString *, NSError **))method_setImplementation(factory, (IMP)hook_extensionWithIdentifier);
    orig_beginExtensionRequest =
        (void (*)(id, SEL, NSArray *, id))method_setImplementation(begin, (IMP)hook_beginExtensionRequest);

    MLXWatchForDonorClass();
}

#ifdef MLX_BRIDGE_TEST
// Lets the test harness look at a donor's side of the shared memory.
__attribute__((visibility("default")))
void *MLXBridgeTestFirstRegion(void)
{
    @synchronized (MLXSelfPath())
    {
        return gRegions.count ? gRegions[0].pointerValue : NULL;
    }
}
#endif
