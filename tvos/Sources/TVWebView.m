#import "TVWebView.h"

// Custom URL scheme used by the in-page JS console hook to ferry messages
// back to native via shouldStartLoadWithRequest: (UIWebView has no real
// JS bridge — this is the standard workaround).
static NSString *const DuplexLogScheme = @"duplex-log";

// Wait this long before retrying after a failed connection attempt.
static const NSTimeInterval kReconnectIntervalSeconds = 30.0;

@interface TVWebView ()
- (NSString *)consoleHookJS;
- (NSString *)currentURLStringForWebView:(id)webView;
- (void)showStatusPageWithError:(NSError *)error;
- (void)scheduleReconnect;
- (BOOL)errorIsRetryable:(NSError *)error;
- (NSString *)htmlEscape:(NSString *)s;
@end

@implementation TVWebView {
    UIView *_webView;

    // Target URL is the "real" page we want to host. We re-attempt it on
    // failure; the status page loads under about:blank so we can tell the
    // two apart in the delegate callbacks.
    NSURL *_targetURL;

    // Incremented every time we schedule a reconnect. A pending dispatch_after
    // block captures the value it was given and bails if it no longer matches —
    // that's how we cancel superseded retries (e.g. when loadURL is called
    // manually or a previous attempt succeeded).
    NSUInteger _reconnectToken;
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
    _targetURL = url;
    // Bumping the token invalidates any in-flight reconnect timer so a manual
    // reload doesn't get clobbered by a late retry.
    _reconnectToken++;
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
    // Mark the page as running inside the tvOS host. CSS keys layout
    // changes off `.tv-mode`; JS keys remote-friendly behaviors off it too.
    [self evaluateJavaScript:@"document.documentElement.classList.add('tv-mode'); window.IS_TV = true; console.log('[hook] tv-mode flag set');"];
    NSLog(@"[Duplex] JS console hook injected into %@", currentURL);

    // If the *target* URL successfully loaded, kill any pending reconnect —
    // ignore finishes for the about:blank status page.
    if (_targetURL && [currentURL isEqualToString:_targetURL.absoluteString]) {
        _reconnectToken++;
        NSLog(@"[Duplex] Target URL reached — pending reconnects cancelled");
    }
}

- (void)webView:(id)webView didFailLoadWithError:(NSError *)error {
    // -999 (NSURLErrorCancelled) routinely fires when a new nav supersedes
    // an in-flight one — noise, never schedule a retry on it.
    NSLog(@"[Duplex] webView didFailLoadWithError domain=%@ code=%ld desc=%@ userInfo=%@",
          error.domain, (long)error.code, error.localizedDescription, error.userInfo);

    if (![self errorIsRetryable:error]) {
        return;
    }

    // Only retry if the failure was for the main target URL. Sub-resource
    // failures shouldn't drag us back to a status screen.
    NSString *failingURL = error.userInfo[@"NSErrorFailingURLStringKey"] ?: error.userInfo[NSURLErrorFailingURLStringErrorKey];
    if (failingURL && _targetURL && ![failingURL isEqualToString:_targetURL.absoluteString]) {
        NSLog(@"[Duplex] Failure was for sub-resource (%@), not target — no reconnect", failingURL);
        return;
    }

    [self showStatusPageWithError:error];
    [self scheduleReconnect];
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

- (BOOL)errorIsRetryable:(NSError *)error {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
        return NO;
    }
    return YES;
}

- (void)scheduleReconnect {
    _reconnectToken++;
    NSUInteger token = _reconnectToken;
    NSURL *url = _targetURL;
    NSLog(@"[Duplex] Scheduling reconnect to %@ in %.0fs (token=%lu)",
          url.absoluteString, kReconnectIntervalSeconds, (unsigned long)token);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kReconnectIntervalSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (token != self->_reconnectToken) {
            NSLog(@"[Duplex] Reconnect token %lu superseded — skipping", (unsigned long)token);
            return;
        }
        NSLog(@"[Duplex] Reconnect firing for %@", url.absoluteString);
        [self loadURL:url];
    });
}

- (void)showStatusPageWithError:(NSError *)error {
    if (!_webView) return;
    SEL htmlSel = NSSelectorFromString(@"loadHTMLString:baseURL:");
    if (![_webView respondsToSelector:htmlSel]) {
        NSLog(@"[Duplex] ERROR: UIWebView does not respond to loadHTMLString:baseURL:");
        return;
    }

    NSString *urlStr = [self htmlEscape:_targetURL.absoluteString ?: @"?"];
    NSString *errStr = [self htmlEscape:[NSString stringWithFormat:@"%@ (code %ld in %@)",
                                                                    error.localizedDescription ?: @"?",
                                                                    (long)error.code,
                                                                    error.domain ?: @"?"]];
    NSInteger retrySec = (NSInteger)kReconnectIntervalSeconds;

    NSString *html = [NSString stringWithFormat:
        @"<!doctype html><html><head><meta charset=\"utf-8\">"
         "<style>"
         "html,body{margin:0;padding:0;background:#0b0d12;color:#e7e9ee;"
         "font-family:-apple-system,Helvetica,Arial,sans-serif;height:100%%;}"
         ".wrap{display:flex;flex-direction:column;justify-content:center;"
         "align-items:flex-start;height:100%%;padding:0 120px;box-sizing:border-box;}"
         ".badge{display:inline-block;background:#3a1f1f;color:#ff8a8a;"
         "padding:8px 20px;border-radius:999px;font-size:24px;letter-spacing:2px;"
         "text-transform:uppercase;margin-bottom:40px;}"
         "h1{font-size:78px;margin:0 0 36px;font-weight:600;}"
         ".url{font-size:42px;color:#7cc4ff;word-break:break-all;margin-bottom:36px;"
         "font-family:Menlo,monospace;}"
         ".err{font-size:32px;color:#ffb4b4;margin-bottom:60px;line-height:1.4;}"
         ".cd{font-size:34px;color:#9aa3b2;}"
         ".n{color:#fff;font-weight:600;font-variant-numeric:tabular-nums;}"
         "</style></head><body><div class=\"wrap\">"
         "<div class=\"badge\">Can't reach Duplex</div>"
         "<h1>Waiting for the server…</h1>"
         "<div class=\"url\">%@</div>"
         "<div class=\"err\">%@</div>"
         "<div class=\"cd\">Retrying in <span class=\"n\" id=\"n\">%ld</span> s</div>"
         "</div><script>"
         "var n=%ld;var t=setInterval(function(){n--;if(n<0){n=0;}"
         "var el=document.getElementById('n');if(el)el.textContent=n;},1000);"
         "</script></body></html>",
        urlStr, errStr, (long)retrySec, (long)retrySec];

    IMP imp = [_webView methodForSelector:htmlSel];
    void (*func)(id, SEL, NSString *, NSURL *) = (void *)imp;
    func(_webView, htmlSel, html, nil);
    NSLog(@"[Duplex] Showing reconnect status page (target=%@)", _targetURL.absoluteString);
}

- (NSString *)htmlEscape:(NSString *)s {
    if (!s) return @"";
    NSMutableString *m = [s mutableCopy];
    [m replaceOccurrencesOfString:@"&" withString:@"&amp;" options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"<" withString:@"&lt;"  options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@">" withString:@"&gt;"  options:0 range:NSMakeRange(0, m.length)];
    [m replaceOccurrencesOfString:@"\"" withString:@"&quot;" options:0 range:NSMakeRange(0, m.length)];
    return m;
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
