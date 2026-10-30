import { describe, expect, it } from 'vitest';
import { scoreAnswer } from '../src/lib/scoring';

describe('scoreAnswer', () => {
  it('awards base marks for a correct response when speed scoring is off', () => {
    expect(scoreAnswer({ marks: 8, answered: true, correct: true })).toEqual({ marksAwarded: 8, speedPoints: 1, totalPoints: 8 });
  });

  it('awards zero for incorrect and unanswered answers by default', () => {
    expect(scoreAnswer({ marks: 8, answered: true, correct: false }).totalPoints).toBe(0);
    expect(scoreAnswer({ marks: 8, answered: false, correct: false })).toEqual({ marksAwarded: 0, speedPoints: 1, totalPoints: 0 });
  });

  it('keeps the speed multiplier between one and ten', () => {
    const fast = scoreAnswer({ marks: 2, answered: true, correct: true, elapsedSeconds: 0, timeLimitSeconds: 30 }, { speedPointsEnabled: true });
    const late = scoreAnswer({ marks: 2, answered: true, correct: true, elapsedSeconds: 30, timeLimitSeconds: 30 }, { speedPointsEnabled: true });
    expect(fast.speedPoints).toBe(10);
    expect(late.speedPoints).toBe(1);
  });

  it('handles zero-duration configuration safely', () => {
    expect(scoreAnswer({ marks: 3, answered: true, correct: true, elapsedSeconds: 0, timeLimitSeconds: 0 }, { speedPointsEnabled: true }).speedPoints).toBe(1);
  });

  it('calculates partial credit and configured negative marks', () => {
    expect(scoreAnswer({ marks: 10, answered: true, correct: false, matchedCorrect: 1, correctCount: 2, wrongSelected: 0, wrongOptionCount: 2 }, { partialMarking: true }).marksAwarded).toBe(5);
    expect(scoreAnswer({ marks: 10, answered: true, correct: false }, { negativeMarkingPercent: 25 }).marksAwarded).toBe(-2.5);
  });

  it('multiplies earned marks by the speed points', () => {
    expect(scoreAnswer({ marks: 4, answered: true, correct: true, elapsedSeconds: 0, timeLimitSeconds: 10 }, { speedPointsEnabled: true })).toEqual({ marksAwarded: 4, speedPoints: 10, totalPoints: 40 });
  });
});
