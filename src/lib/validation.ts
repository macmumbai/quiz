import { z } from 'zod';

const questionImportItemSchema = z.object({
  prompt: z.string().trim().min(1).max(2000),
  type: z.enum(['single_select', 'multiple_select', 'true_false']).default('single_select'),
  options: z.array(z.string().trim().min(1)).min(2).max(12),
  correct_answer: z.union([z.string().min(1), z.array(z.string().min(1)).min(1)]),
  points: z.number().min(0).max(100000).default(1),
  time_limit_seconds: z.number().int().min(1).max(3600).nullable().optional(),
}).superRefine((question, ctx) => {
  const normalized = question.options.map(option => option.toLocaleLowerCase());
  if (new Set(normalized).size !== normalized.length) {
    ctx.addIssue({ code: 'custom', message: 'Answer options must be unique.', path: ['options'] });
  }
  if (question.type === 'true_false' && !['true|false', 'false|true'].includes(normalized.slice().sort().join('|'))) {
    ctx.addIssue({ code: 'custom', message: 'True/False questions must have True and False options.', path: ['options'] });
  }
  const correct = Array.isArray(question.correct_answer) ? question.correct_answer : [question.correct_answer];
  if (question.type === 'multiple_select' && !Array.isArray(question.correct_answer)) {
    ctx.addIssue({ code: 'custom', message: 'Multiple select questions require an array of correct answers.', path: ['correct_answer'] });
  }
  if (new Set(correct).size !== correct.length || correct.some(answer => !question.options.includes(answer))) {
    ctx.addIssue({ code: 'custom', message: 'Correct answers must match unique answer options.', path: ['correct_answer'] });
  }
  if (question.type !== 'multiple_select' && Array.isArray(question.correct_answer) && question.correct_answer.length !== 1) {
    ctx.addIssue({ code: 'custom', message: 'Only multiple select questions can have more than one correct answer.', path: ['correct_answer'] });
  }
});

export const questionImportSchema = z.array(questionImportItemSchema).min(1).max(500);
export type ImportedQuestion = z.infer<typeof questionImportItemSchema>;

