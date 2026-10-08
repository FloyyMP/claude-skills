# Tag vocabulary

The sections a prompt can have, in the order they should appear. Each entry says what belongs
inside, when to include it, and when to leave it out. Use these names unless the user already
has their own; consistency across prompts matters more than the exact word chosen.

| Tag | Holds | Include when | Leave out when |
|---|---|---|---|
| `<role>` | One or two sentences on who the model is acting as and for whom. The docs note even one sentence in the system prompt shifts behaviour | The persona changes tone, vocabulary, or what counts as a good answer (a paediatric nurse vs. a pharmacologist) | The task is mechanical (extract, classify, convert). "You are a helpful assistant" adds nothing |
| `<context>` | Background the model cannot infer: the situation, the audience, why the task exists, what happens to the output next. Template: "I'm working on [larger task] for [who]. They need [what the output enables]." | Almost always. The "why" is what lets the model make good calls on cases you did not spell out | The ask is self-contained and one line |
| `<document>`, `<emails>`, `<code>`, `<transcript>`, or another content-named tag | The run-time input as a `{{PLACEHOLDER}}`. Several documents: `<documents><document index="1"><source>name</source><document_content>{{X}}</document_content></document>` | The model receives input at run time | Pure generation with no input |
| `<instructions>` | Numbered steps, in the order to perform them | The task has more than one step, or order and completeness matter | A single-step task; fold it into the final task line instead |
| `<constraints>` | Hard limits, each with its reason: length, language, what to preserve, what must never appear, what is out of scope | There is a rule the model would otherwise break | Every "constraint" is really the output format (use `<output_format>`) |
| `<examples>` with nested `<example>` | Three to five short input/output pairs, varied enough to show the range. For a chat-style example the docs use `<user>`, `<response>` and `<rationale>` sub-tags | The output shape is unusual, tone is hard to describe, or the user supplied samples. Examples beat abstract format instructions for consistency | The format is fully described in `<output_format>` and obvious. Invented examples for factual tasks can bias the model, so keep them short and illustrative |
| `<output_format>` | The exact shape of the answer: wrapper tag names, JSON fields and order, length, tone, "respond directly without preamble" | Always, unless the output is a single obvious sentence | Never, really. Even "reply in one paragraph" is worth stating |
| Final task line | The actual question or instruction, restated once, last, outside any tag or in `<task>` | Always. On long prompts the model reads this right before it answers, which is why it goes last | Never |

## Tag hygiene

- Lowercase, snake_case, descriptive of content: `<support_ticket>`, not `<data1>`.
- Same name for the same thing everywhere in the prompt and in any instruction that refers to it.
- Close every tag. An unclosed tag is the most common way an XML prompt quietly breaks.
- Do not wrap the whole prompt in a root tag; it adds nothing.
- Attributes are fine for small metadata: `<document index="2" source="annual_report.pdf">`.
- Do not tag single words or wrap a one-line prompt in five sections. Structure has to buy
  clarity; when it does not, prose is better.
- The prompt's own style leaks into the output. A prompt full of markdown bullets gets a
  bulleted answer; if the answer should be prose, write the prompt in prose.

## Phrasing inside the tags

- Imperative mood, one instruction per sentence, no hedging ("please try to" → "do").
- Attach the reason to any rule the model might otherwise soften or ignore. The model
  generalises from the reason to cases you did not list.
- Describe the wanted behaviour rather than the unwanted one. "Write the prose sections inside
  `<flowing_prose>` tags" is the docs' own example of a format indicator that works.
- State scope explicitly. Current models do not silently generalise one instruction to the next
  item: "apply this to every section, not just the first".
- Reserve emphasis for one thing per prompt. "Use this when..." works; "CRITICAL: you MUST"
  makes current models over-trigger.
- For machine-read output: "Return only the JSON object, with no text before or after it,
  because the response is parsed directly." This one sentence fixes most format drift.
- Give permission to be uncertain when the answer depends on supplied material: "If the
  document does not cover this, say 'I don't have enough information to answer.'"

## System prompt vs. user message

When the prompt is for an API integration or an agent with a fixed persona, the content divides
into two parts, but they still ship in one fenced code block (see the Deliver step in SKILL.md:
two blocks break `/copy`). Separate them with a plain marker line inside the block, e.g.
`===== SYSTEM PROMPT =====` and `===== USER MESSAGE =====`:

- **System prompt part**: `<role>`, stable `<context>`, `<constraints>`, `<output_format>`, and
  the `<examples>`. Everything that is true for every call. For a character or persona, the docs
  recommend also listing common scenarios with the expected response to each.
- **User message part**: the run-time input tags and the final task line.

The note under the block tells the reader which half goes in the API's `system` field and which
is the per-call message. For a one-off chat prompt, there is no division: everything is one
block with no markers. The split matters because long stable content in the system field is
what prompt caching works on, so it saves money on repeated calls.
