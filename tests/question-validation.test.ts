import { describe, expect, it } from 'vitest';
import { questionImportSchema } from '../src/lib/validation';

const valid = {
  prompt: 'Which planet is known as the Red Planet?',
  options: ['Earth', 'Mars', 'Jupiter', 'Venus'],
  correct_answer: 'Mars',
  points: 10,
};

describe('questionImportSchema', () => {
  it('accepts a valid single select question and supplies defaults', () => {
    expect(questionImportSchema.parse([valid])).toEqual([{
      ...valid,
      type: 'single_select',
      time_limit_seconds: undefined,
    }]);
  });

  it('accepts a multiple select answer set', () => {
    const parsed = questionImportSchema.parse([{ ...valid, type: 'multiple_select', correct_answer: ['Mars', 'Venus'] }]);
    expect(parsed[0].correct_answer).toEqual(['Mars', 'Venus']);
    expect(questionImportSchema.safeParse([{ ...valid, type: 'multiple_select', correct_answer: 'Mars' }]).success).toBe(false);
  });

  it('rejects duplicate option labels and unknown correct answers', () => {
    expect(questionImportSchema.safeParse([{ ...valid, options: ['Mars', 'mars'], correct_answer: 'Mars' }]).success).toBe(false);
    expect(questionImportSchema.safeParse([{ ...valid, correct_answer: 'Saturn' }]).success).toBe(false);
  });

  it('requires exactly True and False options for a true/false item', () => {
    expect(questionImportSchema.safeParse([{ ...valid, type: 'true_false', options: ['True', 'False'], correct_answer: 'True' }]).success).toBe(true);
    expect(questionImportSchema.safeParse([{ ...valid, type: 'true_false', options: ['Yes', 'No'], correct_answer: 'Yes' }]).success).toBe(false);
  });

  it('rejects out of range scores and oversized imports', () => {
    expect(questionImportSchema.safeParse([{ ...valid, points: -1 }]).success).toBe(false);
    expect(questionImportSchema.safeParse(Array.from({ length: 501 }, () => valid)).success).toBe(false);
  });
});
