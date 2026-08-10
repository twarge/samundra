# Samundra

A native macOS application for Ocean Optics HR4000 spectrometers (including
the HR4000CG). Samundra is a single-window SwiftUI app: connect a
spectrometer and the window shows the live spectrum; Save (⌘S) writes
whatever was last acquired.

No vendor drivers or third-party libraries are required. The app talks to the
spectrometer directly over USB with Apple's `IOUSBHost` framework.

## Features

- Live spectrum display with a visible-spectrum color gradient, hover readout
  (wavelength/counts), peak indicator, and saturation warning; pinch to zoom
  the wavelength axis, drag or two-finger pan to scroll, double-click to
  reset
- Settings and zoom state persist across launches
- Prominence-based peak detection with sub-pixel wavelength marks on the
  chart; sensitivity, anticipated width, and peak-count controls in the
  sidebar
- Optional reference-line overlay from a bundled extract of the NIST Atomic
  Spectra Database (48k observed lines, 193–1105 nm, ions I–III): labeled
  vertical lines on the plot, filterable by element, ionization state, and
  line strength
- Integration time (3.8 ms – 10 s), scan averaging, and boxcar smoothing
- Electric-dark and detector-nonlinearity corrections using the calibration
  stored in the instrument's EEPROM
- Recording is automatic whenever a spectrometer is connected
- Save (⌘S) writes a plain two-column `.csv` file (`wavelength,amplitude`
  with a header line); ⌘C or right-click ▸ Copy Data puts the same CSV on
  the clipboard

## Building

Open `apps/Samundra.xcodeproj` in Xcode (16 or later) and run, or:

```sh
make mac
```

which is the same build ⌘B performs. `make mac-release` builds optimised;
`make icon` regenerates the app icon from `apps/make-icon.swift`.

### Command-line diagnostic

`Tools/hr4000-capture` opens the spectrometer, prints its EEPROM calibration,
and captures a few spectra — useful when bringing up hardware:

```sh
./Tools/build-cli.sh
./build/hr4000-capture
```

There is also a headless smoke test built into the app: launch the app binary
with `SAMUNDRA_AUTOTEST=1` in the environment and it captures one spectrum
after connecting, reporting the result to the unified log (subsystem
`com.twarge.samundra`).

## How it talks to the HR4000

The HR4000 (USB VID 0x2457, PID 0x1012) exposes a vendor-specific interface:
commands on endpoint 0x01, query replies on 0x81, and spectra on 0x86 + 0x82
(high speed). Each spectrum is 3840 little-endian 16-bit words (bit 13
inverted) plus a 0x69 sync byte; the first 3648 words are detector pixels.
Wavelength and linearity calibrations are read from EEPROM info slots.

The protocol details come from the Ocean Optics *HR4000 Data Sheet* and were
cross-checked against [python-seabreeze](https://github.com/ap--/python-seabreeze)
(MIT licensed). All code here is original.

### Sandbox note

The app is sandboxed. `com.apple.security.device.usb` alone does not cover the
`IOUSBHost` framework's user clients (`AppleUSBHostFrameworkDeviceClient` /
`AppleUSBHostFrameworkInterfaceClient`), so the entitlements add a
`temporary-exception.iokit-user-client-class` for them.

## Data attribution

Atomic line identifications use data extracted from the NIST Atomic Spectra
Database: Kramida, A., Ralchenko, Yu., Reader, J., and NIST ASD Team,
[NIST Atomic Spectra Database](https://physics.nist.gov/asd), National
Institute of Standards and Technology. NIST data is in the public domain;
this acknowledgment follows NIST's citation request.

## License

Samundra is a Twarge app, released under the Apache License 2.0 — see
[LICENSE](LICENSE).
