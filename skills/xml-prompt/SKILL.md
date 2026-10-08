---
name: xml-prompt
description: Turn a plain-English request into a tight, well-structured XML prompt that gets the best result out of an LLM. Use whenever the user asks for a prompt, wants a prompt written, improved, optimized, tightened or structured, wants a system prompt, or pastes rough instructions meant for Claude, ChatGPT, Claude Code or any agent and wants them made better, even if they never say "XML". Also use when they hand over an existing prompt and say it isn't working well. Not for answering the request itself.
---

# XML Prompt

Rewrite what the user said in plain English into a prompt an LLM can execute precisely. The
deliverable is the prompt, not the answer to it. Never perform the underlying task.

The guidance here is distilled from Anthropic's current prompting docs (September 2026). Where
a reference file quotes a prompt block, it is quoted from those docs and has been measured to
work; prefer it over paraphrasing.

## Why XML, and why lean

Anthropic's own framing: treat the model as a brilliant new employee who knows nothing about
your norms. Handed a wall of prose, that employee has to guess which sentence is the task,
which is background, which is a hard rule and which is an example. Tags remove the guessing.
Given `<contract>...</contract>` and then "quote the clause from the contract", the model
cannot confuse the document with the instructions. That is the whole value of the tags:
unambiguous boundaries, not decoration.

The second half of the value is economy. Current Claude models follow instructions closely
enough that one clear sentence steers a behaviour; enumerating every case, repeating warnings,
and CAPITALISED MUSTS make the important lines harder to find and make the model over-react.
Filler like "You are a world-class expert with 20 years of experience" changes nothing. Every
sentence in the prompt should either change the model's behaviour or be cut.

## Workflow

1. **Extract the intent before writing a single tag.** From the user's words, pin down:
   - the task, as one verb phrase: classify, rewrite, extract, generate, review, plan, build
   - the inputs the model will receive at run time, and whether any is a long document
   - what "done" looks like: output shape, length, tone, who reads it, what happens to it next
   - hard constraints and the reason for each. The reason is what makes a model honour a rule
     and generalise it to cases you did not list ("no ellipses, a text-to-speech engine reads
     this aloud" beats "NEVER use ellipses")
   - what the user left unsaid that would change the output. Fill obvious gaps with a sensible
     default; mark genuinely unknown facts as `{{PLACEHOLDERS}}`. Do not invent company names,
     numbers, policies or facts the user never gave you. If the fact lives in the project you
     are running in, read it from there instead (see "Prompts about the project you are
     sitting in" below).

   Golden rule from the docs: if a colleague with no context would be confused by the prompt,
   the model will be too.

2. **Size the prompt to the job.** "Summarise this email in two lines" deserves a ten-line
   prompt. A contract-analysis pipeline deserves fifty. Bloating a small task is as much a
   failure as under-specifying a big one. Use only the sections that carry weight;
   `references/tag-vocabulary.md` lists each section and when it earns its place.

3. **Order the sections for how the model reads.** Long inputs first, instructions after
   them, and the actual question last. Anthropic measured up to a 30 percent quality gain from
   putting the query at the end on long, multi-document inputs. Recommended order:
   `role` (only if it changes behaviour) → `context` → inputs/documents → `instructions` →
   `constraints` → `examples` → `output_format` → final task line.

4. **Write the body.** The rules that matter:
   - Tag names: lowercase snake_case, descriptive of the content, used consistently. When an
     instruction refers to a section, name the tag ("using the emails in `<emails>`"). Nest only
     when the data has a natural hierarchy: `<documents><document index="1"><source>` and
     `<document_content>`, or `<examples><example>`.
   - Say what to do, not what to avoid. "Write in flowing prose paragraphs" beats "Do not use
     markdown". When a prohibition is unavoidable, attach the reason.
   - Give context and motivation, not just the order. The docs' template for this is:
     "I'm working on [larger task] for [who it's for]. They need [what the output enables].
     With that in mind: [request]." Fold that into `<context>`.
   - State scope explicitly. Current models follow instructions literally and do not silently
     generalise: write "apply this to every section, not just the first" when that is meant.
   - Examples: include 3 to 5 when the output format or tone is hard to describe, or when the
     user supplied samples. Make them relevant and varied so the model does not learn an
     accidental pattern. Wrap them in `<examples><example>`. When you invent an example for a
     factual task, keep it short and clearly illustrative so its content is not copied.
   - Placeholders for run-time content use `{{UPPER_SNAKE}}` inside the relevant tag:
     `<email>{{EMAIL_BODY}}</email>`. Never put placeholders inside instructions.
   - Long documents (roughly 20k tokens and up): ask the model to pull exact quotes into
     `<quotes>` before doing the task, and to base the task only on those quotes. This is the
     single most effective hallucination control in the docs. Also give explicit permission to
     say "I don't have enough information" when the source does not cover the question.
   - Reasoning: do not ask the model to write out its thinking in `<thinking>` tags. Current
     Claude models think before answering on their own, and on Fable-class models an
     instruction to reproduce reasoning in the response can trigger a refusal. A general nudge
     ("this involves multistep reasoning, think it through carefully") is fine when the task
     has judgement in it. Reserve `<thinking>`/`<answer>` tags for prompts the user says will
     run on an older model with thinking turned off.
   - Output format: state the exact shape. For machine-read output, ask for it inside a named
     tag or as bare JSON with nothing before or after, and say why: "the response is parsed by
     a script". Prefills are no longer supported, so "respond directly without preamble" does
     that job now. For guaranteed JSON, note that structured outputs exist.
   - Self-check: "Before you finish, verify your answer against [criteria]" helps on coding and
     maths tasks. Leave it out of prompts aimed at Opus 5, which over-verifies when told to.

5. **Deliver.** Put the finished prompt in exactly one fenced code block, and never more than
   one. The user copies it with `/copy`, which lists every fenced block as a separate,
   unlabelled option; a prompt split across two blocks becomes two confusing "empty" choices
   and cannot be grabbed in a single selection. One block means one clean copy of the whole
   prompt. Under the block, at most three short lines: placeholders to fill in, one assumption
   you made if it matters, nothing else. No prompt-engineering theory, no walkthrough of the
   sections, and nothing else fenced anywhere in the reply, so the block is the only copy
   option besides the full response.

   **Fence delimiter rule:** when the prompt body itself contains triple-backtick code fences
   (e.g. a directory tree, shell commands, or code samples), the outer fence MUST use four
   backticks (``````) so the inner triple-backtick fences do not accidentally close it. A
   triple-backtick outer fence is fine only when the prompt body contains no fenced blocks at
   all.

   If the prompt is for an API integration or an agent with a fixed persona, it still goes in
   one block. Mark the two parts with plain comment lines inside that single block so they copy
   together:

   ```
   ===== SYSTEM PROMPT =====
   <role>...</role>
   <constraints>...</constraints>

   ===== USER MESSAGE =====
   <input>{{RUN_TIME_INPUT}}</input>
   ...the final task line
   ```

   The reader splits them into the two API fields themselves; the note under the block says
   which half is which.

## Existing prompts

When the user hands you a prompt that already exists, keep their tag names, their tone, and
every domain detail they wrote. Restructure, cut filler, add the missing sections, move the
final instruction to the end, and soften any "CRITICAL / MUST / NEVER" language into a plain
instruction with its reason. Tell them in one line what changed. Do not silently drop a
constraint they wrote; if one is harmful or obsolete (a prefill, a "show your thinking"
instruction, an anti-formatting block aimed at an older model), say so in the note.

## Prompts aimed at coding agents

A prompt for Claude Code or a similar agent needs sections a chat prompt does not: what the
codebase already uses so the agent does not add duplicate dependencies, acceptance criteria,
the verification command to run before claiming done, and what is out of scope. Instruct the
agent to act ("change the function"), not to suggest ("can you suggest changes"): the docs
note that suggestion phrasing makes the model stop at suggestions.

When the user's fear is breakage ("don't break anything", a migration, a large refactor),
have the agent establish a safety net before it touches code: run the existing tests and
record the baseline, or write a thin set of smoke tests if there are none, then work in small
batches and commit after each green one. "Verify at the end" cannot catch which of forty
changes broke something; a checkpoint after each batch can. When the user's ask
touches over-engineering, test-gaming, destructive actions, hallucinated code, or stopping
early, `references/snippets.md` has the measured prompt blocks for each; paste the matching
one into `<constraints>` rather than writing your own version.

## Prompts about the project you are sitting in

When the ask concerns the codebase in the current working directory ("add X to my tool",
"write a prompt to fix the login bug here"), look before you write. A placeholder is for facts
you cannot get; facts in the repo are not that. Read, in this order and only as far as needed:

1. `CLAUDE.md` at the project root and any `## Next` block: conventions, verification gate,
   things the user has already decided.
2. The manifest (`pyproject.toml`, `package.json`, `go.mod`): language, test runner, existing
   dependencies, the real test and build commands.
3. The files the feature would touch: entry points, the module the change belongs in, the
   nearest existing test file so the prompt can say "sized like `tests/test_foo.py`".

Then write the prompt with those facts in it: the actual test command, the real module and
function names, the repo's own naming and error-handling style, the dependency that already
does the job. Placeholders stay only for things the repo cannot tell you, such as the exact
behaviour the user wants. Reading the code is research for the prompt, not permission to
change it; the deliverable is still the prompt, and no file in the project gets edited.

If the ask is about a different project, or no project is present, fall back to placeholders
as usual and say in the note which ones the user should fill from their repo.

## Reference files

- `references/tag-vocabulary.md`: the canonical sections, what goes in each, when to leave
  it out, and how to split system prompt from user message.
- `references/snippets.md`: reusable prompt blocks quoted from Anthropic's docs, indexed by
  the problem they solve (verbosity, scope, over-engineering, autonomy, hallucination, and
  so on). Read this whenever the ask is for an agent or the user names a behaviour to fix.
- `references/model-notes.md`: the handful of per-model differences that change what goes in
  a prompt. Read this when the user names the target model.
- `references/examples.md`: three before/after conversions (short ask, long-document
  analysis, coding-agent task). Read this when unsure how much structure an ask warrants.
