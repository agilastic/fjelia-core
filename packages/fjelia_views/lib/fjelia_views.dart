/// What each Fjelia screen shows and when, shared by the mobile and desktop
/// apps: read from the database (`fjelia_data`) and worked out with
/// `fjelia_core`. The apps decide only how and where to render it, and
/// put it into words.
library;

export 'package:fjelia_core/models/ecg.dart' show EcgChunk, ecgDisplayPoints;
export 'package:fjelia_core/models/workout_draft.dart';
export 'package:fjelia_core/services/course/course.dart';
export 'package:fjelia_core/services/course/course_prediction.dart';
export 'package:fjelia_core/services/course/course_profile.dart';
export 'package:fjelia_core/services/course/grade_pace.dart';
export 'package:fjelia_core/services/ecg_analysis.dart'
    show EcgAnalysis, EcgHeartRate, EcgBlock;
export 'package:fjelia_core/services/lactate_test.dart';
export 'package:fjelia_core/services/strength/strength_plan_edits.dart';

export 'src/activities.dart';
export 'src/analysis.dart';
export 'src/calendar.dart';
export 'src/diary.dart';
export 'src/ecg.dart';
export 'src/fuel.dart';
export 'src/gear.dart';
export 'src/health.dart';
export 'src/lab_tests.dart';
export 'src/plan_edits.dart';
export 'src/race_course.dart';
export 'src/roster.dart';
export 'src/season.dart';
export 'src/sport_stats.dart';
export 'src/strength_plans.dart';
export 'src/today.dart';
export 'src/training_load.dart';
