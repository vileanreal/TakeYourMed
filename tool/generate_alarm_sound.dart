import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

const _sampleRate = 22050;
const _durationSeconds = 60;
const _bytesPerSample = 2;
const _cycleSeconds = 2.5;

void main(List<String> arguments) {
  final outputPath = arguments.isEmpty
      ? 'android/app/src/main/res/raw/medicine_alarm.wav'
      : arguments.single;
  final sampleCount = _sampleRate * _durationSeconds;
  final audioBytes = sampleCount * _bytesPerSample;
  final wave = ByteData(44 + audioBytes);

  _writeText(wave, 0, 'RIFF');
  wave.setUint32(4, 36 + audioBytes, Endian.little);
  _writeText(wave, 8, 'WAVE');
  _writeText(wave, 12, 'fmt ');
  wave.setUint32(16, 16, Endian.little);
  wave.setUint16(20, 1, Endian.little);
  wave.setUint16(22, 1, Endian.little);
  wave.setUint32(24, _sampleRate, Endian.little);
  wave.setUint32(28, _sampleRate * _bytesPerSample, Endian.little);
  wave.setUint16(32, _bytesPerSample, Endian.little);
  wave.setUint16(34, 16, Endian.little);
  _writeText(wave, 36, 'data');
  wave.setUint32(40, audioBytes, Endian.little);

  const chimes = <(double, double, double)>[
    (0.00, 0.34, 880.00),
    (0.46, 0.80, 1046.50),
    (0.92, 1.28, 1174.66),
  ];
  for (var index = 0; index < sampleCount; index++) {
    final time = index / _sampleRate;
    final cycleTime = time % _cycleSeconds;
    var sample = 0.0;
    for (final (start, end, frequency) in chimes) {
      if (cycleTime < start || cycleTime >= end) continue;
      final noteTime = cycleTime - start;
      final noteDuration = end - start;
      final attack = math.min(1.0, noteTime / 0.025);
      final release = math.min(1.0, (noteDuration - noteTime) / 0.055);
      final envelope = math.min(attack, release);
      final phase = 2 * math.pi * frequency * noteTime;
      sample = envelope * (0.48 * math.sin(phase) + 0.09 * math.sin(phase * 2));
      break;
    }
    final pcm = (sample.clamp(-1.0, 1.0) * 32767).round();
    wave.setInt16(44 + index * _bytesPerSample, pcm, Endian.little);
  }

  final output = File(outputPath);
  output.parent.createSync(recursive: true);
  output.writeAsBytesSync(wave.buffer.asUint8List(), flush: true);
  stdout.writeln(
    'Generated ${output.path} '
    '(${_durationSeconds}s, ${_sampleRate}Hz, mono PCM)',
  );
}

void _writeText(ByteData target, int offset, String value) {
  for (var index = 0; index < value.length; index++) {
    target.setUint8(offset + index, value.codeUnitAt(index));
  }
}
