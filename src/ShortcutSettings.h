#import <Cocoa/Cocoa.h>
#import "HotKey.h"

NSString *BMShortcutLabel(UInt32 keyCode, UInt32 modifiers);
BOOL BMShortcutIsValid(UInt32 keyCode, UInt32 modifiers);
NSArray<NSDictionary *> *BMShortcutKeys(void);

@interface BMShortcutRecorder : NSButton
@property(nonatomic) UInt32 recordedKeyCode, recordedModifiers;
- (void)refreshTitle;
- (void)stopRecording;
@end
