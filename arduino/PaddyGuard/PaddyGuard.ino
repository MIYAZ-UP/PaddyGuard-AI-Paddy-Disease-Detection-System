/*
  =====================================================================
  PaddyGuard - AI Paddy Disease Detection System
  Board : Arduino Nano (ATmega328P, 5 V)
  Parts : DHT11, soil moisture sensor with LM393 comparator, red / green /
          blue LEDs (220 ohm each), active buzzer 2510, HC-05 Bluetooth

  Libraries (Sketch > Include Library > Manage Libraries):
      "DHT sensor library"      by Adafruit
      "Adafruit Unified Sensor" by Adafruit
  (SoftwareSerial and EEPROM come with the Arduino IDE.)

  PIN MAP
      D2  -> HC-05 RXD   (Nano transmits)
      D3  <- HC-05 TXD   (Nano receives)
      D4  <-> DHT11 DATA
      D8  -> Active buzzer (+)
      D9  -> 220R -> RED   LED -> GND
      D10 -> 220R -> GREEN LED -> GND
      D11 -> 220R -> BLUE  LED -> GND
      A0  <- Soil sensor AO (analog)
      A1  <- Soil sensor DO (comparator, digital)
      A2  -> Soil sensor VCC (switched on only while reading, so the
             probe does not corrode)
      5V  -> HC-05 VCC, DHT11 VCC        GND -> everything

  HOW THE ALERTS WORK
      The phone app photographs a leaf, runs the AI model and sends the
      result over Bluetooth as a text line (BLAST, BROWNSPOT, BLB or
      HEALTHY). The Nano combines that with the weather inside the field:

      GREEN steady          SAFE     AI says healthy and soil is above 65%
      GREEN blink           SAFE     all general growing conditions are good
      BLUE steady           WATCH    outside good field conditions
      BLUE steady           WATCH    one or more readings are moderate
      BLUE fast blink       FAULT    DHT11 is not answering
      RED fast blink + 150 ms beep every 5 seconds HIGH
                                 very-bad reading or weather risk
      RED fast blink + continuous buzzer DISEASE
                                 AI found a disease on a leaf

  BLUETOOTH COMMANDS (end each with a new line)
      BLAST | BROWNSPOT | BLB   disease found by the AI
      HEALTHY                    AI found a healthy leaf (green only when
                                 field conditions are good and soil is >65%)
      CLEAR                      clear the current AI result/alert
      MUTE / UNMUTE             silence / restore the buzzer
      STATUS                    reply with one reading now
      TEST                      LED and buzzer self test
      CALDRY / CALWET           store soil calibration (see below)
      HELP                      list commands

  BLUETOOTH REPLY (every 2 s), comma separated
      PG,temp_C,humidity_%,soil_%,level,ai,risk,fault,muted
      level: 0 safe, 1 watch, 2 high, 3 disease

  SOIL CALIBRATION (once)
      1. Probe in the air or dry soil   -> send CALDRY
      2. Probe in a glass of water      -> send CALWET
      The values are saved in EEPROM.
  =====================================================================
*/

#include <SoftwareSerial.h>
#include <EEPROM.h>
#include <DHT.h>

// ---------------------------- Pins ---------------------------------
const uint8_t PIN_BT_TX    = 2;    // Nano TX -> HC-05 RXD
const uint8_t PIN_BT_RX    = 3;    // Nano RX <- HC-05 TXD
const uint8_t PIN_DHT      = 4;
const uint8_t PIN_BUZZER   = 8;
const uint8_t PIN_LED_R    = 9;
const uint8_t PIN_LED_G    = 10;
const uint8_t PIN_LED_B    = 11;
const uint8_t PIN_SOIL_AO  = A0;
const uint8_t PIN_SOIL_DO  = A1;
const uint8_t PIN_SOIL_PWR = A2;

// ------------------------- Tunable limits --------------------------
const unsigned long SAMPLE_MS   = 2000UL;     // DHT11 needs 1 s or more
const unsigned long AI_HOLD_MS  = 600000UL;   // AI alert stays 10 min
const uint8_t       FAULT_AFTER  = 3;         // failed DHT reads in a row
const uint8_t       RISK_CONFIRM = 2;         // same weather risk this many
                                              // readings in a row = HIGH

// Buzzer polarity. Most 3-pin buzzer modules are "low level trigger":
// they sound when the pin is LOW. If your buzzer is silent on TEST and
// loud the rest of the time, flip this value.
const bool BUZZER_ACTIVE_LOW = true;

// Disease-risk alerts use the very-bad bands from the user's disease chart.
// All three require soil below 40%, as specified in that chart.

// ----------------------------- Codes -------------------------------
const uint8_t LV_SAFE = 0, LV_WATCH = 1, LV_HIGH = 2, LV_DISEASE = 3;
const uint8_t DZ_NONE = 0, DZ_BLAST = 1, DZ_BROWN = 2, DZ_BLB = 3;
const char *const LV_NAME[] = {"SAFE", "WATCH", "HIGH", "DISEASE"};
const char *const DZ_NAME[] = {"NONE", "BLAST", "BROWNSPOT", "BLB"};

// ---------------------------- Objects ------------------------------
SoftwareSerial btSerial(PIN_BT_RX, PIN_BT_TX);   // RX, TX
DHT dht(PIN_DHT, DHT11);

// ---------------------------- State --------------------------------
struct Calib {
  uint16_t magic;
  int16_t  dryRaw;
  int16_t  wetRaw;
};
const uint16_t CAL_MAGIC = 0x5047;               // "PG"
Calib calib = {CAL_MAGIC, 1000, 350};            // typical LM393 probe

float temp = 0, hum = 0;
bool  haveClimate = false;
uint8_t dhtFails = 0;
int   soilRaw = 0;
uint8_t soilPct = 0;
bool  soilDoDry = false;

uint8_t aiDisease = DZ_NONE;
unsigned long aiStart = 0;
bool aiHealthy = false;
uint8_t riskDisease = DZ_NONE;
uint8_t lastRawRisk = DZ_NONE;
uint8_t riskStreak = 0;
uint8_t level = LV_SAFE;
bool  sensorFault = false;
bool  muted = false;
const unsigned long CONDITION_BEEP_MS = 150UL;
const unsigned long CONDITION_BEEP_GAP_MS = 5000UL;
unsigned long nextAlarmBeepAt = 0;
unsigned long alarmBeepUntil = 0;
bool redAlertWasActive = false;
uint8_t lastRedAlertLevel = LV_SAFE;
unsigned long lastSample = 0;
bool  firstSample = true;

char btBuf[24];  uint8_t btLen = 0;
char usbBuf[24]; uint8_t usbLen = 0;

// ------------------------- Small helpers ---------------------------
bool aiActive() {
  return aiDisease != DZ_NONE && (millis() - aiStart) < AI_HOLD_MS;
}

bool aiHealthyActive() {
  return aiHealthy && (millis() - aiStart) < AI_HOLD_MS;
}

void setLeds(bool r, bool g, bool b) {
  digitalWrite(PIN_LED_R, r ? HIGH : LOW);
  digitalWrite(PIN_LED_G, g ? HIGH : LOW);
  digitalWrite(PIN_LED_B, b ? HIGH : LOW);
}

void buzzerWrite(bool on) {
  digitalWrite(PIN_BUZZER, (on != BUZZER_ACTIVE_LOW) ? HIGH : LOW);
}

void beep(unsigned int ms) {
  buzzerWrite(true);
  delay(ms);
  buzzerWrite(false);
}

void loadCalibration() {
  Calib c;
  EEPROM.get(0, c);
  if (c.magic == CAL_MAGIC && c.dryRaw != c.wetRaw) calib = c;
}

void saveCalibration() {
  EEPROM.put(0, calib);
}

// --------------------------- Sensors -------------------------------
int readSoilRaw() {
  digitalWrite(PIN_SOIL_PWR, HIGH);      // power the probe only now
  delay(60);
  long sum = 0;
  for (uint8_t i = 0; i < 8; i++) {
    sum += analogRead(PIN_SOIL_AO);
    delay(5);
  }
  soilDoDry = digitalRead(PIN_SOIL_DO) == HIGH;  // HIGH = dry on most modules
  digitalWrite(PIN_SOIL_PWR, LOW);
  return (int)(sum / 8);
}

uint8_t rawToPercent(int raw) {
  long pct = map(raw, calib.dryRaw, calib.wetRaw, 0, 100);
  return (uint8_t)constrain(pct, 0, 100);
}

void readSensors() {
  float t = dht.readTemperature();
  float h = dht.readHumidity();
  if (isnan(t) || isnan(h)) {
    if (dhtFails < 255) dhtFails++;
  } else {
    temp = t;
    hum = h;
    dhtFails = 0;
    haveClimate = true;
  }
  sensorFault = dhtFails >= FAULT_AFTER;

  soilRaw = readSoilRaw();
  soilPct = rawToPercent(soilRaw);
}

// ------------------------- Risk decision ---------------------------
bool allGrowingConditionsGood() {
  return haveClimate && temp >= 25 && temp <= 35 &&
         hum >= 70 && hum <= 90 && soilPct >= 70;
}

bool anyGrowingConditionVeryBad() {
  if (!haveClimate) return false;
  return temp < 15 || temp > 40 || hum < 50 || hum > 95 || soilPct < 40;
}

uint8_t climateDisease() {
  if (!haveClimate) return DZ_NONE;
  if (soilPct >= 40) return DZ_NONE;
  // Overlapping chart bands are resolved in this order: blast, brown spot,
  // then bacterial leaf blight.
  if (temp >= 20 && temp <= 28 && hum > 90) return DZ_BLAST;
  if (temp >= 30 && temp <= 35 && hum > 85) return DZ_BROWN;
  if (temp >= 25 && temp <= 34 && hum > 85) return DZ_BLB;
  return DZ_NONE;
}

// Called once per sample. A weather risk only counts after it has been
// seen RISK_CONFIRM times in a row (DHT11 readings jitter a little).
void updateRisk() {
  uint8_t raw = climateDisease();
  if (raw != DZ_NONE && raw == lastRawRisk) {
    if (riskStreak < 255) riskStreak++;
  } else {
    riskStreak = (raw != DZ_NONE) ? 1 : 0;
  }
  lastRawRisk = raw;
  riskDisease = (riskStreak >= RISK_CONFIRM) ? raw : DZ_NONE;
}

void evaluate(unsigned long now) {
  uint8_t lv = LV_SAFE;

  if (aiActive()) {
    lv = LV_DISEASE;
  } else if (riskDisease != DZ_NONE) {
    lv = LV_HIGH;
  } else if (haveClimate && anyGrowingConditionVeryBad()) {
    lv = LV_HIGH;
  } else if (aiHealthyActive()) {
    lv = allGrowingConditionsGood() && soilPct > 65 ? LV_SAFE : LV_WATCH;
  } else if (allGrowingConditionsGood()) {
    lv = LV_SAFE;
  } else {
    lv = LV_WATCH;
  }

  if (lv < LV_HIGH) muted = false;          // next alarm is audible again
  level = lv;
}

// --------------------------- Outputs -------------------------------
void updateOutputs(unsigned long now) {
  bool r = false, g = false, b = false;
  bool redAlert = level == LV_DISEASE ||
                  (level == LV_HIGH && !sensorFault);

  if (level == LV_DISEASE) {
    redAlertWasActive = true;
    lastRedAlertLevel = LV_DISEASE;
    nextAlarmBeepAt = 0;
    alarmBeepUntil = 0;
  } else if (level == LV_HIGH && !sensorFault) {
    if (!redAlertWasActive || lastRedAlertLevel != LV_HIGH) {
      redAlertWasActive = true;
      lastRedAlertLevel = LV_HIGH;
      nextAlarmBeepAt = now;                // first short beep immediately
    }
    if ((long)(now - nextAlarmBeepAt) >= 0) {
      alarmBeepUntil = now + CONDITION_BEEP_MS;
      nextAlarmBeepAt = now + CONDITION_BEEP_GAP_MS;
    }
  } else {
    redAlertWasActive = false;
    lastRedAlertLevel = LV_SAFE;
    nextAlarmBeepAt = 0;
    alarmBeepUntil = 0;
  }

  if (sensorFault && level != LV_DISEASE) {   // a disease alert wins
    b = ((now / 200UL) % 2UL) == 0;
  } else if (level == LV_SAFE) {
    g = aiHealthyActive() || ((now / 500UL) % 2UL) == 0;
  } else if (level == LV_WATCH) {
    b = true;
  } else if (level == LV_HIGH) {
    r = ((now / 250UL) % 2UL) == 0;
  } else {
    r = ((now / 250UL) % 2UL) == 0;
  }
  setLeds(r, g, b);

  bool buz = false;
  if (!muted && level == LV_DISEASE) {
    buz = true;
  } else if (!muted && redAlert && level == LV_HIGH) {
    buz = (long)(alarmBeepUntil - now) > 0;
  }
  buzzerWrite(buz);
}

void selfTest() {
  setLeds(true, false, false);  beep(120);  delay(250);
  setLeds(false, true, false);  delay(300);
  setLeds(false, false, true);  delay(300);
  setLeds(true, true, true);    beep(120);  delay(300);
  setLeds(false, false, false);
}

// --------------------------- Reporting -----------------------------
void sendTelemetry(Stream &out) {
  out.print(F("PG,"));
  out.print(temp, 1);            out.print(',');
  out.print(hum, 0);             out.print(',');
  out.print(soilPct);            out.print(',');
  out.print(level);              out.print(',');
  if (aiActive()) out.print(DZ_NAME[aiDisease]);
  else if (aiHealthyActive()) out.print(F("HEALTHY"));
  else out.print(DZ_NAME[DZ_NONE]);
  out.print(',');
  out.print(DZ_NAME[riskDisease]); out.print(',');
  out.print(sensorFault ? 1 : 0);  out.print(',');
  out.println(muted ? 1 : 0);
}

void printReadable(Stream &out) {
  out.print(F("T="));      out.print(temp, 1);
  out.print(F(" C  H="));  out.print(hum, 0);
  out.print(F("%  Soil=")); out.print(soilPct);
  out.print(F("% (raw "));  out.print(soilRaw);
  out.print(F(", DO="));    out.print(soilDoDry ? F("dry") : F("wet"));
  out.print(F(")  Level=")); out.print(LV_NAME[level]);
  out.print(F("  AI="));
  if (aiActive()) out.print(DZ_NAME[aiDisease]);
  else if (aiHealthyActive()) out.print(F("HEALTHY"));
  else out.print(DZ_NAME[DZ_NONE]);
  out.print(F("  Risk="));  out.print(DZ_NAME[riskDisease]);
  if (sensorFault) out.print(F("  DHT11 FAULT"));
  out.println();
}

// --------------------------- Commands ------------------------------
void setAi(uint8_t dz, Stream &out, bool healthyResult = false) {
  aiDisease = dz;
  aiHealthy = healthyResult;
  aiStart = millis();
  evaluate(millis());
  out.print(F("OK AI="));
  out.println(DZ_NAME[dz]);
}

void processCommand(const char *cmd, Stream &out) {
  if (!strcmp(cmd, "BLAST")) {
    setAi(DZ_BLAST, out);
  } else if (!strcmp(cmd, "BROWNSPOT")) {
    setAi(DZ_BROWN, out);
  } else if (!strcmp(cmd, "BLB")) {
    setAi(DZ_BLB, out);
  } else if (!strcmp(cmd, "HEALTHY")) {
    setAi(DZ_NONE, out, true);
  } else if (!strcmp(cmd, "CLEAR")) {
    setAi(DZ_NONE, out);
  } else if (!strcmp(cmd, "MUTE")) {
    muted = true;
    out.println(F("OK MUTED"));
  } else if (!strcmp(cmd, "UNMUTE")) {
    muted = false;
    out.println(F("OK UNMUTED"));
  } else if (!strcmp(cmd, "STATUS")) {
    sendTelemetry(out);
  } else if (!strcmp(cmd, "TEST")) {
    selfTest();
    out.println(F("OK TEST"));
  } else if (!strcmp(cmd, "CALDRY")) {
    calib.dryRaw = readSoilRaw();
    saveCalibration();
    out.print(F("OK DRY="));
    out.println(calib.dryRaw);
  } else if (!strcmp(cmd, "CALWET")) {
    calib.wetRaw = readSoilRaw();
    saveCalibration();
    out.print(F("OK WET="));
    out.println(calib.wetRaw);
  } else if (!strcmp(cmd, "HELP")) {
    out.println(F("BLAST BROWNSPOT BLB HEALTHY MUTE UNMUTE STATUS TEST CALDRY CALWET"));
  } else {
    out.println(F("ERR unknown command, send HELP"));
  }
}

// Collects characters until a line ends. Returns true when a full line
// is waiting in buf.
bool readLine(Stream &port, char *buf, uint8_t &len, uint8_t cap) {
  while (port.available()) {
    char c = (char)port.read();
    if (c == '\r' || c == '\n') {
      if (len == 0) continue;
      buf[len] = '\0';
      len = 0;
      return true;
    }
    if (len < cap - 1) buf[len++] = (char)toupper((unsigned char)c);
  }
  return false;
}

// ------------------------- Arduino entry ---------------------------
void setup() {
  pinMode(PIN_LED_R, OUTPUT);
  pinMode(PIN_LED_G, OUTPUT);
  pinMode(PIN_LED_B, OUTPUT);
  pinMode(PIN_BUZZER, OUTPUT);
  buzzerWrite(false);        // buzzer off at start
  pinMode(PIN_SOIL_PWR, OUTPUT);
  pinMode(PIN_SOIL_DO, INPUT);
  digitalWrite(PIN_SOIL_PWR, LOW);

  Serial.begin(9600);        // USB monitor
  btSerial.begin(9600);      // HC-05 default data baud rate
  dht.begin();
  loadCalibration();

  Serial.println(F("PaddyGuard starting"));
  selfTest();
  delay(1500);               // DHT11 warm-up
}

void loop() {
  unsigned long now = millis();

  if (readLine(btSerial, btBuf, btLen, sizeof(btBuf))) processCommand(btBuf, btSerial);
  if (readLine(Serial, usbBuf, usbLen, sizeof(usbBuf))) processCommand(usbBuf, Serial);

  if (firstSample || now - lastSample >= SAMPLE_MS) {
    firstSample = false;
    lastSample = now;
    readSensors();
    updateRisk();
    evaluate(now);
    sendTelemetry(btSerial);
    printReadable(Serial);
  }

  updateOutputs(now);
}
