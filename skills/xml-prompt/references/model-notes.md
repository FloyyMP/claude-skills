# Per-model notes

Only the differences that change what goes into a prompt. Everything else in the skill applies
to every current model. Source: Anthropic's model-specific prompting pages, September 2026.

## If the user does not name a model

Write for current Claude models (Fable 5.1, Opus 5, Sonnet 5). The defaults in SKILL.md
already match them: no `<thinking>` tags, no prefill, plain instructions rather than shouted
ones, explicit scope.

## Fable 5 and Fable 5.1 (also Mythos)

- Thinking is always on. Do not instruct the model to echo, transcribe, or explain its
  reasoning in the response; that can trigger a `reasoning_extraction` refusal. Ask for the
  result, not the workings.
- Strong instruction following: one brief instruction beats a list of every case. Older
  prompts that enumerate behaviours are often too prescriptive and degrade output; cut them.
- Give the reason behind the request (the "I'm working on X for Y, they need Z" template).
- Fable 5.1 formats *less* than older models: remove anti-markdown blocks, or replace them with
  the "Formatting in chat" rule in `snippets.md`.
- Fable 5.1 prose can run dense: add the "Mannered prose" block if the user complains about
  flourish, or "Please remove all mannered prose".
- Fable 5.1 summarising sources may reuse wording without quote marks: add the one-example
  block from `snippets.md` section 14.
- For unattended agents, the "Finish the whole task" block is the fix for turns that end on
  "Next, I'll..." or "Shall I apply this?".
- A "keep changes and tests to what the task asks for" block cuts unrequested fixes without
  hurting task success.

## Opus 5

- Responses run longer than other models and effort does not shorten them. Add an explicit
  conciseness instruction, and in a long system prompt repeat a short one near the end:
  `<tone_preference>Keep outputs reasonably concise.</tone_preference>`
- It verifies and self-corrects on its own. Remove "double-check your answer", "verify before
  responding", "use a subagent to verify"; they cause over-verification.
- It widens task scope readily: use the "Scope: deliver what was asked" block for narrow tasks.
- It spawns subagents readily: add the subagent damping block in cost-sensitive setups.
- Review prompts that say "only report high-severity issues" get followed literally and recall
  drops. Ask for everything with a confidence and severity per finding, and filter later.

## Sonnet 5 and Opus 4.8

- Literal instruction following: they do not generalise one instruction to the next item.
  State scope explicitly ("every section, not just the first").
- Positive examples of the wanted style beat instructions about what not to do.
- At low effort they can under-think. If the prompt will run at low effort, add: "This task
  involves multistep reasoning. Think carefully through the problem before responding."
- Both have a persistent default visual style on design briefs. Generic "don't use cream"
  just swaps palettes; either specify a concrete alternative in detail, or ask the model to
  propose four directions and build only the chosen one.
- Same review-prompt caveat as Opus 5.

## Older models (Claude 4.5 and earlier, or any model with thinking off)

- Manual chain of thought is still useful: ask for reasoning in `<thinking>` and the result in
  `<answer>`. Put `<thinking>` inside few-shot examples to show the pattern.
- Opus 4.5 with thinking off is sensitive to the word "think"; use "consider", "evaluate",
  "reason through".
- Prefill still works there but is gone from 4.6 onward, so do not build on it.
- "If in doubt, use [tool]" style over-prompting was needed then and over-triggers now.

## Non-Claude models

XML sectioning, placement of long inputs first, the query last, examples in tags, and stating
the reason behind rules all transfer. Model-specific blocks in `snippets.md` were measured on
Claude; use them as a starting point and say so in the note under the prompt.
