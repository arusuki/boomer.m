#import <Foundation/Foundation.h>
#import <Carbon/Carbon.h>

// Main-thread-only registration. Uses a hot key, not a keyboard event tap.
@interface BMHotKey : NSObject
@property(nonatomic, readonly, getter=isRegistered) BOOL registered;
@property(nonatomic, readonly) UInt32 keyCode, modifiers;
// Registers the replacement first; failure leaves the current binding intact.
- (BMHotKey *)replacementWithKeyCode:(UInt32)keyCode modifiers:(UInt32)modifiers error:(NSError **)error;
- (instancetype)initWithKeyCode:(UInt32)keyCode modifiers:(UInt32)modifiers handler:(dispatch_block_t)handler;
- (BOOL)registerWithError:(NSError **)error;
- (void)unregister;
@end
