// Read-only saver probe; all mutation checks use one temporary JSON file.
// Compile with clang -fobjc-arc -framework AppKit -framework ScreenSaver -framework QuartzCore.
// Run with the path to an AuraFlowLockScreen.saver bundle; add --cache for
// cache identity, expiry and bounded-retention checks on an optimized build.
#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import <QuartzCore/QuartzCore.h>
#import <sys/stat.h>
#import <fcntl.h>
@interface ScreenSaverView (JSONProbe)
- (NSDictionary *)JSONDictionaryAtURL:(NSURL *)url;
@end
int main(int argc,const char *argv[]) { @autoreleasepool {
 if (argc < 2) return 1;
 [NSApplication sharedApplication];
 NSBundle *bundle=[NSBundle bundleWithPath:[NSString stringWithUTF8String:argv[1]]];
 if (![bundle load]) return 2;
 ScreenSaverView *view=[[bundle.principalClass alloc] initWithFrame:NSMakeRect(0,0,320,240) isPreview:YES];
 NSURL *url=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
 void (^write)(NSString *)=^(NSString *value){[value writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];};
 write(@"{\"mode\":\"fill\"}");
 for(int pass=0;pass<5;pass++){
  CFTimeInterval start=CACurrentMediaTime();
  for(int i=0;i<5000;i++)@autoreleasepool { if(![[view JSONDictionaryAtURL:url][@"mode"] isEqual:@"fill"])return 3; }
  printf("JSON 5000 reads: %.6f seconds\n",CACurrentMediaTime()-start);
 }
 if(argc>2){
  NSDictionary *first=[view JSONDictionaryAtURL:url];
  if(first!=[view JSONDictionaryAtURL:url])return 9;
  NSMutableDictionary *cache=[view valueForKey:@"jsonCache"];
  [cache[url.path] setValue:@(CACurrentMediaTime()-61) forKey:@"createdAt"];
  if(first==[view JSONDictionaryAtURL:url])return 10;
  for(int i=0;i<40;i++){
   NSURL *other=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
   [@"{\"test\":true}" writeToURL:other atomically:YES encoding:NSUTF8StringEncoding error:nil];
   if([view JSONDictionaryAtURL:other].count!=1)return 11;
   [[NSFileManager defaultManager]removeItemAtURL:other error:nil];
   if(cache.count>16)return 12;
  }
 }
 struct stat info;stat(url.fileSystemRepresentation,&info);
 [@"{\"mode\":\"fit \"}" writeToURL:url atomically:NO encoding:NSUTF8StringEncoding error:nil];
 struct timespec times[2]={info.st_atimespec,info.st_mtimespec};utimensat(AT_FDCWD,url.fileSystemRepresentation,times,0);
 if(![[view JSONDictionaryAtURL:url][@"mode"] isEqual:@"fit "])return 4;
 write(@"{\"mode\":\"stretch\"}"); if(![[view JSONDictionaryAtURL:url][@"mode"] isEqual:@"stretch"])return 5;
 write(@"invalid");if([view JSONDictionaryAtURL:url].count)return 6;
 write(@"{\"mode\":\"fill\"}");if(![[view JSONDictionaryAtURL:url][@"mode"] isEqual:@"fill"])return 7;
 [[NSFileManager defaultManager]removeItemAtURL:url error:nil];if([view JSONDictionaryAtURL:url].count)return 8;
 printf("CACHE INVALIDATION PASS\n");[view stopAnimation];return 0;
}}
