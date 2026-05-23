#import "TVWebView.h"

@implementation TVWebView {
    UIView *_webView;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        [self setupWebView];
    }
    return self;
}

- (void)setupWebView {
    Class UIWebView = NSClassFromString(@"UIWebView");
    if (UIWebView) {
        _webView = [[UIWebView alloc] initWithFrame:self.bounds];
        NSLog(@"[Duplex] Created UIWebView");

        @try {
            [_webView setValue:@NO forKey:@"mediaPlaybackRequiresUserAction"];
        } @catch (NSException *e) {}
        @try {
            [_webView setValue:@YES forKey:@"allowsInlineMediaPlayback"];
        } @catch (NSException *e) {}
    }

    if (_webView) {
        _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

        UIScrollView *scrollView = [_webView valueForKey:@"scrollView"];
        if (scrollView) {
            scrollView.panGestureRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirect)];
            scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
        }

        [self addSubview:_webView];
    }
}

- (BOOL)canBecomeFocused {
    return YES;
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (_webView) return @[_webView];
    return @[];
}

- (void)loadURL:(NSURL *)url {
    if (!_webView || !url) return;
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    SEL loadSel = NSSelectorFromString(@"loadRequest:");
    if ([_webView respondsToSelector:loadSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [_webView performSelector:loadSel withObject:request];
#pragma clang diagnostic pop
    }
}

- (void)evaluateJavaScript:(NSString *)js {
    if (!_webView) return;
    SEL uiSel = NSSelectorFromString(@"stringByEvaluatingJavaScriptFromString:");
    if ([_webView respondsToSelector:uiSel]) {
        @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [_webView performSelector:uiSel withObject:js];
#pragma clang diagnostic pop
        } @catch (NSException *e) {
            NSLog(@"[Duplex] JS eval exception: %@", e);
        }
    }
}

@end
