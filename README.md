# Notchy

Notchy is a macOS notch companion prototype. It expands from the camera notch on hover and shows current media playback details, progress, and audio output state.

## Build and Run

```sh
./script/build_and_run.sh
```

The app is a Swift Package Manager macOS app. The run script builds the package, stages `dist/Notchy.app`, and launches it.

## Notes

- Browser media progress uses supported browser automation where available.
- QuickTime and Apple Music media details may require macOS Automation permission.
