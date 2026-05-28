# Backward-compat: accept WEBVIEW_URL as an alias for SERVER_URL so the old
# `make run … WEBVIEW_URL=…` invocations still work.
SERVER_URL ?= $(WEBVIEW_URL)
SERVER_URL ?= http://localhost:2345
DEVELOPMENT_TEAM ?= $(shell security find-certificate -c "Apple Development" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -n 's/.*OU=\([A-Z0-9]*\).*/\1/p')

PROJECT = Duplex.xcodeproj
SCHEME = Duplex

.PHONY: generate build simulator install run massinstall list clean

generate: $(PROJECT)

$(PROJECT): project.yml $(shell find Sources -type f \( -name '*.swift' -o -name '*.plist' -o -name '*.h' -o -name '*.m' \) 2>/dev/null)
	xcodegen generate

build: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-sdk appletvos \
		-configuration Release \
		-destination 'generic/platform=tvOS' \
		SERVER_URL='$(SERVER_URL)' \
		DEVELOPMENT_TEAM='$(DEVELOPMENT_TEAM)' \
		-allowProvisioningUpdates \
		build

simulator: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme $(SCHEME) \
		-sdk appletvsimulator \
		-destination 'platform=tvOS Simulator,name=Apple TV' \
		SERVER_URL='$(SERVER_URL)' \
		build

install: build
	$(eval APP := $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -sdk appletvos -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR = /{print $$3}')/Duplex.app)
	$(eval DEVICE_ID ?= $(shell xcrun devicectl list devices 2>/dev/null | grep 'Apple TV' | head -1 | awk '{for(i=1;i<=NF;i++) if($$i ~ /^[0-9A-F].*-.*-/) print $$i}'))
	@if [ -z "$(DEVICE_ID)" ]; then echo "Error: No Apple TV found. Run 'xcrun devicectl list devices' and pass DEVICE_ID=..."; exit 1; fi
	xcrun devicectl device install app --device $(DEVICE_ID) $(APP)
	xcrun devicectl device process launch --device $(DEVICE_ID) --terminate-existing com.duplex.app

run: build
	$(eval APP := $(shell xcodebuild -project $(PROJECT) -scheme $(SCHEME) -sdk appletvos -configuration Release -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR = /{print $$3}')/Duplex.app)
	$(eval DEVICE_ID ?= $(shell xcrun devicectl list devices 2>/dev/null | grep 'Apple TV' | head -1 | awk '{for(i=1;i<=NF;i++) if($$i ~ /^[0-9A-F].*-.*-/) print $$i}'))
	@if [ -z "$(DEVICE_ID)" ]; then echo "Error: No Apple TV found. Run 'xcrun devicectl list devices' and pass DEVICE_ID=..."; exit 1; fi
	xcrun devicectl device install app --device $(DEVICE_ID) $(APP)
	xcrun devicectl device process launch --device $(DEVICE_ID) --terminate-existing --console com.duplex.app

list:
	@xcrun devicectl list devices 2>/dev/null | grep 'Apple TV'

clean:
	rm -rf $(PROJECT) build DerivedData
