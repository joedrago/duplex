#import <UIKit/UIKit.h>

/// Wrapper around UIWebView loaded via private API on tvOS. The tvOS SDK does
/// not link WebKit, so we resolve UIWebView at runtime via NSClassFromString.
@interface TVWebView : UIView

- (void)loadURL:(NSURL *)url;
- (void)evaluateJavaScript:(NSString *)js;

@end
