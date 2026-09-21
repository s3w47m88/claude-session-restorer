#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

typedef int CGSConnectionID;
extern CGSConnectionID _CGSDefaultConnection(void);
extern CFArrayRef CGSCopyManagedDisplaySpaces(CGSConnectionID);
extern CFArrayRef CGSCopySpacesForWindows(CGSConnectionID, int mask, CFArrayRef windows);
extern void CGSMoveWindowsToManagedSpace(CGSConnectionID, CFArrayRef windows, uint64_t space);

static NSArray* displays(CGSConnectionID c){ return (__bridge_transfer NSArray*)CGSCopyManagedDisplaySpaces(c); }

static int indexForSpace(NSArray* disp, uint64_t sid){
  int idx=0;
  for(NSDictionary* d in disp) for(NSDictionary* s in d[@"Spaces"]){ idx++;
    if([s[@"ManagedSpaceID"] unsignedLongLongValue]==sid) return idx; }
  return -1;
}
static uint64_t spaceForIndex(NSArray* disp, int want){
  int idx=0;
  for(NSDictionary* d in disp) for(NSDictionary* s in d[@"Spaces"]){ idx++;
    if(idx==want) return [s[@"ManagedSpaceID"] unsignedLongLongValue]; }
  return 0;
}

int main(int argc, char** argv){
  @autoreleasepool {
    CGSConnectionID c=_CGSDefaultConnection();
    NSArray* disp=displays(c);
    NSString* cmd = argc>=2 ? @(argv[1]) : @"";
    if([cmd isEqual:@"current"]){
      uint64_t cur=[disp.firstObject[@"Current Space"][@"ManagedSpaceID"] unsignedLongLongValue];
      printf("%d\n", indexForSpace(disp,cur)); return 0;
    }
    if([cmd isEqual:@"window"] && argc>=3){
      CFArrayRef wids=(__bridge CFArrayRef)@[@(atoi(argv[2]))];
      NSArray* sp=(__bridge_transfer NSArray*)CGSCopySpacesForWindows(c,0x7,wids);
      printf("%d\n", sp.count?indexForSpace(disp,[sp.firstObject unsignedLongLongValue]):-1); return 0;
    }
    if([cmd isEqual:@"move"] && argc>=4){
      uint64_t sid=spaceForIndex(disp,atoi(argv[3]));
      if(!sid){ fprintf(stderr,"no desktop %s\n",argv[3]); return 1; }
      CGSMoveWindowsToManagedSpace(c,(__bridge CFArrayRef)@[@(atoi(argv[2]))],sid);
      printf("ok\n"); return 0;
    }
    if([cmd isEqual:@"find"]){  // list ALL windows (any Space) for owner (default iTerm2): id x y w h title
      NSString* owner = argc>=3 ? @(argv[2]) : @"iTerm2";
      CFArrayRef info=CGWindowListCopyWindowInfo(kCGWindowListOptionAll|kCGWindowListExcludeDesktopElements,kCGNullWindowID);
      for(NSDictionary* w in (__bridge_transfer NSArray*)info){
        if(![w[(id)kCGWindowOwnerName] isEqual:owner]) continue;
        NSDictionary* b=w[(id)kCGWindowBounds];
        int wid=[w[(id)kCGWindowNumber] intValue];
        NSString* t=w[(id)kCGWindowName]?:@"";  // may be empty without Screen Recording — window id/Space still valid
        printf("%d\t%.0f\t%.0f\t%.0f\t%.0f\t%s\n",wid,[b[@"X"] doubleValue],[b[@"Y"] doubleValue],
          [b[@"Width"] doubleValue],[b[@"Height"] doubleValue],t.UTF8String);
      }
      return 0;
    }
    if([cmd isEqual:@"spaces"]){  // list ALL windows (any Space) for owner: windowID<TAB>spaceIndex, without switching Spaces
      NSString* owner = argc>=3 ? @(argv[2]) : @"iTerm2";
      CFArrayRef info=CGWindowListCopyWindowInfo(kCGWindowListOptionAll|kCGWindowListExcludeDesktopElements,kCGNullWindowID);
      for(NSDictionary* w in (__bridge_transfer NSArray*)info){
        if(![w[(id)kCGWindowOwnerName] isEqual:owner]) continue;
        int wid=[w[(id)kCGWindowNumber] intValue];
        CFArrayRef wids=(__bridge CFArrayRef)@[@(wid)];
        NSArray* sp=(__bridge_transfer NSArray*)CGSCopySpacesForWindows(c,0x7 /* kCGSAllSpacesMask */,wids);
        int spaceIdx = sp.count ? indexForSpace(disp,[sp.firstObject unsignedLongLongValue]) : -1;
        printf("%d\t%d\n",wid,spaceIdx);
      }
      return 0;
    }
    fprintf(stderr,"usage: spacesctl current | window <id> | move <id> <desktop> | find [owner] | spaces [owner]\n");
    return 2;
  }
}
