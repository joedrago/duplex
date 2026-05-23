WEBVIEW_URL ?= http://localhost:2345
DEVELOPMENT_TEAM ?= $(shell security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')

PROJECT = Duplex.xcodeproj
SCHEME = Duplex

.PHONY: generate build simulator install massinstall list clean

generate: $(PROJECT)

$(PROJECT): project.yml Sources/Info.plist Sources/AppDelegate.swift Sources/WebViewController.swift Sources/TVWebView.h Sources/TVWebView.m Sources/BridgingHeader.h
	xcodegen generate

build: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-sdk appletvos \
		-configuration Release \
		WEBVIEW_URL='$(WEBVIEW_URL)' \
		DEVELOPMENT_TEAM='$(DEVELOPMENT_TEAM)' \
		-allowProvisioningUpdates \
		build

simulator: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-sdk appletvsimulator \
		-destination 'platform=tvOS Simulator,name=Apple TV' \
		WEBVIEW_URL='$(WEBVIEW_URL)' \
		build

install: build
	$(eval APP := $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -sdk appletvos -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR = /{print $$3}')/Duplex.app)
	$(eval DEVICE_ID ?= $(shell xcrun devicectl list devices 2>/dev/null | grep 'Apple TV' | head -1 | awk '{for(i=1;i<=NF;i++) if($$i ~ /^[0-9A-F].*-.*-/) print $$i}'))
	@if [ -z "$(DEVICE_ID)" ]; then echo "Error: No Apple TV found. Run 'xcrun devicectl list devices' and pass DEVICE_ID=..."; exit 1; fi
	xcrun devicectl device install app --device $(DEVICE_ID) $(APP)
	xcrun devicectl device process launch --device $(DEVICE_ID) --terminate-existing com.duplex.app

list:
	@xcrun devicectl list devices 2>/dev/null | grep 'Apple TV'

clean:
	rm -rf $(PROJECT) build DerivedData
