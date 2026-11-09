APP := build/MeetingNotes.app

.PHONY: app run install clean

app:
	./scripts/build-app.sh

run: app
	-pkill -x MeetingNotes && sleep 0.5
	open $(APP)

install: app
	-pkill -x MeetingNotes && sleep 0.5
	rm -rf /Applications/MeetingNotes.app
	cp -R $(APP) /Applications/
	open /Applications/MeetingNotes.app

clean:
	rm -rf .build build
