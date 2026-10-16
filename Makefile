APP := build/Millume.app
SWIFT_BUILD := swift build -c release --arch arm64 --arch x86_64

.PHONY: app run install probe clean

app:
	$(SWIFT_BUILD)
	rm -rf $(APP)
	mkdir -p $(APP)/Contents/MacOS
	cp "$$($(SWIFT_BUILD) --show-bin-path)/Millume" $(APP)/Contents/MacOS/Millume
	cp Resources/Info.plist $(APP)/Contents/Info.plist
	codesign --force --sign - $(APP)

run: app
	open $(APP)

install: app
	rm -rf /Applications/Millume.app
	cp -R $(APP) /Applications/Millume.app

probe: app
	$(APP)/Contents/MacOS/Millume --probe

clean:
	rm -rf .build build
