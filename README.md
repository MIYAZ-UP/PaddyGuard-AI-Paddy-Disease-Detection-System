# PaddyGuard

PaddyGuard combines a Flutter phone app, a Roboflow rice-leaf classifier, and an Arduino Nano field monitor. The phone analyses leaf photos and sends the result to the Nano over Bluetooth; the Nano reports temperature, relative humidity, soil-probe percentage, and alert status back to the app.

## Project contents

- `lib/main.dart` — Flutter app, camera controls, Roboflow inference, Bluetooth telemetry, and field readings.
- `arduino/PaddyGuard.ino` — Nano sketch for the DHT11, soil probe, HC-05, LEDs, and buzzer.

## Run the Flutter app

Install Flutter, then from the project root run:

```sh
flutter pub get
flutter run
```

Pair the HC-05 in the phone's Bluetooth settings, connect it in PaddyGuard, enter a Roboflow API key in the app, and use the model ID `rice-leaf-diseases-detection-m7knr/3` or another compatible classification model. API keys are entered at runtime and are not included in this repository.

## Arduino setup

Open `arduino/PaddyGuard.ino` in the Arduino IDE. Install Adafruit's DHT sensor library and Adafruit Unified Sensor, select Arduino Nano, and upload the sketch. The sketch's pin map and Bluetooth commands are documented at the top of the file.

Calibrate the soil probe with `CALDRY` and `CALWET`. The reported percentage is relative to those calibration readings, not a universal soil-water percentage. For a flooded paddy field, the probe may read near 100%; interpret the weather-risk thresholds in the sketch with that in mind.
