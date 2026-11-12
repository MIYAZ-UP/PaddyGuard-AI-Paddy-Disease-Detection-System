// PaddyGuard phone app
// Camera -> AI leaf analysis -> Bluetooth (HC-05) -> Arduino decision system.
// Keep the phone on a tripod with the screen on (the app holds a wakelock).

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:bluetooth_serial_next/bluetooth_serial_next.dart';
import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

void main() => runApp(const PaddyGuardApp());

class PaddyGuardApp extends StatelessWidget {
  const PaddyGuardApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'PADDY GUARD',
    theme: ThemeData(colorSchemeSeed: Colors.green, useMaterial3: true),
    home: const HomePage(),
  );
}

// ----------------------------------------------------------------------
// Roboflow hosted image classification. The rest of the app only needs
// classify() to return BLAST, BROWNSPOT, BLB, HEALTHY or UNKNOWN.
// ----------------------------------------------------------------------
class LeafClassifier {
  LeafClassifier(this.apiKey, this.modelId);
  final String apiKey;
  final String modelId;
  String lastRawClassLabel = 'not provided';
  String lastPredictionSummary = '';

  static const labels = {'BLAST', 'BROWNSPOT', 'BLB', 'HEALTHY'};

  static String _mapClass(String value) {
    final name = value.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    if (name.contains('blast')) return 'BLAST';
    if (name.contains('brownspot')) return 'BROWNSPOT';
    if ((name.contains('bacterial') && name.contains('blight')) ||
        name.contains('leafblight') ||
        name == 'blb') {
      return 'BLB';
    }
    if (name.contains('healthy') ||
        name == 'normal' ||
        name == 'good' ||
        name == 'nodisease' ||
        name == 'noissue') {
      return 'HEALTHY';
    }
    return 'UNKNOWN';
  }

  static String? _classFromItem(dynamic item) {
    if (item is! Map<String, dynamic>) return null;
    final name =
        item['class'] ??
        item['class_name'] ??
        item['class_label'] ??
        item['predicted_class'] ??
        item['label'] ??
        item['name'];
    return name is String ? _mapClass(name) : null;
  }

  static String? _bestClassFromScores(Map<dynamic, dynamic> scores) {
    final ranked =
        scores.entries
            .where((entry) => entry.key is String && entry.value is num)
            .toList()
          ..sort((a, b) => (b.value as num).compareTo(a.value as num));
    return ranked.isEmpty ? null : _mapClass(ranked.first.key as String);
  }

  String? _aggregateClassPredictions(List<dynamic> predictions) {
    final totals = <String, double>{};
    for (final prediction in predictions) {
      final label = _classFromItem(prediction);
      if (label == null || label == 'UNKNOWN') continue;
      final item = prediction as Map<String, dynamic>;
      final confidence = item['confidence'];
      final score = confidence is num ? confidence.toDouble() : 1.0;
      totals.update(label, (value) => value + score, ifAbsent: () => score);
    }
    if (totals.isEmpty) return null;
    final ranked = totals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    lastPredictionSummary = ranked
        .take(4)
        .map((entry) => '${entry.key} ${entry.value.toStringAsFixed(2)}')
        .join(', ');
    return ranked.first.key;
  }

  static String _findRawClass(dynamic value) {
    if (value is Map) {
      for (final key in [
        'class',
        'class_name',
        'class_label',
        'predicted_class',
        'top_class',
        'label',
        'name',
        'top',
      ]) {
        final candidate = value[key];
        if (candidate is String) return candidate;
      }
      for (final key in [
        'prediction',
        'predictions',
        'predicted_classes',
        'classification',
        'classifications',
        'result',
        'results',
        'output',
      ]) {
        if (value.containsKey(key)) {
          final found = _findRawClass(value[key]);
          if (found != 'not provided') return found;
        }
      }
      final scored =
          value.entries
              .where((entry) => entry.key is String && entry.value is num)
              .toList()
            ..sort((a, b) => (b.value as num).compareTo(a.value as num));
      if (scored.isNotEmpty) return scored.first.key as String;
    } else if (value is List) {
      for (final item in value) {
        final found = _findRawClass(item);
        if (found != 'not provided') return found;
      }
    } else if (value is String) {
      return value;
    }
    return 'not provided';
  }

  Future<String> classify(Uint8List jpeg) async {
    final parts = modelId.trim().split('/');
    if (parts.length != 2 || parts.any((part) => part.isEmpty)) {
      throw 'Model ID must look like project-name/1';
    }
    final uri = Uri.https(
      'serverless.roboflow.com',
      '/${parts[0]}/${parts[1]}',
    );
    final res = await http
        .post(
          uri,
          headers: {
            'content-type': 'application/x-www-form-urlencoded',
            'authorization': 'Bearer $apiKey',
          },
          body: base64Encode(jpeg),
        )
        .timeout(const Duration(seconds: 60));

    if (res.statusCode != 200) {
      throw 'Roboflow request failed (${res.statusCode})';
    }
    final data = jsonDecode(res.body) as Map<String, dynamic>;
    lastRawClassLabel = _findRawClass(data);
    final rawPredictions = data['predictions'];
    if (rawPredictions is Map<String, dynamic>) {
      final directClass = _classFromItem(rawPredictions);
      if (directClass != null && directClass != 'UNKNOWN') return directClass;
      final top = rawPredictions['top'] ?? rawPredictions['prediction'];
      if (top is String) {
        final mapped = _mapClass(top);
        if (mapped != 'UNKNOWN') return mapped;
      }
      final topClass = _classFromItem(top);
      if (topClass != null && topClass != 'UNKNOWN') return topClass;
      final nested = rawPredictions['predictions'];
      if (nested is List && nested.isNotEmpty) {
        final aggregated = _aggregateClassPredictions(nested);
        if (aggregated != null) return aggregated;
        final ranked = nested.whereType<Map<String, dynamic>>().toList()
          ..sort(
            (a, b) => ((b['confidence'] as num?) ?? 0).compareTo(
              (a['confidence'] as num?) ?? 0,
            ),
          );
        final found = ranked.isEmpty ? null : _classFromItem(ranked.first);
        if (found != null && found != 'UNKNOWN') return found;
      } else if (nested is Map) {
        final found = _classFromItem(nested);
        if (found != null && found != 'UNKNOWN') return found;
        final scored = _bestClassFromScores(nested);
        if (scored != null && scored != 'UNKNOWN') return scored;
      }
      final scored = _bestClassFromScores(rawPredictions);
      if (scored != null && scored != 'UNKNOWN') return scored;
    } else if (rawPredictions is List && rawPredictions.isNotEmpty) {
      final firstString = rawPredictions.whereType<String>().firstOrNull;
      if (firstString != null) {
        final mapped = _mapClass(firstString);
        if (mapped != 'UNKNOWN') return mapped;
      }
      final aggregated = _aggregateClassPredictions(rawPredictions);
      if (aggregated != null && aggregated != 'UNKNOWN') return aggregated;
      final ranked = rawPredictions.whereType<Map<String, dynamic>>().toList()
        ..sort(
          (a, b) => ((b['confidence'] as num?) ?? 0).compareTo(
            (a['confidence'] as num?) ?? 0,
          ),
        );
      if (ranked.isNotEmpty) {
        final found = _classFromItem(ranked.first);
        if (found != null && found != 'UNKNOWN') return found;
      }
    }
    final topLevel = data['top'] ?? data['class'] ?? data['class_name'];
    if (topLevel is String) {
      final mapped = _mapClass(topLevel);
      if (mapped != 'UNKNOWN') return mapped;
    }
    final predictedClasses = data['predicted_classes'];
    if (predictedClasses is List && predictedClasses.isNotEmpty) {
      final first = predictedClasses.first;
      if (first is String) {
        final mapped = _mapClass(first);
        if (mapped != 'UNKNOWN') return mapped;
      }
    }
    final fallbackClass = _mapClass(lastRawClassLabel);
    if (fallbackClass != 'UNKNOWN') return fallbackClass;
    return 'UNKNOWN';
  }
}

// ----------------------------------------------------------------------
class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const levelNames = ['SAFE', 'WATCH', 'HIGH', 'DISEASE'];
  static const levelColors = [
    Colors.green,
    Colors.blue,
    Colors.orange,
    Colors.red,
  ];

  final _bt = BluetoothSerial.instance;
  BluetoothSerialPort? _port;
  StreamSubscription<String>? _lineSub;
  List<BluetoothSerialDevice> _devices = [];
  BluetoothSerialDevice? _selected;
  bool _connecting = false;

  CameraController? _cam;
  List<CameraDescription> _backCameras = [];
  CameraDescription? _selectedCamera;
  bool _switchingCamera = false;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _zoom = 1.0;
  bool _zoomBusy = false;
  Timer? _timer;
  bool _monitoring = false;
  bool _busy = false;
  bool _blinkOn = true;
  bool _sensorFault = false;
  bool _muted = false;
  String _arduinoAi = 'NONE';
  Timer? _blinkTimer;
  Timer? _greenBlinkTimer;
  bool _greenBlinkOn = true;
  int _intervalMin = 5;

  final _keyCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  String _lastLabel = '-';
  DateTime? _lastTime;

  double? _temp, _hum;
  int? _soil, _level;
  String _weatherRisk = '-';

  final List<String> _log = [];

  @override
  void initState() {
    super.initState();
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (mounted) setState(() => _blinkOn = !_blinkOn);
    });
    _greenBlinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _greenBlinkOn = !_greenBlinkOn);
    });
    _init();
  }

  Future<void> _init() async {
    final prefs = await SharedPreferences.getInstance();
    _keyCtrl.text = prefs.getString('apiKey') ?? '';
    _modelCtrl.text =
        prefs.getString('modelId') ?? 'rice-leaf-diseases-detection-m7knr/3';
    _intervalMin = prefs.getInt('intervalMin') ?? 5;
    await _loadDevices();
    await _initCamera();
    if (mounted) setState(() {});
  }

  Future<void> _loadDevices() async {
    try {
      if (!await _bt.requestPermissions()) {
        _addLog('Bluetooth permission denied');
        return;
      }
      _devices = await _bt.bondedDevices();
      for (final d in _devices) {
        if ((d.name ?? '').toUpperCase().contains('HC-05')) _selected = d;
      }
      _selected ??= _devices.isNotEmpty ? _devices.first : null;
      if (_devices.isEmpty) {
        _addLog(
          'No paired devices. Pair the HC-05 in Android settings (PIN 1234 or 0000).',
        );
      }
    } catch (e) {
      _addLog('Bluetooth error: $e');
    }
  }

  Future<void> _initCamera() async {
    try {
      final cams = await availableCameras();
      if (cams.isEmpty) {
        _addLog('No camera found');
        return;
      }
      _backCameras = cams
          .where((c) => c.lensDirection == CameraLensDirection.back)
          .toList();
      final initialCamera = _backCameras.isNotEmpty
          ? _backCameras.first
          : cams.first;
      await _switchCamera(initialCamera);
    } catch (e) {
      _addLog('Camera error: $e');
    }
  }

  Future<void> _switchCamera(CameraDescription description) async {
    if (_switchingCamera) return;
    setState(() => _switchingCamera = true);
    final previous = _cam;
    _cam = null;
    try {
      await previous?.dispose();
      final cam = CameraController(
        description,
        ResolutionPreset.high,
        enableAudio: false,
      );
      await cam.initialize();
      var minZoom = 1.0;
      var maxZoom = 1.0;
      try {
        minZoom = await cam.getMinZoomLevel();
        maxZoom = await cam.getMaxZoomLevel();
      } catch (_) {
        // Keep the preview available on cameras that don't report zoom bounds.
      }
      if (!mounted) {
        await cam.dispose();
        return;
      }
      setState(() {
        _cam = cam;
        _selectedCamera = description;
        _minZoom = minZoom > 0.6 ? minZoom : 0.6;
        _maxZoom = maxZoom < _minZoom ? _minZoom : maxZoom;
        _zoom = 1.0.clamp(_minZoom, _maxZoom).toDouble();
      });
    } catch (e) {
      _addLog('Camera switch failed: $e');
    } finally {
      if (mounted) setState(() => _switchingCamera = false);
    }
  }

  String _cameraLabel(CameraDescription camera, int index) {
    final name = camera.name.toLowerCase();
    if (name.contains('ultra')) return 'Ultra-wide';
    if (name.contains('wide')) return 'Wide';
    return 'Back lens ${index + 1}';
  }

  Future<void> _adjustZoom(double change) async {
    final cam = _cam;
    if (cam == null || _zoomBusy) return;
    final next = (_zoom + change).clamp(_minZoom, _maxZoom).toDouble();
    if ((next - _zoom).abs() < 0.001) return;
    setState(() => _zoomBusy = true);
    try {
      await cam.setZoomLevel(next);
      if (mounted) setState(() => _zoom = next);
    } catch (e) {
      _addLog('Camera zoom unavailable: $e');
    } finally {
      if (mounted) setState(() => _zoomBusy = false);
    }
  }

  // ------------------------- Bluetooth ------------------------------
  Future<void> _connect() async {
    final d = _selected;
    if (d == null || _connecting) return;
    setState(() => _connecting = true);
    try {
      if (!await _bt.requestEnable()) throw 'Bluetooth is off';
      final port = await _bt.open(d.address);
      _port = port;
      _lineSub = port.lines().listen(
        _onLine,
        onError: (e) {
          _addLog('Bluetooth lost: $e');
          _dropPort();
        },
        onDone: _dropPort,
      );
      _addLog('Connected to ${d.name ?? d.address}');
    } catch (e) {
      _addLog('Connect failed: $e');
    }
    if (mounted) setState(() => _connecting = false);
  }

  void _dropPort() {
    _lineSub?.cancel();
    _lineSub = null;
    _port = null;
    if (mounted) setState(() {});
  }

  Future<void> _disconnect() async {
    try {
      await _port?.close();
    } catch (_) {}
    _dropPort();
    _addLog('Disconnected');
  }

  void _onLine(String raw) {
    final line = raw.trim();
    if (line.isEmpty) return;
    // PG,temp_C,humidity_%,soil_%,level,ai,risk,fault,muted
    if (line.startsWith('PG,')) {
      final p = line.split(',');
      if (p.length >= 5) {
        setState(() {
          _temp = double.tryParse(p[1]);
          _hum = double.tryParse(p[2]);
          _soil = int.tryParse(p[3]);
          _level = int.tryParse(p[4]);
          if (p.length >= 6) _arduinoAi = p[5];
          if (p.length >= 7) _weatherRisk = p[6];
          if (p.length >= 8) _sensorFault = p[7] == '1';
          if (p.length >= 9) _muted = p[8] == '1';
        });
      }
    } else {
      _addLog('Arduino: $line');
    }
  }

  // --------------------- Capture + analyse + send -------------------
  Future<void> _cycle() async {
    if (_busy) return;
    _busy = true;
    if (mounted) setState(() {});
    try {
      if (_keyCtrl.text.trim().isEmpty) throw 'Enter the API key first';
      if (_modelCtrl.text.trim().isEmpty) throw 'Enter the Roboflow model ID';

      final cam = _cam;
      if (cam == null || !cam.value.isInitialized) throw 'Camera not ready';
      final shot = await cam.takePicture();
      final bytes = await shot.readAsBytes();
      _addLog('Analysing leaf...');
      final classifier = LeafClassifier(
        _keyCtrl.text.trim(),
        _modelCtrl.text.trim(),
      );
      final label = await classifier.classify(bytes);

      setState(() {
        _lastLabel = label;
        _lastTime = DateTime.now();
      });

      if (label == 'UNKNOWN') {
        _addLog('Could not identify this leaf. Nothing sent to Arduino.');
      } else {
        if (classifier.lastPredictionSummary.isNotEmpty) {
          _addLog(
            'Model class confidence totals: ${classifier.lastPredictionSummary}',
          );
        }
      }
      if (label != 'UNKNOWN' && _port == null) {
        _addLog('Result $label, but Bluetooth is not connected');
        unawaited(_connect());
      } else if (label != 'UNKNOWN') {
        await _port!.writeText('$label\n');
        _addLog('Sent $label to Arduino');
      }
    } catch (e) {
      _addLog('Error: $e');
    } finally {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _clearAiResult() async {
    setState(() {
      _lastLabel = '-';
      _lastTime = null;
      _arduinoAi = 'NONE';
    });
    if (_port != null) {
      try {
        await _port!.writeText('CLEAR\n');
      } catch (e) {
        _addLog('Could not clear Arduino AI result: $e');
      }
    }
    _addLog('AI result cleared');
  }

  Future<void> _startMonitoring() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('apiKey', _keyCtrl.text.trim());
    await prefs.setString('modelId', _modelCtrl.text.trim());
    await prefs.setInt('intervalMin', _intervalMin);
    await WakelockPlus.enable();
    _timer?.cancel();
    _timer = Timer.periodic(Duration(minutes: _intervalMin), (_) => _cycle());
    setState(() => _monitoring = true);
    _addLog('Monitoring every $_intervalMin min');
    unawaited(_cycle());
  }

  Future<void> _stopMonitoring() async {
    _timer?.cancel();
    _timer = null;
    await WakelockPlus.disable();
    setState(() => _monitoring = false);
    _addLog('Monitoring stopped');
  }

  void _addLog(String s) {
    final t = TimeOfDay.now();
    final stamp =
        '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    _log.insert(0, '$stamp  $s');
    if (_log.length > 40) _log.removeLast();
    if (mounted) setState(() {});
  }

  String _humidityGuidance() {
    final humidity = _hum;
    if (humidity == null) return 'Waiting for Arduino reading.';
    if (humidity < 50) {
      return 'Very bad: below 50% in the growing-conditions chart.';
    }
    if (humidity < 70) {
      return 'Moderate: 50–69% in the growing-conditions chart.';
    }
    if (humidity <= 90) {
      return 'Good: 70–90% in the growing-conditions chart.';
    }
    if (humidity <= 95) {
      return 'Moderate: 91–95% in the growing-conditions chart.';
    }
    return 'Very bad: above 95% in the growing-conditions chart.';
  }

  String _soilMoistureGuidance() {
    final moisture = _soil;
    if (moisture == null) return 'Waiting for Arduino reading.';
    if (moisture < 20) {
      return 'Below 20%: dry-soil alert; also below the chart’s <40% very-bad soil band.';
    }
    if (moisture >= 90) {
      return 'Near-flooded reading. Paddy probes may read close to 100%; this is good soil moisture in the chart.';
    }
    if (moisture >= 70) {
      return 'Good: 70–100% in the growing-conditions chart.';
    }
    if (moisture >= 40) {
      return 'Moderate: 40–69% in the growing-conditions chart.';
    }
    return 'Very bad: below 40% in the growing-conditions chart.';
  }

  String _condition(
    double? value,
    double goodMin,
    double goodMax,
    double moderateMin,
    double moderateMax,
  ) {
    if (value == null) return 'Waiting';
    if (value >= goodMin && value <= goodMax) return 'Good';
    if (value >= moderateMin && value <= moderateMax) return 'Moderate';
    return 'Very bad';
  }

  String _temperatureCondition() {
    final value = _temp;
    if (value == null) return 'Waiting';
    if (value >= 25 && value <= 35) return 'Good';
    if ((value >= 20 && value < 25) || (value > 35 && value <= 40)) {
      return 'Moderate';
    }
    // The reference chart leaves 15–19°C unclassified; flag it as moderate.
    if (value >= 15 && value < 20) {
      return 'Moderate';
    }
    return 'Very bad';
  }

  String _overallCondition() {
    if (_temp == null || _hum == null || _soil == null) {
      return 'Waiting for readings';
    }
    final bands = [
      _temperatureCondition(),
      _condition(_hum, 70, 90, 50, 95),
      _soil! >= 70 ? 'Good' : (_soil! >= 40 ? 'Moderate' : 'Very bad'),
    ];
    if (bands.contains('Very bad')) return 'Very bad';
    if (bands.contains('Moderate')) return 'Moderate';
    return 'Good';
  }

  Color _conditionColor(String band) => band == 'Good'
      ? Colors.green
      : (band == 'Moderate'
            ? Colors.deepOrange
            : (band.startsWith('Waiting') ? Colors.grey : Colors.red));

  String _riskName(String risk) => switch (risk) {
    'BLAST' => 'Rice blast',
    'BROWNSPOT' => 'Brown spot',
    'BLB' => 'Bacterial leaf blight',
    'NONE' => 'None',
    '-' => 'Waiting for Arduino',
    _ => risk,
  };

  Widget _conditionRow(String title, String band) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      children: [
        Expanded(child: Text(title)),
        Text(
          band,
          style: TextStyle(
            color: band == 'Waiting' ? null : _conditionColor(band),
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    ),
  );

  Widget _rgbIndicator(
    String name,
    Color color,
    bool active, {
    bool blink = false,
  }) {
    final blinkOn = name == 'Green' ? _greenBlinkOn : _blinkOn;
    final visible = active && (!blink || blinkOn);
    return Expanded(
      child: Column(
        children: [
          AnimatedOpacity(
            opacity: visible ? 1 : 0.18,
            duration: const Duration(milliseconds: 120),
            child: Container(
              width: 30,
              height: 30,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: visible
                    ? [
                        BoxShadow(
                          color: color.withValues(alpha: 0.6),
                          blurRadius: 10,
                        ),
                      ]
                    : null,
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(name),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _timer?.cancel();
    _blinkTimer?.cancel();
    _greenBlinkTimer?.cancel();
    _lineSub?.cancel();
    _port?.close();
    _cam?.dispose();
    _keyCtrl.dispose();
    _modelCtrl.dispose();
    WakelockPlus.disable();
    super.dispose();
  }

  // ----------------------------- UI ---------------------------------
  @override
  Widget build(BuildContext context) {
    final connected = _port != null;
    final lvl = _level;
    final lvlColor = (lvl != null && lvl >= 0 && lvl < 4)
        ? levelColors[lvl]
        : Colors.grey;
    final disease =
        _lastLabel != '-' && _lastLabel != 'HEALTHY' && _lastLabel != 'UNKNOWN';
    final goodLeafWithEnoughMoisture =
        _lastLabel == 'HEALTHY' && (_soil ?? 0) > 65;
    final displayedLabel = _lastLabel == 'HEALTHY' ? 'Good leaf' : _lastLabel;
    final resultSubtitle = _lastTime == null
        ? 'No leaf analysed yet'
        : 'at ${_lastTime!.hour.toString().padLeft(2, '0')}:${_lastTime!.minute.toString().padLeft(2, '0')}';
    final weatherRiskText = _weatherRisk == '-'
        ? 'Waiting for Arduino'
        : _riskName(_weatherRisk);
    final statusKnown = lvl != null && lvl >= 0 && lvl < 4;
    final greenActive = statusKnown && lvl == 0 && !_sensorFault;
    final blueActive = statusKnown && (lvl == 1 || (_sensorFault && lvl != 3));
    final redActive = statusKnown && (lvl == 3 || (lvl == 2 && !_sensorFault));
    final anyBlink = _sensorFault || lvl == 2 || lvl == 3;
    final buzzerActive =
        statusKnown && (lvl == 3 || (lvl == 2 && !_sensorFault)) && !_muted;
    final buzzerStatus = _muted
        ? 'Muted'
        : (!buzzerActive
              ? 'OFF'
              : (lvl == 3
                    ? 'Continuous buzzer'
                    : '150 ms beep every 2 seconds'));

    return Scaffold(
      appBar: AppBar(title: const Text('PADDY GUARD')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '1. Bluetooth (HC-05)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  DropdownButton<BluetoothSerialDevice>(
                    isExpanded: true,
                    value: _selected,
                    hint: const Text('Select paired device'),
                    items: [
                      for (final d in _devices)
                        DropdownMenuItem(
                          value: d,
                          child: Text(d.name ?? d.address),
                        ),
                    ],
                    onChanged: connected
                        ? null
                        : (d) => setState(() => _selected = d),
                  ),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: _connecting
                            ? null
                            : (connected ? _disconnect : _connect),
                        child: Text(
                          _connecting
                              ? 'Connecting...'
                              : (connected ? 'Disconnect' : 'Connect'),
                        ),
                      ),
                      const SizedBox(width: 8),
                      TextButton(
                        onPressed: _loadDevices,
                        child: const Text('Refresh list'),
                      ),
                      const Spacer(),
                      Icon(
                        Icons.circle,
                        size: 14,
                        color: connected ? Colors.green : Colors.grey,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '2. Leaf camera and AI',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  if (_cam != null && _cam!.value.isInitialized)
                    ClipRRect(
                      borderRadius: BorderRadius.circular(8),
                      child: SizedBox(
                        height: 220,
                        width: double.infinity,
                        child: FittedBox(
                          fit: BoxFit.cover,
                          child: SizedBox(
                            width: _cam!.value.previewSize?.height ?? 300,
                            height: _cam!.value.previewSize?.width ?? 400,
                            child: CameraPreview(_cam!),
                          ),
                        ),
                      ),
                    )
                  else
                    const SizedBox(
                      height: 80,
                      child: Center(child: Text('Camera not ready')),
                    ),
                  if (_backCameras.length > 1) ...[
                    const SizedBox(height: 4),
                    InputDecorator(
                      decoration: const InputDecoration(
                        labelText: 'Camera lens',
                        helperText: 'Try another back lens for ultra-wide.',
                        isDense: true,
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          isExpanded: true,
                          value: _selectedCamera?.name,
                          items: [
                            for (var i = 0; i < _backCameras.length; i++)
                              DropdownMenuItem(
                                value: _backCameras[i].name,
                                child: Text(_cameraLabel(_backCameras[i], i)),
                              ),
                          ],
                          onChanged: _switchingCamera
                              ? null
                              : (name) {
                                  if (name == null) return;
                                  final camera = _backCameras.firstWhere(
                                    (item) => item.name == name,
                                  );
                                  unawaited(_switchCamera(camera));
                                },
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  if (_cam != null && _cam!.value.isInitialized)
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        IconButton(
                          tooltip: 'Zoom out',
                          onPressed:
                              _zoomBusy ||
                                  _switchingCamera ||
                                  _zoom <= _minZoom + 0.001
                              ? null
                              : () => _adjustZoom(-0.1),
                          icon: const Icon(Icons.remove_circle_outline),
                        ),
                        SizedBox(
                          width: 56,
                          child: Text(
                            '${_zoom.toStringAsFixed(1)}×',
                            textAlign: TextAlign.center,
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Zoom in',
                          onPressed:
                              _zoomBusy ||
                                  _switchingCamera ||
                                  _zoom >= _maxZoom - 0.001
                              ? null
                              : () => _adjustZoom(0.1),
                          icon: const Icon(Icons.add_circle_outline),
                        ),
                      ],
                    ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _keyCtrl,
                    obscureText: true,
                    enabled: !_monitoring,
                    decoration: const InputDecoration(
                      labelText: 'Roboflow API key',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _modelCtrl,
                    enabled: !_monitoring,
                    decoration: const InputDecoration(
                      labelText: 'Roboflow model ID (project/version)',
                      hintText: 'rice-leaf-diseases-detection-m7knr/3',
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      const Text('Every '),
                      SegmentedButton<int>(
                        segments: const [
                          ButtonSegment(value: 5, label: Text('5')),
                          ButtonSegment(value: 7, label: Text('7')),
                          ButtonSegment(value: 9, label: Text('9')),
                        ],
                        selected: {_intervalMin},
                        onSelectionChanged: _monitoring
                            ? null
                            : (s) => setState(() => _intervalMin = s.first),
                      ),
                      const Text(' min'),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      FilledButton(
                        onPressed: _monitoring
                            ? _stopMonitoring
                            : _startMonitoring,
                        child: Text(
                          _monitoring ? 'Stop monitoring' : 'Start monitoring',
                        ),
                      ),
                      const SizedBox(width: 8),
                      OutlinedButton(
                        onPressed: _busy ? null : _cycle,
                        child: Text(_busy ? 'Working...' : 'Analyse now'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            color: disease
                ? Colors.red.shade50
                : (goodLeafWithEnoughMoisture ? Colors.green.shade50 : null),
            child: ListTile(
              title: Text(
                'AI result: $displayedLabel',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
              subtitle: Text(resultSubtitle),
              trailing: IconButton(
                tooltip: 'Clear AI result',
                onPressed: _lastLabel == '-' ? null : _clearAiResult,
                icon: const Icon(Icons.clear),
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '3. Field readings (from Arduino)',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text('Temperature: ${_temp?.toStringAsFixed(1) ?? '-'} °C'),
                  _conditionRow(
                    'Temperature condition',
                    _temperatureCondition(),
                  ),
                  Text(
                    'Relative humidity: ${_hum?.toStringAsFixed(0) ?? '-'} %',
                  ),
                  _conditionRow(
                    'Humidity condition',
                    _condition(_hum, 70, 90, 50, 95),
                  ),
                  Text(
                    'Humidity guide: ${_humidityGuidance()}',
                    style: TextStyle(
                      color: _hum == null
                          ? null
                          : _conditionColor(_condition(_hum, 70, 90, 50, 95)),
                    ),
                  ),
                  Text('Soil moisture: ${_soil ?? '-'} %'),
                  _conditionRow(
                    'Soil condition',
                    _soil == null
                        ? 'Waiting'
                        : (_soil! >= 70
                              ? 'Good'
                              : (_soil! >= 40 ? 'Moderate' : 'Very bad')),
                  ),
                  Text(
                    'Paddy soil: ${_soilMoistureGuidance()}',
                    style: TextStyle(
                      color: _soil == null
                          ? null
                          : _conditionColor(
                              _soil! >= 70
                                  ? 'Good'
                                  : (_soil! >= 40 ? 'Moderate' : 'Very bad'),
                            ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Arduino weather risk: $weatherRiskText',
                    style: TextStyle(
                      color: _weatherRisk != '-' && _weatherRisk != 'NONE'
                          ? Colors.deepOrange.shade800
                          : null,
                      fontWeight: _weatherRisk != '-' && _weatherRisk != 'NONE'
                          ? FontWeight.w600
                          : null,
                    ),
                  ),
                  const Divider(height: 20),
                  Text(
                    'Overall paddy condition: ${_overallCondition()}',
                    style: TextStyle(
                      fontWeight: FontWeight.bold,
                      color: _conditionColor(_overallCondition()),
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text('Arduino RGB status (shown on screen)'),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      _rgbIndicator(
                        'Red',
                        Colors.red,
                        redActive,
                        blink: anyBlink && redActive,
                      ),
                      _rgbIndicator(
                        'Green',
                        Colors.green,
                        greenActive,
                        blink: greenActive && _arduinoAi != 'HEALTHY',
                      ),
                      _rgbIndicator(
                        'Blue',
                        Colors.blue,
                        blueActive,
                        blink: anyBlink && blueActive,
                      ),
                    ],
                  ),
                  Row(
                    children: [
                      Icon(
                        Icons.volume_up,
                        color: buzzerActive ? Colors.red : Colors.grey,
                      ),
                      const SizedBox(width: 6),
                      Text('Arduino buzzer: $buzzerStatus'),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Chip(
                    backgroundColor: lvlColor.withValues(alpha: 0.15),
                    label: Text(
                      'Level: ${(lvl != null && lvl >= 0 && lvl < 4) ? levelNames[lvl] : '-'}',
                      style: TextStyle(
                        color: lvlColor,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  Wrap(
                    spacing: 4,
                    children: [
                      TextButton(
                        onPressed: connected
                            ? () => _port!.writeText(
                                _muted ? 'UNMUTE\n' : 'MUTE\n',
                              )
                            : null,
                        child: Text(_muted ? 'Unmute buzzer' : 'Mute buzzer'),
                      ),
                      TextButton(
                        onPressed: connected
                            ? () => _port!.writeText('TEST\n')
                            : null,
                        child: const Text('Test buzzer and LEDs'),
                      ),
                      TextButton(
                        onPressed: connected ? _clearAiResult : null,
                        child: const Text('Clear alert'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Log',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 6),
                  for (final l in _log.take(12))
                    Text(l, style: const TextStyle(fontSize: 12)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
