import 'dart:math';

class DemoPreset {
  final bool smoke;
  final int minutes, people, speed;
  final String intensity, pattern;
  const DemoPreset({
    this.smoke = false,
    this.minutes = 10,
    this.people = 2,
    this.speed = 10,
    this.intensity = 'medium',
    this.pattern = 'staggered',
  });

  Map<String, Object> toStartBody(String device, String id) => {
    'device': device,
    'run_id': id,
    'kind': smoke ? 'smoke' : 'shower',
    'speed': speed,
    if (smoke) ...{
      'people': people,
      'intensity': intensity,
      'pattern': pattern,
    } else
      'minutes': minutes,
  };
}

String newDemoId() {
  final random = Random.secure();
  final bytes = List.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 15) | 64;
  bytes[8] = (bytes[8] & 63) | 128;
  final s = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${s.substring(0, 8)}-${s.substring(8, 12)}-${s.substring(12, 16)}-'
      '${s.substring(16, 20)}-${s.substring(20)}';
}

class DemoSnapshot {
  final String? id, kind, endReason;
  final String phase, pattern;
  final int people, speed, elapsed;
  final int? configVersion;
  final bool finalIdle;
  final num? humidityThreshold, smokeThreshold;

  const DemoSnapshot(
    this.id,
    this.kind,
    this.endReason,
    this.phase,
    this.pattern,
    this.people,
    this.speed,
    this.elapsed, {
    this.configVersion,
    this.finalIdle = false,
    this.humidityThreshold,
    this.smokeThreshold,
  });

  static DemoSnapshot? fromJson(Object? raw) {
    if (raw is! Map<String, dynamic> ||
        raw['v'] != 1 ||
        raw['phase'] is! String) {
      return null;
    }
    return DemoSnapshot(
      raw['run_id'] as String?,
      raw['kind'] as String?,
      raw['end_reason'] as String?,
      raw['phase'] as String,
      raw['pattern'] as String? ?? 'together',
      (raw['people'] as int? ?? 1).clamp(1, 3),
      raw['speed'] as int? ?? 1,
      raw['elapsed_s'] as int? ?? 0,
      configVersion: raw['config_version'] as int?,
      finalIdle: raw['final_idle'] == true,
      humidityThreshold: raw['hum_on'] as num?,
      smokeThreshold: raw['smoke_on'] as num?,
    );
  }

  bool get active => phase != 'idle' && id != null;
  bool get smoke => kind == 'smoke';
  int sourceAge(int index) =>
      elapsed * speed - (pattern == 'staggered' ? index * 30 : 0);
  String get terminalLabel => switch (endReason) {
    'completed' => 'Selesai',
    'stopped' => 'Dihentikan',
    'timeout' => 'Batas waktu',
    'disconnected' => 'Koneksi terputus',
    'physical_alarm' => 'Alarm sensor fisik mengambil alih',
    'sensor_fault' => 'Sensor fisik bermasalah',
    _ => 'Siap',
  };
}

class DemoRequest {
  final String id;
  final bool stop, expired;
  const DemoRequest(this.id, this.stop, {this.expired = false});
}

typedef DemoTrendPoint = ({double? humidity, int? smoke});

/// Observations from one dashboard, not proof of motor speed or precise timers.
class DemoEvidence {
  final String runId;
  final int? configVersion;
  final bool smokeRun;
  int _lastElapsed;
  bool _crossed = false, _response = false, _cleared = false;
  bool _postRun = false, _idle = false, _settled = false;
  String? _missingReason;

  DemoEvidence(DemoSnapshot first)
    : runId = first.id!,
      configVersion = first.configVersion,
      smokeRun = first.smoke,
      _lastElapsed = first.elapsed {
    if (first.elapsed > 5) invalidate('awal skenario tidak terekam');
    if (configVersion == null) {
      invalidate('konfigurasi firmware tidak diketahui');
    }
  }

  void invalidate(String reason) => _missingReason ??= reason;

  void observe(
    DemoSnapshot run, {
    required double? humidity,
    required int? smoke,
    required bool alarm,
    required int? pwm,
    required String? state,
    required bool autoControl,
  }) {
    if (run.elapsed < _lastElapsed || run.elapsed - _lastElapsed > 20) {
      invalidate('ada jeda telemetri');
    }
    _lastElapsed = run.elapsed;
    if (!autoControl) invalidate('kontrol Auto berubah');
    if (configVersion != run.configVersion) invalidate('konfigurasi berubah');
    final threshold = run.smoke ? run.smokeThreshold : run.humidityThreshold;
    final input = run.smoke ? smoke : humidity;
    if (threshold == null || input == null || pwm == null) {
      invalidate('bacaan tidak lengkap');
    }
    if (threshold != null && input != null && input > threshold) {
      _crossed = true;
    }
    if (_crossed && (pwm ?? 0) > 0 && (!run.smoke || alarm)) _response = true;
    if (_response && run.smoke && !alarm) _cleared = true;
    if (_response && state == 'POSTRUN') _postRun = true;
    if (_postRun && state == 'IDLE' && pwm == 0) _idle = true;
    if (run.phase == 'settling') _settled = true;
  }

  String get progress => _response
      ? 'Respons teramati'
      : _crossed
      ? 'Respons belum teramati'
      : 'Menunggu ambang';

  String finish(String? reason, {bool finalIdle = false}) {
    final missing = _missingReason;
    if (reason != 'completed') {
      return 'Tidak dinilai · skenario tidak selesai normal';
    }
    if (missing != null) return 'Tidak dinilai · $missing';
    if (!_crossed) return 'Tidak dinilai · ambang tidak teramati terlintasi';
    if (!_settled) return 'Tidak dinilai · fase akhir tidak terekam';
    if (!_response) return 'Gagal · respons tidak tercapai';
    if (!_postRun || !(_idle || finalIdle) || (smokeRun && !_cleared)) {
      return 'Tidak dinilai · pemulihan tidak terekam';
    }
    return 'Lulus · respons dan pemulihan teramati';
  }
}
