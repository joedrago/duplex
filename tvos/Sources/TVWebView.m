#import "TVWebView.h"

// Custom URL scheme used by the in-page JS console hook to ferry messages
// back to native via shouldStartLoadWithRequest: (UIWebView has no real
// JS bridge — this is the standard workaround).
static NSString *const DuplexLogScheme = @"duplex-log";

@interface TVWebView ()
- (NSString *)consoleHookJS;
- (NSString *)currentURLStringForWebView:(id)webView;
@end

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
    if (!UIWebView) {
        NSLog(@"[Duplex] ERROR: UIWebView class not found via NSClassFromString — private API unavailable on this OS");
        return;
    }
    _webView = [[UIWebView alloc] initWithFrame:self.bounds];
    NSLog(@"[Duplex] Created UIWebView (frame=%@)", NSStringFromCGRect(self.bounds));

    @try {
        [_webView setValue:@NO forKey:@"mediaPlaybackRequiresUserAction"];
    } @catch (NSException *e) {
        NSLog(@"[Duplex] WARN: mediaPlaybackRequiresUserAction set failed: %@", e);
    }
    @try {
        [_webView setValue:@YES forKey:@"allowsInlineMediaPlayback"];
    } @catch (NSException *e) {
        NSLog(@"[Duplex] WARN: allowsInlineMediaPlayback set failed: %@", e);
    }
    @try {
        [_webView setValue:self forKey:@"delegate"];
        NSLog(@"[Duplex] UIWebView delegate wired (load/nav/JS-console events will be logged)");
    } @catch (NSException *e) {
        NSLog(@"[Duplex] ERROR: failed to set UIWebView delegate: %@ — load/JS events will NOT be visible", e);
    }

    _webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIScrollView *scrollView = [_webView valueForKey:@"scrollView"];
    if (scrollView) {
        scrollView.panGestureRecognizer.allowedTouchTypes = @[@(UITouchTypeIndirect)];
        scrollView.contentInsetAdjustmentBehavior = UIScrollViewContentInsetAdjustmentNever;
    }
    [self addSubview:_webView];
}

- (BOOL)canBecomeFocused {
    return YES;
}

- (NSArray<id<UIFocusEnvironment>> *)preferredFocusEnvironments {
    if (_webView) return @[_webView];
    return @[];
}

- (void)loadURL:(NSURL *)url {
    if (!_webView) {
        NSLog(@"[Duplex] loadURL aborted — _webView is nil");
        return;
    }
    if (!url) {
        NSLog(@"[Duplex] loadURL aborted — url is nil");
        return;
    }
    NSLog(@"[Duplex] loadURL: %@", url.absoluteString);
    NSURLRequest *request = [NSURLRequest requestWithURL:url];
    SEL loadSel = NSSelectorFromString(@"loadRequest:");
    if ([_webView respondsToSelector:loadSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [_webView performSelector:loadSel withObject:request];
#pragma clang diagnostic pop
    } else {
        NSLog(@"[Duplex] ERROR: UIWebView does not respond to loadRequest:");
    }
}

- (void)evaluateJavaScript:(NSString *)js {
    if (!_webView) return;
    SEL uiSel = NSSelectorFromString(@"stringByEvaluatingJavaScriptFromString:");
    if (![_webView respondsToSelector:uiSel]) {
        NSLog(@"[Duplex] ERROR: UIWebView does not respond to stringByEvaluatingJavaScriptFromString:");
        return;
    }
    @try {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [_webView performSelector:uiSel withObject:js];
#pragma clang diagnostic pop
    } @catch (NSException *e) {
        NSLog(@"[Duplex] JS eval exception: %@ — js prefix: %@", e, [js substringToIndex:MIN(120u, (unsigned)js.length)]);
    }
}

#pragma mark - UIWebViewDelegate (informal — UIWebView resolves selectors at runtime)

- (BOOL)webView:(id)webView shouldStartLoadWithRequest:(NSURLRequest *)request navigationType:(NSInteger)navigationType {
    NSURL *url = request.URL;

    // Intercept the JS→native log channel (see consoleHookJS).
    // Format: duplex-log://LEVEL/PERCENT_ENCODED_MESSAGE
    if ([url.scheme isEqualToString:DuplexLogScheme]) {
        NSString *level = url.host ?: @"log";
        NSString *path = url.path ?: @"";
        if ([path hasPrefix:@"/"]) path = [path substringFromIndex:1];
        NSString *msg = [path stringByRemovingPercentEncoding] ?: path;
        NSLog(@"[JS:%@] %@", [level uppercaseString], msg);
        return NO;
    }

    NSLog(@"[Duplex] shouldStartLoad navType=%ld url=%@", (long)navigationType, url.absoluteString);
    return YES;
}

- (void)webViewDidStartLoad:(id)webView {
    NSLog(@"[Duplex] webViewDidStartLoad url=%@", [self currentURLStringForWebView:webView]);
}

- (void)webViewDidFinishLoad:(id)webView {
    NSString *currentURL = [self currentURLStringForWebView:webView];
    NSLog(@"[Duplex] webViewDidFinishLoad url=%@", currentURL);
    // Re-inject on every finish: SPA route changes don't fire this, but full
    // navigations / reloads do, and we need the hook in the new document.
    [self evaluateJavaScript:[self consoleHookJS]];
    NSLog(@"[Duplex] JS console hook injected into %@", currentURL);
}

- (void)webView:(id)webView didFailLoadWithError:(NSError *)error {
    // -999 (NSURLErrorCancelled) routinely fires when a new nav supersedes
    // an in-flight one — noise, but useful to see during real failures.
    NSLog(@"[Duplex] webView didFailLoadWithError domain=%@ code=%ld desc=%@ userInfo=%@",
          error.domain, (long)error.code, error.localizedDescription, error.userInfo);
}

#pragma mark - Helpers

- (NSString *)currentURLStringForWebView:(id)webView {
    @try {
        NSURLRequest *req = [webView valueForKey:@"request"];
        return req.URL.absoluteString ?: @"?";
    } @catch (NSException *e) {
        return @"?";
    }
}

- (NSString *)consoleHookJS {
    // Overrides console.{log,info,warn,error,debug} and listens for
    // window.error / unhandledrejection. Each call creates a transient
    // hidden iframe pointed at duplex-log://LEVEL/MSG — UIWebView fires
    // shouldStartLoadWithRequest: for the iframe, we intercept and NSLog.
    // Messages are capped at 4096 chars to stay under URL length limits.
    return @"(function(){"
            "if(window.__duplexHookInstalled)return;"
            "window.__duplexHookInstalled=true;"
            "function fmt(a){"
              "if(a instanceof Error)return (a.stack||a.message||String(a));"
              "if(typeof a==='string')return a;"
              "try{return JSON.stringify(a);}catch(e){return String(a);}"
            "}"
            "function send(level,args){"
              "try{"
                "var parts=[];"
                "for(var i=0;i<args.length;i++){parts.push(fmt(args[i]));}"
                "var msg=parts.join(' ');"
                "if(msg.length>4096)msg=msg.substring(0,4096)+'…[truncated]';"
                "var f=document.createElement('iframe');"
                "f.style.display='none';"
                "f.src='duplex-log://'+level+'/'+encodeURIComponent(msg);"
                "(document.documentElement||document.body||document).appendChild(f);"
                "setTimeout(function(){try{f.parentNode&&f.parentNode.removeChild(f);}catch(e){}},0);"
              "}catch(e){}"
            "}"
            "['log','info','warn','error','debug'].forEach(function(level){"
              "var orig=console[level];"
              "console[level]=function(){send(level,arguments);if(orig)try{orig.apply(console,arguments);}catch(e){}};"
            "});"
            "window.addEventListener('error',function(e){"
              "send('error',['[window.error] '+(e.message||'?')+' @ '+(e.filename||'?')+':'+(e.lineno||'?')+':'+(e.colno||'?')+(e.error&&e.error.stack?' '+e.error.stack:'')]);"
            "});"
            "window.addEventListener('unhandledrejection',function(e){"
              "var r=e.reason;"
              "send('error',['[unhandledrejection] '+((r&&r.stack)||(r&&r.message)||String(r))]);"
            "});"
            "console.log('[hook] installed; UA='+navigator.userAgent+' URL='+location.href);"
          "})();";
}

@end
