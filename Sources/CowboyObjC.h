#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
// AVFoundation reports invalid writer/capture configurations by raising NSException, which Swift cannot catch:
// the app would just close. This turns the exception into a message.
@interface CowboyObjC : NSObject
+ (nullable NSString *)catching:(void (NS_NOESCAPE ^)(void))block;
@end
NS_ASSUME_NONNULL_END
