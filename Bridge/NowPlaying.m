// Now Playing bridge.
//
// Since macOS 15.4 MediaRemote only answers processes signed by Apple, so the app cannot read
// "Now Playing" itself. /usr/bin/perl is an Apple platform binary: MediaService runs perl, perl loads
// this library with DynaLoader and calls np_main(). Modes (env NP_MODE):
//   watch  print one JSON line per second: title, artist, album, duration, elapsed, playing, artwork (base64, once per track)
//   send   send MediaRemote command NP_CMD (2 toggle play/pause, 4 next, 5 previous) and exit
//   seek   jump the current track to NP_TIME seconds and exit
// Built and ad-hoc signed by the "Build NowPlaying bridge" phase into Contents/Resources/libNowPlaying.dylib.

#import <Foundation/Foundation.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef Boolean (*SendFn)(int, NSDictionary *);
typedef void (*SeekFn)(double);

static NSString *lastArtworkKey;

static void emit(GetInfoFn get) {
    get(dispatch_get_main_queue(), ^(NSDictionary *info) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        if (info) {
            NSString *title = info[@"kMRMediaRemoteNowPlayingInfoTitle"] ?: @"";
            NSString *artist = info[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
            double rate = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
            double elapsed = [info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
            NSDate *stamp = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
            if ([stamp isKindOfClass:NSDate.class] && rate > 0) elapsed += -stamp.timeIntervalSinceNow * rate;
            out[@"title"] = title;
            out[@"artist"] = artist;
            out[@"album"] = info[@"kMRMediaRemoteNowPlayingInfoAlbum"] ?: @"";
            out[@"duration"] = info[@"kMRMediaRemoteNowPlayingInfoDuration"] ?: @0;
            out[@"elapsed"] = @(elapsed);
            out[@"playing"] = @(rate > 0);
            NSString *key = [title stringByAppendingString:artist];
            NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
            if ([art isKindOfClass:NSData.class] && ![key isEqualToString:lastArtworkKey]) {
                out[@"artwork"] = [art base64EncodedStringWithOptions:0];
                lastArtworkKey = key;
            }
        }
        NSData *json = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
        if (!json) return;
        fwrite(json.bytes, 1, json.length, stdout);
        fputc('\n', stdout);
        fflush(stdout); // the app reads line by line; a closed pipe (app quit) ends perl via SIGPIPE
    });
}

// Installed as a perl XSUB; perl's arguments are ignored.
void np_main(void) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!mr) return;
    const char *mode = getenv("NP_MODE");
    if (mode && strcmp(mode, "seek") == 0) {
        SeekFn seek = (SeekFn)dlsym(mr, "MRMediaRemoteSetElapsedTime");
        const char *t = getenv("NP_TIME");
        if (seek && t) seek(atof(t));
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false);
        return;
    }
    if (mode && strcmp(mode, "send") == 0) {
        SendFn send = (SendFn)dlsym(mr, "MRMediaRemoteSendCommand");
        const char *cmd = getenv("NP_CMD");
        if (send) send(cmd ? atoi(cmd) : 2, nil);
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.3, false); // let the XPC message leave before exiting
        return;
    }
    GetInfoFn get = (GetInfoFn)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    if (!get) return;
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_SEC, NSEC_PER_SEC / 10);
    dispatch_source_set_event_handler(timer, ^{ emit(get); });
    dispatch_resume(timer);
    CFRunLoopRun();
}
