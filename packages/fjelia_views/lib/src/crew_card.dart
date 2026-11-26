import 'dart:typed_data';

import 'package:fjelia_core/utils/target_time.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import 'race_course.dart';

/// The crew card's words, in the app's language.
abstract interface class CrewCardTexts {
  String get checkpoint;
  String get km;
  String get upDown;
  String get arrival;
  String get cutoff;
  String get handOver;
  String get finish;
  String start(String time);
  String finishRange(String time, String from, String to);
  String ahead(String time);
  String late(String time);
  String fuel(int carbs, String litres, int sodium);
  String get footer;
}

/// One checkpoint on the crew card: when the runner is due, and what to
/// hand over for the leg after it.
class CrewCardRow {
  const CrewCardRow({
    required this.name,
    required this.km,
    required this.gain,
    required this.loss,
    required this.arrival,
    this.clock,
    this.cutoff,
    this.margin,
    this.handOver,
  });
  final String name;

  /// Kilometres from the start, and the climb and descent of the leg to it.
  final double km, gain, loss;

  /// Elapsed seconds on arrival, and the clock time when the start is known.
  final double arrival;
  final DateTime? clock;
  final DateTime? cutoff;
  final Duration? margin;

  /// Carbohydrate (g), drink (ml) and sodium (mg) for the next leg; null at
  /// the finish or without a fuel plan.
  final ({double carbs, double fluid, double sodium})? handOver;
}

/// The checkpoints of [view]'s plan with the finish; null without a plan.
List<CrewCardRow>? crewCardRows(RaceCourseView view) {
  final plan = view.plan;
  if (plan == null) return null;
  final start = view.startAt;
  var km = 0.0;
  return [
    for (final (i, leg) in plan.legs.indexed)
      CrewCardRow(
        name: leg.leg.to,
        km: km += leg.leg.km,
        gain: leg.leg.gain,
        loss: leg.leg.loss,
        arrival: leg.arrival,
        clock: start?.add(Duration(seconds: leg.arrival.round())),
        cutoff: leg.leg.cutoff(view.course),
        margin: view.marginAt(leg),
        handOver: i + 1 < plan.legs.length
            ? view.fuelFor(plan.legs[i + 1])
            : null,
      ),
  ];
}

/// The crew card as a one-page PDF (A4, landscape when the table is wide):
/// the race, the start, the finish range, and per checkpoint the time the
/// runner is due, the cut-off and margin, and what to hand over. [regular]
/// and [bold] are TrueType fonts that cover the app's languages; [locale]
/// formats the clock times. Null without a plan.
Future<Uint8List?> crewCardPdf(
  RaceCourseView view,
  CrewCardTexts texts, {
  required ByteData regular,
  required ByteData bold,
  String? locale,
}) async {
  final rows = crewCardRows(view);
  final plan = view.plan;
  if (rows == null || plan == null) return null;
  final font = pw.Font.ttf(regular), heavy = pw.Font.ttf(bold);
  final clock = DateFormat('EEE HH:mm', locale);
  final day = DateFormat.yMMMMEEEEd(locale);
  final small = pw.TextStyle(font: font, fontSize: 9, color: PdfColors.grey700);
  final cell = pw.TextStyle(font: font, fontSize: 10);
  final head = pw.TextStyle(font: heavy, fontSize: 9);
  final doc = pw.Document(title: view.goal.name, creator: 'Fjelia');
  doc.addPage(
    pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: const pw.EdgeInsets.all(28),
      build: (_) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(
            view.goal.name,
            style: pw.TextStyle(font: heavy, fontSize: 20),
          ),
          pw.SizedBox(height: 2),
          pw.Text(
            [
              day.format(view.goal.raceDate),
              if (view.startAt case final s?)
                texts.start(DateFormat.Hm(locale).format(s)),
              texts.finishRange(
                formatHoursMinutes(plan.seconds),
                formatHoursMinutes(plan.fastest),
                formatHoursMinutes(plan.slowest),
              ),
            ].join(' · '),
            style: pw.TextStyle(font: font, fontSize: 11),
          ),
          pw.SizedBox(height: 14),
          pw.TableHelper.fromTextArray(
            border: pw.TableBorder(
              horizontalInside: const pw.BorderSide(
                color: PdfColors.grey300,
                width: 0.5,
              ),
              bottom: const pw.BorderSide(color: PdfColors.grey500),
              top: const pw.BorderSide(color: PdfColors.grey500),
            ),
            headerStyle: head,
            cellStyle: cell,
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
            cellAlignments: {
              for (var c = 1; c <= 5; c++) c: pw.Alignment.centerRight,
            },
            headerAlignments: {
              0: pw.Alignment.centerLeft,
              for (var c = 1; c <= 5; c++) c: pw.Alignment.centerRight,
              6: pw.Alignment.centerLeft,
            },
            cellPadding: const pw.EdgeInsets.symmetric(
              horizontal: 5,
              vertical: 4,
            ),
            headers: [
              texts.checkpoint,
              texts.km,
              texts.upDown,
              texts.arrival,
              texts.cutoff,
              '',
              texts.handOver,
            ],
            data: [
              for (final (i, r) in rows.indexed)
                [
                  i == rows.length - 1 ? texts.finish : r.name,
                  r.km.toStringAsFixed(1),
                  '+${r.gain.round()} / −${r.loss.round()}',
                  [
                    if (r.clock case final c?) clock.format(c),
                    formatHoursMinutes(r.arrival),
                  ].join('  '),
                  r.cutoff == null ? '' : clock.format(r.cutoff!.toLocal()),
                  switch (r.margin) {
                    null => '',
                    final m when m.isNegative => texts.late(
                      formatHoursMinutes(-m.inSeconds.toDouble()),
                    ),
                    final m => texts.ahead(
                      formatHoursMinutes(m.inSeconds.toDouble()),
                    ),
                  },
                  switch (r.handOver) {
                    null => '',
                    final f => texts.fuel(
                      f.carbs.round(),
                      (f.fluid / 1000).toStringAsFixed(1),
                      f.sodium.round(),
                    ),
                  },
                ],
            ],
          ),
          pw.Spacer(),
          pw.Text(texts.footer, style: small),
        ],
      ),
    ),
  );
  return doc.save();
}
