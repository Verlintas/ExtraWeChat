//
//  login_persist.mm
//  ExtraWeChat — experimental login-state persistence for WeChat 4.x.
//
//  Loaded into WeChat via DYLD_INSERT_LIBRARIES (the app is re-signed with
//  com.apple.security.cs.allow-dyld-environment-variables and
//  com.apple.security.cs.disable-library-validation). It hooks
//  owl::v9::ini_file::get/set and persists the ilink2 auto-auth keys.
//
//  It only injects a saved key when WeChat itself returns an empty
//  kTdiKeyAutoauthKey / kTdiKeyAutoauthEncKey, i.e. when the normal path would
//  fall back to manual (phone) login. If the server rejects a saved key, the
//  normal fallback still runs.
//
//  The raw key is stored in the app's sandbox container at
//  Library/Application Support/ExtraWeChat/login_keys.tsv (0600). This is a
//  prototype; the final product should use Keychain.
//

#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
#include <dispatch/dispatch.h>
#include <atomic>
#include <thread>
#include <chrono>
#include <dlfcn.h>
#include <string>
#include <map>
#include <mutex>
#include <fstream>
#include <sstream>
#include <ctime>
#include <cstdlib>
#include <cstring>
#include <sys/stat.h>
#include <unistd.h>
#include "vendor/fishhook.h"

namespace {

constexpr const char *kKeyAuth = "kTdiKeyAutoauthKey";
constexpr const char *kKeyEnc = "kTdiKeyAutoauthEncKey";

std::mutex g_mutex;
std::mutex g_log_mutex;
std::map<std::string, std::string> g_saved;
std::string g_dir;
std::string g_store;
std::string g_log;
std::atomic<bool> g_hooked{false};
bool g_debug = false;

std::string nsstring_to_string(NSString *s) {
    return s ? std::string([s UTF8String]) : std::string();
}

std::string support_dir() {
    @autoreleasepool {
        NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
            NSApplicationSupportDirectory, NSUserDomainMask, YES);
        NSString *base = paths.count ? paths.firstObject
                                     : [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support"];
        NSString *dir = [base stringByAppendingPathComponent:@"ExtraWeChat"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES
                                                   attributes:@{NSFilePosixPermissions: @0700}
                                                        error:nil];
        return nsstring_to_string(dir);
    }
}

void log_line(const std::string &message) {
    if (g_log.empty()) return;
    std::lock_guard<std::mutex> lock(g_log_mutex);
    std::ofstream out(g_log, std::ios::app);
    if (!out) return;
    std::time_t now = std::time(nullptr);
    char buf[64] = {0};
    std::strftime(buf, sizeof(buf), "%Y-%m-%d %H:%M:%S", std::localtime(&now));
    out << buf << " [" << getpid() << "] " << message << "\n";
    chmod(g_log.c_str(), 0600);
}

void load_store() {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_saved.clear();
    std::ifstream in(g_store);
    if (!in) return;
    std::string line;
    while (std::getline(in, line)) {
        if (line.empty()) continue;
        auto tab = line.find('\t');
        if (tab == std::string::npos) continue;
        std::string k = line.substr(0, tab);
        std::string v = line.substr(tab + 1);
        if (!k.empty() && !v.empty()) g_saved[k] = v;
    }
}

void save_store_locked() {
    std::string tmp = g_store + ".tmp";
    {
        std::ofstream out(tmp, std::ios::trunc);
        if (!out) return;
        for (const auto &kv : g_saved) {
            if (!kv.second.empty()) out << kv.first << "\t" << kv.second << "\n";
        }
    }
    chmod(tmp.c_str(), 0600);
    rename(tmp.c_str(), g_store.c_str());
    chmod(g_store.c_str(), 0600);
}

void remember(const std::string &key, const std::string &value) {
    if (value.empty()) return;
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_saved.find(key);
    if (it != g_saved.end() && it->second == value) return;
    g_saved[key] = value;
    save_store_locked();
    log_line("[capture] " + key + " length=" + std::to_string(value.size()));
}

std::string lookup(const std::string &key) {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_saved.find(key);
    return it == g_saved.end() ? std::string() : it->second;
}

typedef std::string (*GetFn)(void *self, const std::string &key, const std::string &def);
typedef void (*SetFn)(void *self, const std::string &key, const std::string &value);

GetFn g_orig_get = nullptr;
SetFn g_orig_set = nullptr;

std::string hook_get(void *self, const std::string &key, const std::string &def) {
    const bool target = (key == kKeyAuth || key == kKeyEnc);
    if (target && g_debug) {
        fprintf(stderr, "[login_persist] hook_get key=%s len=%zu pid=%d\n",
                key.c_str(), key.size(), getpid());
        fflush(stderr);
    }
    if (!g_orig_get) return def;
    std::string result = g_orig_get(self, key, def);
    if (key == kKeyAuth || key == kKeyEnc) {
        if (!result.empty()) {
            remember(key, result);
        } else {
            std::string saved = lookup(key);
            if (!saved.empty()) {
                result = saved;
                log_line("[inject] " + key + " length=" + std::to_string(saved.size()));
            }
        }
    }
    return result;
}

void hook_set(void *self, const std::string &key, const std::string &value) {
    const bool target = (key == kKeyAuth || key == kKeyEnc);
    if (target && g_debug) {
        fprintf(stderr, "[login_persist] hook_set key=%s value_len=%zu pid=%d\n",
                key.c_str(), value.size(), getpid());
        fflush(stderr);
    }
    if (g_orig_set) g_orig_set(self, key, value);
    if (key == kKeyAuth || key == kKeyEnc) {
        if (!value.empty()) remember(key, value);
    }
}

bool ilink_loaded() {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && std::strstr(name, "ilink2.framework")) return true;
    }
    return false;
}

bool install_hooks() {
    if (g_debug) {
        fprintf(stderr, "[login_persist] install_hooks enter pid=%d\n", getpid());
        fflush(stderr);
    }
    if (g_hooked.load()) return true;
    bool loaded = ilink_loaded();
    if (g_debug) {
        fprintf(stderr, "[login_persist] ilink_loaded=%d pid=%d\n", loaded ? 1 : 0, getpid());
        fflush(stderr);
    }
    if (!loaded) {
        return false;
    }
    struct rebinding rebinds[2] = {
        {"_ZN3owl2v98ini_file3getERKNSt3__112basic_stringIcNS2_11char_traitsIcEENS2_9allocatorIcEEEESA_",
         (void *)hook_get, (void **)&g_orig_get},
        {"_ZN3owl2v98ini_file3setERKNSt3__112basic_stringIcNS2_11char_traitsIcEENS2_9allocatorIcEEEESA_",
         (void *)hook_set, (void **)&g_orig_set},
    };
    log_line("[hook] calling rebind_symbols");
    if (g_debug) {
        fprintf(stderr, "[login_persist] rebind_symbols before pid=%d\n", getpid());
        fflush(stderr);
    }
    int rc = rebind_symbols(rebinds, 2);
    if (g_debug) {
        fprintf(stderr, "[login_persist] rebind_symbols after rc=%d get=%p set=%p pid=%d\n",
                rc, (void *)g_orig_get, (void *)g_orig_set, getpid());
        fflush(stderr);
    }
    log_line("[hook] rebind returned rc=" + std::to_string(rc));
    if (rc == 0 && g_orig_get && g_orig_set) {
        g_hooked.store(true);
        log_line("[hook] owl::ini_file::get/set installed");
        return true;
    }
    log_line("[hook] rebind rc=" + std::to_string(rc) +
             " get=" + std::to_string((uintptr_t)g_orig_get) +
             " set=" + std::to_string((uintptr_t)g_orig_set));
    return false;
}

NSString *find_framework_binary(NSString *name) {
    NSBundle *main = [NSBundle mainBundle];
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSString *fw = [main privateFrameworksPath];
    NSString *res = [main resourcePath];
    NSString *frameworkDir = [name stringByAppendingString:@".framework"];
    NSArray<NSString *> *bases = @[fw ?: @"", res ?: @""];
    for (NSString *base in bases) {
        if (base.length == 0) continue;
        NSString *versions = [base stringByAppendingPathComponent:
            [frameworkDir stringByAppendingPathComponent:@"Versions/A"]];
        [candidates addObject:[versions stringByAppendingPathComponent:name]];
        NSString *plain = [base stringByAppendingPathComponent:frameworkDir];
        [candidates addObject:[plain stringByAppendingPathComponent:name]];
    }
    for (NSString *candidate in candidates) {
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) return candidate;
    }
    return nil;
}

NSString *find_owl_path() {
    return find_framework_binary(@"owl");
}

void poll_thread() {
    log_line("[thread] started");
    fprintf(stderr, "[login_persist] poll thread started pid=%d\n", getpid());
    fflush(stderr);
    for (int attempts = 0; attempts < 300 && !g_hooked.load(); attempts++) {
        if (install_hooks()) return;
        if (attempts % 10 == 0) {
            log_line("[poll] attempts=" + std::to_string(attempts) +
                     " images=" + std::to_string(_dyld_image_count()) +
                     " ilink=" + (ilink_loaded() ? "yes" : "no"));
        }
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    if (!g_hooked.load()) log_line("[hook] gave up waiting for ilink2.framework");
}

void image_added(const struct mach_header *mh, intptr_t vmaddr_slide) {
    Dl_info info;
    if (dladdr(mh, &info) && info.dli_fname) {
        if (std::strstr(info.dli_fname, "ilink") ||
            std::strstr(info.dli_fname, "wechat.dylib") ||
            std::strstr(info.dli_fname, "WCDY")) {
            log_line(std::string("[image] ") + info.dli_fname);
        }
        if (std::strstr(info.dli_fname, "owl.framework") ||
            std::strstr(info.dli_fname, "ilink2.framework") ||
            std::strstr(info.dli_fname, "wechat.dylib")) {
            install_hooks();
        }
    }
}

__attribute__((constructor)) static void initialize() {
    @autoreleasepool {
        const char *enabled = getenv("EXTRAWECHAT_LOGIN_PERSIST");
        if (enabled && std::strcmp(enabled, "0") == 0) return; // explicit opt-out
        g_debug = getenv("EXTRAWECHAT_LOGIN_DEBUG") != nullptr;

        g_dir = support_dir();
        g_store = g_dir + "/login_keys.tsv";
        g_log = g_dir + "/login_persist.log";
        chmod(g_dir.c_str(), 0700);
        load_store();
        log_line("[load] keys=" + std::to_string(g_saved.size()) + " dylib loaded");

        NSString *owl = find_owl_path();
        if (owl) {
            void *h = dlopen([owl UTF8String], RTLD_NOW | RTLD_GLOBAL);
            log_line(std::string("[load] dlopen owl ") + (h ? "ok" : dlerror()));
        } else {
            log_line("[load] owl.framework not found in bundle; waiting for dyld");
        }
        NSString *ilink = find_framework_binary(@"ilink2");
        if (ilink) {
            void *h = dlopen([ilink UTF8String], RTLD_LAZY | RTLD_GLOBAL);
            log_line(std::string("[load] dlopen ilink2 ") + (h ? "ok" : dlerror()));
        }
        install_hooks();
        _dyld_register_func_for_add_image(image_added);
        log_line("[thread] creating");
        fprintf(stderr, "[login_persist] creating poll thread pid=%d\n", getpid());
        fflush(stderr);
        std::thread(poll_thread).detach();
        log_line("[thread] create returned");
    }
}

} // namespace
