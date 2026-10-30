export type ScoringRules = {
  speedPointsEnabled?: boolean;
  partialMarking?: boolean;
  negativeMarkingPercent?: number;
};

export type ScoreInput = {
  marks: number;
  answered: boolean;
  correct: boolean;
  elapsedSeconds?: number;
  timeLimitSeconds?: number;
  matchedCorrect?: number;
  correctCount?: number;
  wrongSelected?: number;
  wrongOptionCount?: number;
};

export type ScoreResult = { marksAwarded: number; speedPoints: number; totalPoints: number };

/** Mirrors the trusted submit_answer formula; PostgreSQL remains authoritative. */
export function scoreAnswer(input: ScoreInput, rules: ScoringRules = {}): ScoreResult {
  if (!input.answered) return { marksAwarded: 0, speedPoints: 1, totalPoints: 0 };

  const penalty = Math.min(100, Math.max(0, rules.negativeMarkingPercent || 0));
  let marksAwarded = input.correct ? input.marks : -input.marks * penalty / 100;
  if (!input.correct && rules.partialMarking && (input.correctCount || 0) > 0) {
    const correctCount = input.correctCount || 0;
    const matched = Math.min(correctCount, Math.max(0, input.matchedCorrect || 0));
    const wrongOptions = Math.max(0, input.wrongOptionCount || 0);
    const wrongSelected = Math.max(0, input.wrongSelected || 0);
    marksAwarded = input.marks * Math.max(0, matched / correctCount - (wrongOptions ? wrongSelected / wrongOptions : 0));
  }

  let speedPoints = 1;
  const duration = input.timeLimitSeconds || 0;
  if (rules.speedPointsEnabled && marksAwarded > 0 && duration > 0) {
    const remaining = Math.max(0, duration - Math.max(0, input.elapsedSeconds || 0));
    speedPoints = Math.min(10, Math.max(1, 1 + Math.floor(9 * remaining / duration)));
  }
  marksAwarded = Math.round(marksAwarded * 100) / 100;
  if (Object.is(marksAwarded, -0)) marksAwarded = 0;
  return { marksAwarded, speedPoints, totalPoints: Math.round(marksAwarded * speedPoints * 100) / 100 };
}
