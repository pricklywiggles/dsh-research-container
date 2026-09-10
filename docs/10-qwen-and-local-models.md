# Running Qwen3.8 (and other local models) as the agent

This setup drives a local llama.cpp server rather than a hosted API. That
changes which failure modes you hit. The dominant one is not "the model is
less clever", it is **degenerate repetition inside agent loops**: the model
issues the same tool call over and over until something external stops it.

Everything here was learned by running qwen38-27B (IQ4_XS) against real
research workloads and reading the session transcripts afterwards.

## The model in use

| | |
|---|---|
| Model | Qwen3.8-27B, IQ4_XS (4.25 bpw), ~14.6 GB |
| Server | llama.cpp on another machine, reached through the gateway relay on port 8090 |
| Alias | `qwen38` (what `settings.yaml` references) |
| Trained context | 262,144 |
| Multimodal | yes, `mmproj-F16.gguf` loaded |

## Sampling: use the vendor numbers

Qwen publishes different parameters per mode, and they are not
interchangeable:

| | Instruct / non-thinking | Thinking |
|---|---|---|
| temperature | 0.7 | 1.0 |
| top_p | 0.80 | 0.95 |
| top_k | 20 | 20 |
| min_p | 0.0 | 0.0 |
| presence_penalty | **1.5** | 0.0 |
| repetition_penalty | 1.0 | 1.0 |

Two things worth internalising, because both are counter-intuitive:

**presence_penalty 1.5 is correct, not excessive.** It looks alarmingly high
next to other vendors' defaults. It is Qwen's own recommendation for
non-thinking mode, and their guidance for endless repetition is to raise it
toward 2.0 rather than lower it. Do not "fix" a loop by reducing it. (This
document exists partly because that advice was given here and was wrong.)

**Never use greedy decoding.** Qwen explicitly warns it causes performance
degradation and endless repetition.

## Why the penalties do not stop agent loops

This is the important mechanism, and it is a llama.cpp implementation detail
rather than anything about Qwen.

llama.cpp applies presence, frequency and repeat penalties over a sliding
window of the last `--repeat-last-n` tokens. **The default is 64.** In an
agent loop the repeated thing is a whole tool call, and consecutive
occurrences are separated by the tool result, the model's reasoning, and
often thousands of tokens. The penalty window never contains two copies of
it, so no penalty is ever applied, no matter how high you set it.

That produces the confusing situation of a model looping while configured
with an aggressive anti-repetition penalty that is working exactly as
designed and is structurally blind to the problem.

Fixes that actually reach it:

- **`--repeat-last-n 512`** or larger, so the window can span turns. Costs
  a little sampling time per token.
- **DRY sampler** (`--dry-multiplier 0.8 --dry-base 1.75
  --dry-allowed-length 2`). Off by default in llama.cpp. Unlike the
  penalties, DRY targets repeated *sequences* over long range, which is the
  actual shape of the failure. Caveat: tool-call JSON is legitimately
  repetitive, so verify tool calling still works after enabling it.
- **Stay current on llama.cpp.** Fixes in this area land regularly; a build
  from a few weeks ago can be missing a relevant one. The reference setup went from
  `b10434` to `b10628` as part of the same round of changes.

## KV cache quantization: benchmark, do not reason

This section is a correction. The advice originally given here was wrong and
caused a measurable regression, so the reasoning that produced it is recorded
alongside the result.

**What was advised:** `-ctk q8_0 -ctv q4_0`, on the widely-repeated principle
that keys are more sensitive to quantization than values, plus a KV-size
calculation suggesting a context cut would pay for it.

**What actually happened:** mixed KV types were fine on short prompts and
catastrophic on long ones. Long-prompt attention fell back to the CPU.
Prompt processing measured **378 tok/s on short prompts and ~35 tok/s at
length**, and a 72k-token fill never completed in 35 minutes. Reverting to
symmetric `-ctk q4_0 -ctv q4_0` restored **2,300-2,970 tok/s at every
length**, with the same 72k fill completing in **34 seconds**.

Two lessons, both general:

- **Mixed KV types can lose the optimized kernel path.** A configuration that
  benchmarks fine on a short prompt can fall off a cliff at length. The cost
  is invisible until you test at the context sizes you actually use.
- **Benchmark prefill at realistic length before believing any KV change.**
  Short-prompt numbers are actively misleading here.

**Architecture matters more than the generic advice.** Qwen3.8-27B is a
hybrid Gated-DeltaNet model, not a dense transformer. Most of its layers do
not carry a KV cache that grows linearly with context, which is why 112k
context is cheap on this model and why dense-transformer KV arithmetic
(`context x bytes-per-element x layers x kv-heads`) does not describe it.
Any sizing formula you find online, including an earlier version of this
document, assumes a dense model. Check what architecture you are running
before applying it.

llama.cpp prints the real KV cache size at startup. Use that, and a timed
long-prompt fill, rather than arithmetic.

## The failure mode, in detail

Two runaway agents were captured here in full. Both look identical from the
outside: a subagent that runs for tens of minutes and will not stop, and does
not respond to being told it is looping.

| | Session 1 | Session 2 |
|---|---|---|
| Runtime | 33 min | 68 min, stopped manually |
| Steps | 622 | 1,113 |
| Tool calls | 626 | 1,227 |
| Searches | 1,200 (74 distinct) | 1,043 |
| Worst repeat | one query 555× | one query 1,000× |
| Compactions | 6 | 10 |
| Search failures | none, all returned results | none |

Characteristics worth recognising:

- **It starts early.** Step 28 in the first case, step 11 in the second.
  This is not context exhaustion. Compaction happens later and then erases
  the evidence, which is why intervening mid-loop does not help.
- **Nothing errors.** Every tool call succeeds. There is no exception to
  catch and no failure signal in any log.
- **Instructions do not reach it.** The second agent *read* a briefing
  containing "Budget: 12 web_search calls" and "never re-issue a query you
  have already run", then exceeded that budget 87-fold. A model in
  degenerate repetition has stopped doing instruction-following; the failure
  sits below the level where prompts operate.
- **Sibling agents in the same batch are fine.** Two agents launched
  alongside the second one finished normally at 38 and 30 calls. It afflicts
  individual generations rather than the setup as a whole.

The practical consequence: **prompt engineering is not a defence.** Budgets
and stop rules in a skill are still worth having, because they shape the
healthy majority of runs, but they will not save you from this. Only
sampler-level fixes and an external circuit breaker do.

## DRY: tried, and reverted

The DRY sampler (`--dry-multiplier 0.8 --dry-base 1.75 --dry-allowed-length 2`)
was added here to attack the looping problem, and had to be removed within a
day. It is worth recording because the reasoning for adding it was sound and
the outcome was still bad.

**What went wrong.** Agents began emitting corrupted file paths:

```
/home/dev/.dsh/sills/deep-researh/web-searh-agent.md    <- skills, research, search
/workspace/wotfard-free-alteratives/fields.yaml         <- alternatives
/home/devsills/deep-resechwebsearchagnt.md
/home/dev/.d/skills/deepresearchrun/SKILL.md
```

Single characters dropped from the middle of words the model had already
written correctly dozens of times. Measured at **41 of 1,398 tool calls (~3%)
over two hours**, peaking at 7 failures in a single minute, and failing on
exactly the worst targets: agents unable to read their own skill briefing,
outline, or fields file.

**Why.** DRY penalizes the *continuation* of a token sequence that repeats
within `dry_penalty_last_n` (8192 here). A file path an agent must write
verbatim on every call is exactly such a sequence. With
`dry_allowed_length=2` and no `dry_sequence_breakers`, an entire path is one
continuous repeatable run, so the sampler is pushed off the correct next
token and drops characters.

**Confirmation.** Turning DRY off produced a clean cutoff: errors every
minute from 13:23 to 13:46, then **zero from 13:47 onward** across 58
subsequent tool calls. Caveat worth keeping: `repeat_last_n` reverted from
512 to 64 in the same restart, so the timeline alone cannot attribute the fix.
The attribution rests on the failure *signature* instead. DRY corrupts
strings mid-word because it penalizes sequence continuations; presence
penalty is a flat per-token subtraction that changes word choice and would
not drop a character from inside a word it is already committed to.

**If you want DRY anyway**, make it survivable rather than removing it:
raise `--dry-allowed-length` to 8 or more so only genuinely long repeats are
penalized, and add `--dry-sequence-breaker` entries for `/`, `.`, `-` and `_`
so paths are broken into segments instead of treated as one run. Untested
here; the version above was simply switched off.

**The general lesson**, which has now cost two regressions in one day: the KV
change and the DRY change both passed short verification and failed only at
length or after many repetitions. Smoke tests systematically miss this class
of failure. Verify with a long agent session doing file-heavy work, watched
with the minute-bucket query below.

## Diagnosing a suspected loop

dsh session transcripts are zstd-compressed JSONL on the volume. This is the
fastest path from "something feels stuck" to a verdict:

```sh
cd dsh-home/sessions/--workspace--
# newest sessions; directories without a `session-` prefix are subagents
find . -type f -name session.jsonl.zstd -exec stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' {} \; | sort -r | head

zstd -dc <dir>/session.jsonl.zstd > /tmp/s.jsonl
grep -c '"type":"step/start"' /tmp/s.jsonl          # >100 steps is pathological
jq -r 'select(.type=="tool/call") | .data.name' /tmp/s.jsonl | sort | uniq -c | sort -rn

# the decisive check: issued vs distinct arguments
jq -r 'select(.type=="tool/call") | (.data.arguments | fromjson
       | (.url // (.queries // [] | join(" | ")) // "?"))' /tmp/s.jsonl \
  | sort | uniq -c | sort -rn | head
```

`.data.arguments` is a JSON **string**, so it needs `fromjson`. A healthy
research agent shows issued ≈ distinct. A looping one shows a single entry
with a count in the hundreds.

Live activity without decompressing anything:

```sh
container logs dsh 2>&1 | grep -oE "url: '[^']+'" | tail -20   # repeated URL = loop
```

## Stopping a runaway subagent

There is no step cap or duplicate-call detection in dsh, and the parent
session shows no stop button while a background subagent runs. The control
lives in the subagent's own view: expand the right sidebar, open a **Tasks**
tab, expand "N subagents running", click the running agent, then **Stop
generating** in its detail pane. Confirm it worked by checking that the
session file stops growing, rather than trusting the label.

## Known-good configuration

Verified live on 2026-08-27:

```
-c 114688                     # cheap on this architecture; verified by timing
-ngl 99
-np 1
--jinja
-fa on
-ctk q4_0 -ctv q4_0           # SYMMETRIC. mixed types crawl at length here
--spec-type draft-mtp --spec-draft-n-max 2    # MTP speculative decoding
--fit off                     # fail loudly on OOM instead of silently spilling
--temp 0.7 --top-p 0.80 --top-k 20 --min-p 0.0
--presence-penalty 1.5        # Qwen's own value for non-thinking mode
--repeat-last-n 512           # default 64 cannot span turns
                              # NO DRY: see below, it corrupts paths here
--reasoning off
--no-context-shift
```

Confirmed on the running server (`/props` -> `default_generation_settings.params`):
`dry_multiplier=0.0`, `repeat_last_n=512`, `presence_penalty=1.5`,
`temperature=0.7`, `top_p=0.8`, `top_k=20`, `n_ctx=114688`, build `b10628`.
`dry_base` and `dry_allowed_length` still report 1.75 and 2 but are inert
with the multiplier at zero.

Measured on this configuration:

| | Before | After |
|---|---|---|
| Prompt processing | 378 tok/s short, ~35 tok/s long | 2,300-2,970 tok/s at all lengths |
| Decode | 32 tok/s | ~74 tok/s (65 at full 72k context) |
| 72k-token fill | never finished in 35 min | 34 s |
| VRAM | n/a | 23.6 GB idle, 23.85 GB peak |

Tool calling and vision both pass with DRY and MTP active. DRY measured at
zero cost, so the sampler changes were not implicated in the earlier
slowdown.

Two operational notes:

- **Headroom is ~700 MB.** A large image plus anything else on the GPU can
  OOM. `--fit off` makes that fail loudly rather than silently spilling to
  system RAM, which is the failure that produced 27 tok/s prefill. Drop to
  98304 context if you hit it.
- **A config edit needs a fresh shell.** The launcher function is defined at
  shell start, so editing it and re-running in the same session silently runs
  the old flags. This caused two false results during tuning.

Verify what is actually live rather than what you think you launched:Verify what is actually live rather than what you think you launched:

```sh
curl -s http://<model-host>:8090/props | jq '.default_generation_settings
  | {n_ctx, presence_penalty, repeat_last_n, dry_multiplier, dry_base}'
```

The build id comes back in any completion response as `system_fingerprint`.

## Keep the harness's context window in sync with the server

`dsh-home/settings.yaml` declares `contextWindow` per model, and dsh's token
meter uses it to compute context pressure and decide when to compact. It is
**not** discovered from the server, so changing llama.cpp's `-c` silently
desynchronizes them.

If the declared window is larger than the server's real `n_ctx`, dsh
under-reports pressure, compacts too late, and eventually builds a prompt the
server cannot accept. With `--no-context-shift` that is a hard error rather
than graceful truncation.

Run this after any change to the server's `-c`, then restart dsh:

```sh
./scripts/sync-model-context.sh          # MODEL_HOST=host:port to override
container stop dsh && container start dsh
```

It reads `n_ctx` from the server's `/props`, subtracts a reserve for the
response (4096 by default), and writes `contextWindow` plus `maxTokens` into
settings.yaml. Reserving output space matters because `n_ctx` covers prompt
and generation together: a prompt sized to the full window leaves no room to
answer.

## Post-restart verification

Run this after every server restart. It takes under a minute and catches both
regressions seen here.

**1. Did the flags actually land?** The launcher runs from a shell function,
so editing it and re-running in the same session silently uses the old flags.
This produced two false results during tuning.

```sh
curl -s http://HOST:8090/props | jq '.default_generation_settings.params
  | {temperature, top_p, presence_penalty, repeat_last_n, dry_multiplier}'
curl -s http://HOST:8090/props | jq '.default_generation_settings.n_ctx, .build_info'
```

Note the samplers live under `default_generation_settings.params`, and
`/slots` reports them as null while the slot is idle.

**2. Is prefill healthy at length?** A short prompt proves nothing: the broken
mixed-KV config served 378 tok/s on a small prompt while managing 35 tok/s at
length. Send something substantial and read the server's own timings.

```sh
python3 -c "
import json,random; random.seed(7)
w=['alpha','beta','gamma','delta','epsilon','zeta','eta','theta']
b=' '.join(f'{random.choice(w)}-{i}' for i in range(6000))
print(json.dumps({'model':'qwen38','max_tokens':8,'messages':[
  {'role':'user','content':'Reference material. Reply only DONE.\n\n'+b}]}))" > /tmp/big.json

curl -s http://HOST:8090/v1/chat/completions -H 'Content-Type: application/json' \
  -d @/tmp/big.json | jq '{prompt_tokens: .usage.prompt_tokens,
    prefill: .timings.prompt_per_second, decode: .timings.predicted_per_second}'
```

Measured 2026-08-27: **2,742 tok/s prefill on a 35,841-token prompt**, inside
the healthy 2,300-2,970 band and about 100x the broken config's 27 tok/s.

**3. Re-sync the harness** if `-c` changed: `./scripts/sync-model-context.sh`
then restart dsh.

## Why a healthy-looking server can still be unusable

Every endpoint that matters can pass while the box is useless. `/health`
returns ok and `/v1/models` answers in milliseconds because those never touch
the model. With `-np 1` a single slot serves everything, so one slow request
stalls every agent behind it and the harness looks frozen.

Sample the slot directly to tell "slow" from "wedged":

```sh
curl -s http://HOST:8090/slots | jq '.[0]
  | {is_processing, prefill: .n_prompt_tokens_processed, total: .n_prompt_tokens,
     cache_reused: .n_prompt_tokens_cache}'
```

Advancing exactly one `ubatch` (2048 tokens) then stalling for tens of
seconds means attention has fallen off the GPU path, from either a kernel
fallback or VRAM spilling to system RAM.

Also watch `n_prompt_tokens_cache`. A persistent 0 means no prefix reuse, so
every turn re-prefills the whole conversation. With one slot shared by a
parent and its subagents, each agent's request evicts the previous one's
cached prefix. `--cache-reuse 256` helps.

## Loose ends

`speculative.types` reported `none` on the 2026-08-27 restart, so MTP
speculative decoding did not survive that config edit. Decode measured 64.6
tok/s short and 20 tok/s on a 35k prompt, against ~74 tok/s benchmarked with
MTP active. Prefill and correctness are unaffected, so this is a speed
regression rather than a fault, but check whether
`--spec-type draft-mtp --spec-draft-n-max 2` is still in the launcher.

## The loop guard

dsh ships no loop protection of its own: no step cap, no wall-clock limit, no
duplicate-call detection, and no way for a parent to notice its subagent has
gone pathological.
[dsh-circuit-breaker](https://github.com/pricklywiggles/dsh-circuit-breaker),
written for this project and pinned in the Dockerfile, fills that gap.

It registers through `ctx.tools.guard()`, DSH's synchronous pre-execution
check, and denies a call once the same tool has run with the same significant
arguments too many times, with a per-agent call cap as a backstop. Denials
return an explanation to the model and appear in the transcript.

Verified live: an agent asked to repeat one command was denied at call 6, and
then reported honestly that the breaker prevented it rather than spinning.

Why the two tiers are shaped the way they are: repetition is a
self-reinforcing attractor. Each repeat raises the probability of the next
one, and the published results match what happened here, with the pattern
persisting through added sampling randomness and through changed prompts.
That is why telling a looping agent it is looping sends it straight back
(observed on both captured sessions), and why compaction made things worse by
deleting the evidence while the behavior persisted. `duplicateLimit` fires at
six repeats because early is the only time denial text still has a chance of
reaching the model; `maxCallsPerAgent` is a lifetime kill switch because by
then recovery in place is not real, and the only true fix is a fresh agent
with a clean context, which gets a fresh cap automatically.

A denial is not a kill. dsh's guard API has no abort hook, so an agent that
ignores the denial becomes a zombie: every call denied, externally harmless,
but never completing, never returning anything to its parent, and still
competing for the single llama.cpp slot (`-np 1`). The breaker therefore
writes an incident line to `/workspace/.circuit-breaker-incidents.jsonl` on
the first denial of each kind per agent (configured as an id-targeted
override in the home cordis patch layer), and the deep-research-run skill's monitoring step reads
it: a tripped child with no output after 5 minutes gets `interrupt_agent` and
one re-dispatch with that line of investigation marked exhausted; a second
trip marks the item [uncertain]. Interrupting matters beyond hygiene, since
it frees the inference slot.

One finding from building it, which matters for anyone writing a similar
guard: DSH's `bash` tool takes a free-text `description` alongside `command`,
and the model rewrites it every call. Comparing raw arguments therefore never
matches, so the plugin strips annotation-only fields (`ignoreArgs`) before
comparing. Without that it silently never fires.

The sampler changes above reduce how often loops happen. This is what bounds
the damage when one does.

If you are running a different local model, expect the same class of
problem and check two things first: the anti-repetition window
(`--repeat-last-n` or the equivalent) against the length of one agent turn,
and whether your KV cache quantization is symmetric.
