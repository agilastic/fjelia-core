import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:fjelia_data/database.dart';
import 'package:fjelia_data/sync.dart';
import 'package:fjelia_views/fjelia_views.dart';
import 'package:test/test.dart';

void main() {
  late AppDatabase db;
  setUp(() async {
    db = AppDatabase(NativeDatabase.memory());
    await db.installSync();
  });
  tearDown(() => db.close());

  Future<void> recording(String id) => db
      .into(db.ecgRecordings)
      .insert(
        EcgRecordingsCompanion.insert(
          recordingId: id,
          recordedAt: DateTime(2026, 11, 20, 7),
          source: 'polar_h10',
          deviceName: 'Polar H10',
          kind: 'waveform',
          status: 'complete',
          sampleRateHz: const Value(130),
          sampleCount: const Value(130 * 60),
          durationMs: const Value(60000),
        ),
      );

  /// A minute at 60 bpm: a sharp R peak every second on a flat line.
  Future<void> waveform(String id) async {
    for (var s = 0; s < 60; s++) {
      await db
          .into(db.ecgSampleChunks)
          .insert(
            EcgSampleChunksCompanion.insert(
              recordingId: id,
              sequence: s,
              dataJson: jsonEncode(
                EcgChunk(
                  offsetUs: s * 1000000,
                  microvolts: [
                    for (var i = 0; i < 130; i++)
                      i == 30 ? 1500 : (20 * math.sin(i / 10)).round(),
                  ],
                ).toJson(),
              ),
            ),
          );
    }
  }

  test('a waveform is asked for, then read when it arrived', () async {
    await recording('r1');
    expect((await loadEcgDetail(db, 'r1'))!.state, EcgWaveformState.onPhone);

    await db.wantEcgWaveform('r1');
    expect((await loadEcgDetail(db, 'r1'))!.state, EcgWaveformState.requested);
    expect(await db.syncWanted(), {
      'ecg': ['r1'],
    });

    await waveform('r1');
    final detail = (await loadEcgDetail(db, 'r1'))!;
    expect(detail.state, EcgWaveformState.here);
    expect(detail.chunks, hasLength(60));
    expect(detail.seconds, closeTo(60, 1));
    // Arrived: no longer asked for.
    expect(await db.syncWanted(), {'ecg': <String>[]});
  });
}
