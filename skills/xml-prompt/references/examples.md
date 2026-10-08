# Before and after

Three conversions at three sizes. The point of each is proportion: the short ask stays short,
the document task gets quote grounding, the agent task gets acceptance criteria and a
verification command.

---

## 1. Short ask

**User said:**
> make me a prompt that turns a customer support email into a ticket with priority, category and next action

**Delivered:**

```xml
<context>
You triage inbound support emails for a small software company. The output feeds a ticketing
system, so it is read by a script, not a person.
</context>

<email>
{{EMAIL_BODY}}
</email>

<output_format>
Return only a JSON object with these keys, nothing before or after it:
- "priority": one of "urgent", "high", "normal", "low". Urgent means the customer cannot use
  the product at all or is losing data.
- "category": one of "billing", "bug", "how_to", "feature_request", "other".
- "next_action": one sentence, imperative, addressed to the support agent.
- "summary": one sentence describing the customer's problem in their terms.
If the email is not a support request (spam, newsletter, out-of-office), set every field to
"n/a" except "category", which is "other".
</output_format>

Read the email in <email> and produce the ticket.
```

Fill in: `{{EMAIL_BODY}}`. Assumed the category list; adjust to your ticketing system's real
values.

**Why it is this size:** one input, one output shape, no judgement calls the model cannot make
from the email alone. A role line or numbered steps would add nothing. The "not a support
request" case is the one gap the user did not mention and would otherwise produce garbage JSON.

---

## 2. Long-document analysis

**User said:**
> I want to paste a 40 page contract and have claude find all the clauses that let the other
> side terminate early. it needs to quote the exact text and page. turn that into a good prompt

**Delivered:**

```xml
<role>
You are a contracts analyst preparing notes for a lawyer who will negotiate this agreement.
</role>

<context>
We are the party referred to as {{OUR_PARTY_NAME}}. The lawyer needs every route by which the
other party ({{THEIR_PARTY_NAME}}) can end the agreement before its natural expiry, so nothing
can be missed and every finding must be checkable against the source text.
</context>

<contract>
{{CONTRACT_TEXT}}
</contract>

<instructions>
1. Read the whole contract. Early-termination rights can appear outside the termination
   section: in breach, insolvency, change-of-control, force majeure, assignment, and
   convenience clauses, and in schedules.
2. Extract every passage that gives {{THEIR_PARTY_NAME}} a right to terminate, suspend, or
   treat the agreement as ended before expiry. Copy each passage word for word into
   <quotes>, one <quote> per passage, with its clause number and page number as attributes.
   If a passage's page is not visible in the text, use page="unknown" rather than guessing.
3. Base the analysis only on those quotes. For each one, state the trigger, any notice period
   or cure period, and whether the right is one-sided or mutual.
4. If you find no such clauses, say so plainly rather than stretching a clause to fit.
</instructions>

<output_format>
<quotes>
  <quote clause="12.2" page="17">exact text</quote>
</quotes>
<analysis>
One entry per quote, in contract order. Each entry: clause reference, trigger, notice or
cure period, one-sided or mutual, and a one-line plain-English reading. End with a
two-sentence overall summary of how exposed we are to early termination.
</analysis>
</output_format>

List every early-termination right {{THEIR_PARTY_NAME}} holds under the contract in
<contract>, following the instructions above.
```

Fill in: `{{OUR_PARTY_NAME}}`, `{{THEIR_PARTY_NAME}}`, `{{CONTRACT_TEXT}}`.

**Why it is this size:** the input is long, so the document sits first and the task line sits
last. Quote-first extraction is what keeps a 40-page analysis grounded, and the page-unknown
escape hatch stops the model inventing page numbers. Step 1 exists because the obvious failure
mode is reading only the section titled "Termination".

---

## 3. Coding-agent task

**User said:**
> write a prompt for claude code to add rate limiting to my fastapi app, redis is already used,
> don't break existing tests

**Delivered:**

```xml
<context>
This is a FastAPI service. Redis is already a dependency and there is an existing client in
the codebase; reuse it rather than adding a second Redis library or a rate-limiting package.
The goal is to protect the public endpoints from abuse without changing behaviour for normal
traffic.
</context>

<task>
Add per-client rate limiting to every route under {{PUBLIC_ROUTE_PREFIX}}.
</task>

<requirements>
- Limit: {{REQUESTS_PER_WINDOW}} requests per {{WINDOW_SECONDS}} seconds per client, keyed on
  the API key header if present, otherwise on client IP.
- Over-limit requests return HTTP 429 with a Retry-After header.
- The limiter state lives in Redis so it works across multiple app instances.
- Implement it as FastAPI middleware or a dependency, whichever matches how the codebase
  already handles cross-cutting concerns. Look before choosing.
</requirements>

<constraints>
Every existing test must still pass. Add tests for the limiter sized like the neighbouring
test files: one for under-limit, one for over-limit, one for the window resetting.
Do not refactor unrelated code, add configuration flags that were not asked for, or add
docstrings to code you did not change. If you find a pre-existing bug, report it in your
summary instead of fixing it here.
</constraints>

<verification>
Run {{TEST_COMMAND}} before changing anything and record the result as the baseline. Run it
again before reporting done and include the output. If anything fails, say so with the
failing output rather than describing it.
</verification>

Implement the rate limiter as specified, then report what changed and the test results.
```

Fill in: `{{PUBLIC_ROUTE_PREFIX}}`, `{{REQUESTS_PER_WINDOW}}`, `{{WINDOW_SECONDS}}`,
`{{TEST_COMMAND}}` (for example `uv run pytest`).

**Why it is this size:** the agent needs to know what already exists (Redis client, test
layout), what done means (429 with Retry-After, tests green), and what is out of bounds. The
constraint wording is lifted from the docs' measured "keep changes to what the task asks for"
guidance. "Implement" rather than "can you add" matters: suggestion phrasing makes the model
stop at suggestions.
