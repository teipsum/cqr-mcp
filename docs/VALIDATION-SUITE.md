**CQR Validation Test Suite**

MVP1 Feature Definition

Current State Assessment, Feature Specifications, and Patent Evidence Requirements

TEIPSUM / UNICA Platform

March 2026 (originally drafted under the SEQUR name, renamed April 2026)

**CONFIDENTIAL**

> **Naming note:** This document was originally written when the protocol was named **SEQUR** (Semantic Query Resolution). It has been updated to use the current name, **CQR** (Cognitive Query Resolution). Module references like `Sequr.Parser` are now `Cqr.Parser`. The USPTO provisional patent application was filed under the SEQUR name; all claims and semantics apply to CQR. Pronunciation: "C-Q-R" sounds like "seeker."

# Current State Assessment

## What Exists Today

The current test harness consists of 55 ExUnit tests across unit and integration categories. These tests validate parser correctness, adapter functionality, engine fan-out, and the Teipsum Agent reasoning loop. They are development-quality tests, not a validation harness. There is no formal test suite for measuring LLM SEQUR generation accuracy, no versioned run tracking, no patent evidence capture, and no comparison baseline.

### Existing Test Coverage

| **Test Module** | **Count** | **What It Validates** |
| --- | --- | --- |
| Sequr.ParserTest | ~20 | Parser correctness for RESOLVE and DISCOVER primitives. Syntax variants, optional clause ordering, arrow formats, uppercase identifiers. |
| Sequr.IntegrationTest | ~10 | End-to-end: parse SEQUR string, execute against real Postgres/Neo4j, verify return envelopes. Scope fallback, reputation filtering, DISCOVER graph traversal. |
| Sequr.EngineTest | ~10 | Context Assembly Engine fan-out via Task.async_stream across adapters. Multi-adapter result merging, sources field attribution. |
| Unica.AgentTwinTest | ~10 | GenServer lifecycle, multi-step reasoning loop (DISCOVER → rank → RESOLVE → synthesize), LLM integration. |
| Adapter health checks | ~5 | Postgres and Neo4j connectivity and health_check/0 callback. |

### What These Tests Do Not Cover

- LLM SEQUR generation accuracy against a controlled intent suite

- Versioned run tracking across configuration changes

- Side-by-side comparison against RAG or direct tool-call baselines

- Patent evidence capture (reduction to practice, novelty demonstration, full context chains)

- Automated scoring with syntactic, semantic, and intent fidelity axes

- Regression detection across system prompt, model, or parser changes

- Cross-model comparison (local Ollama vs Claude API vs other frontier models)

### Informal Validation Results

From approximately 10 live queries during the POC build, the informal assessment is:

| **Metric** | **Informal Estimate** | **Target** | **Gap** |
| --- | --- | --- | --- |
| Syntactic accuracy | 70–80% | 90%+ | Moderate. Failures: double-entity anchors, search terms instead of entity references. Few-shot improvements trending positive. |
| Semantic accuracy | 85–90% | 85%+ | Likely at target. When expressions parse, entity and scope references are consistently correct. |
| Intent fidelity | 4.0–4.5 avg | 4.0+ avg | Likely at target. LLM correctly identifies primitives, anchors, cross-domain scoping. |
| RAG comparison | Not measured | Qualitative superiority | No formal A/B. Anecdotal: cross-domain causal chains that RAG cannot produce. |

These estimates are based on a handful of queries against local 8B–32B models with iteratively improved few-shot examples. They are directionally encouraging but not publishable. The validation suite exists to produce rigorous, versioned, defensible numbers.

# MVP1 Objectives

The validation test suite MVP1 serves three distinct audiences with different requirements:

## Product Development

Track SEQUR generation accuracy over time. Detect regressions when system prompts, few-shot examples, parser rules, schema, or models change. Identify systematic failure patterns by complexity tier and domain. Guide investment in fine-tuning, prompt engineering, and grammar simplification.

## Patent Filing

Provide timestamped, cryptographically anchored evidence of reduction to practice. Demonstrate novelty through systematic RAG comparison. Capture full context chains showing the multi-adapter fan-out and merge algorithm in action. Document the capability gap between SEQUR-mediated context and traditional retrieval.

## Business Development

Produce publishable accuracy numbers for conversations with co-founders, investors, and design partners. Show trajectory — accuracy improving over time as the system learns. Provide concrete evidence that the thesis holds: agents speaking SEQUR against a shared context fabric produces measurably better results than the current approach.

# Feature Definitions

## F1: Test Intent Corpus

**Purpose: **Define the 100 natural language intents that form the fixed evaluation benchmark.

### Specification

100 intents stratified by complexity and distributed across domains. Each intent includes the natural language question, the expected primitive type, and a gold standard SEQUR expression written by a human expert.

| **Tier** | **Count** | **Definition** | **Example Intent** |
| --- | --- | --- | --- |
| Simple | 40 | Single primitive (RESOLVE or DISCOVER), 1–2 parameters. | "What’s our current ARR?" |
| Moderate | 35 | Single primitive, 3–4 parameters with constraints (freshness, reputation, scope, depth). | "Get the churn rate from product, must be less than a week old, include lineage." |
| Complex | 15 | Single primitive, full parameter set with fallbacks, multiple scopes, annotations. | "Resolve ARR from finance with high reputation, fall back to product then global, include full lineage and owner." |
| Multi-step | 10 | Intent requires 2+ SEQUR expressions in sequence. | "Find everything related to churn, then get the current value of the top driver." |

### Domain Distribution

| **Domain** | **Target Count** | **Rationale** |
| --- | --- | --- |
| Finance | 25 | Core business domain with dense entity relationships (ARR, burn_rate, operating_expenses, etc.) |
| Product | 25 | Growth and retention metrics, heavy cross-domain linkage to finance and customer success |
| Customer Success | 20 | NRR, satisfaction, support metrics. Tests scope:customer_success resolution. |
| HR | 15 | Workforce metrics (headcount, attrition, eNPS). Tests cross-domain causal chains to finance. |
| Cross-domain | 15 | Questions that inherently span 2+ domains. Tests multi-scope WITHIN and cross-domain DISCOVER. |

### Gold Standard Requirements

Each intent’s gold standard SEQUR expression must:

- Parse successfully against the current NimbleParsec grammar

- Reference only entities and scopes that exist in the seeded schema

- Use the optimal primitive for the intent (not just a valid one)

- Include appropriate optional clauses that a skilled SEQUR user would include

- Be reviewed by at least one other person before inclusion in the corpus

### Storage Schema

test_intents

  id              UUID PRIMARY KEY

  natural_language TEXT NOT NULL

  tier             VARCHAR(20) NOT NULL  -- simple|moderate|complex|multi_step

  domain           VARCHAR(30) NOT NULL  -- finance|product|customer_success|hr|cross_domain

  expected_primitive VARCHAR(20) NOT NULL -- RESOLVE|DISCOVER|MULTI

  gold_sequr       TEXT NOT NULL          -- the human-authored gold standard expression

  gold_entities    JSONB                  -- expected entity references [{namespace, name}]

  gold_scopes      JSONB                  -- expected scope references

  notes            TEXT                   -- edge cases, known difficulties, context

  version          INTEGER DEFAULT 1      -- allows corpus versioning

  inserted_at      TIMESTAMP

  updated_at       TIMESTAMP

## F2: Configuration Fingerprinting

**Purpose: **Capture the exact system state for every test run so results are reproducible and comparable.

### Fingerprint Fields

| **Field** | **Type** | **Source** | **Why It Matters** |
| --- | --- | --- | --- |
| model_name | VARCHAR | Ollama API or Claude API response | Different models produce different SEQUR. Must know which model produced which results. |
| model_version | VARCHAR | Model metadata | Same model name can have different quantizations or versions. |
| system_prompt_hash | VARCHAR(64) | SHA-256 of the system prompt text | Few-shot examples and grammar reference change frequently. The hash tracks which version was active. |
| system_prompt_text | TEXT | Full system prompt | The hash identifies; the full text enables reconstruction if needed. |
| parser_git_commit | VARCHAR(40) | git rev-parse HEAD | Ties results to exact parser code. Detects regressions from parser changes. |
| schema_fingerprint | JSONB | Computed from DB | Entity count, relationship count, scope count, schema version hash. Detects data changes. |
| adapter_versions | JSONB | Runtime introspection | Which adapters were active and their configuration. |
| run_timestamp | TIMESTAMP | System clock | When the run executed. |
| run_duration_ms | INTEGER | Measured | Total wall-clock time for the full suite. |
| run_notes | TEXT | Manual input | Free-text notes about what changed or why this run was triggered. |

### Storage Schema

test_runs

  id                UUID PRIMARY KEY

  model_name        VARCHAR NOT NULL

  model_version     VARCHAR

  system_prompt_hash VARCHAR(64) NOT NULL

  system_prompt_text TEXT NOT NULL

  parser_git_commit VARCHAR(40) NOT NULL

  schema_fingerprint JSONB NOT NULL

  adapter_versions   JSONB NOT NULL

  run_timestamp      TIMESTAMP NOT NULL

  run_duration_ms    INTEGER

  run_notes          TEXT

  -- Patent evidence fields

  git_commit_hash    VARCHAR(40) NOT NULL  -- full repo state, not just parser

  git_signed         BOOLEAN DEFAULT false -- whether commit is GPG-signed

  corpus_version     INTEGER NOT NULL       -- which version of test_intents was used

  inserted_at        TIMESTAMP

## F3: Automated Scoring Engine

**Purpose: **Score every generated SEQUR expression on three axes automatically, with optional human/LLM-judge scoring for intent fidelity.

### Scoring Axes

| **Axis** | **Method** | **Score Type** | **Automation Level** |
| --- | --- | --- | --- |
| Syntactic accuracy | Pass the generated expression through Sequr.Parser.parse/1. Binary pass/fail. | Boolean (1 or 0) | Fully automated |
| Semantic accuracy | If parsed, validate that all entity references exist in the schema and all scope references exist. Validate parameter types (durations, scores, depths). | Boolean (1 or 0) | Fully automated |
| Intent fidelity | Compare the generated expression to the gold standard. Score 1–5 on whether it captures the human’s actual intent. Can be human-evaluated or LLM-judge evaluated. | Integer 1–5 | Semi-automated (LLM judge with human override) |

### Intent Fidelity Rubric

| **Score** | **Definition** |
| --- | --- |
| 5 | Exact match or functionally equivalent to gold standard. Correct primitive, correct entity, correct scope, appropriate parameters. |
| 4 | Correct primitive and entity. Minor parameter differences (missing an optional annotation, slightly different depth). Would retrieve essentially the same context. |
| 3 | Correct concept but wrong addressing. Used search term instead of entity reference, or used a related but not optimal entity. Retrieves relevant but suboptimal context. |
| 2 | Wrong primitive or fundamentally wrong entity. Intent partially captured but execution would produce significantly different context. |
| 1 | Completely wrong. Generated expression bears no meaningful relationship to the intent. |

### LLM Judge Implementation

For MVP1, intent fidelity scoring uses a second LLM call (the "judge") that receives the natural language intent, the gold standard SEQUR, and the generated SEQUR, then returns a score 1–5 with rationale. The judge prompt must be deterministic — same inputs should produce same scores. Human override is available for disputed scores.

The judge model should be a frontier model (Claude API) even when the generation model is a local model. This ensures the judge is more capable than the generator.

### Storage Schema

test_results

  id                  UUID PRIMARY KEY

  run_id              UUID REFERENCES test_runs(id)

  intent_id           UUID REFERENCES test_intents(id)

  -- Generation output

  llm_raw_response    TEXT           -- full LLM response before extraction

  generated_sequr     TEXT           -- extracted SEQUR expression

  generation_time_ms  INTEGER        -- latency for this single generation

  -- Scoring

  syntactic_pass      BOOLEAN        -- did it parse?

  parse_error         TEXT           -- if it failed, what was the error?

  semantic_pass       BOOLEAN        -- valid entities, scopes, types?

  semantic_errors     JSONB          -- list of specific validation failures

  intent_fidelity     INTEGER        -- 1-5 score

  fidelity_rationale  TEXT           -- judge's reasoning

  fidelity_judge      VARCHAR        -- 'llm_judge' or 'human'

  fidelity_override   INTEGER        -- human override score if different from judge

  -- Patent evidence fields

  adapter_individual_results JSONB   -- what each adapter returned separately

  context_chain       JSONB          -- full DISCOVER->rank->RESOLVE->synthesize chain

  execution_result    JSONB          -- the actual SEQUR execution output (if executed)

  -- Failure categorization

  failure_category    VARCHAR        -- parse_error|wrong_entity|wrong_primitive|

                                     -- invented_syntax|wrong_scope|parameter_error|null

  inserted_at         TIMESTAMP

## F4: Patent Evidence Capture

**Purpose: **Systematically collect evidence that supports the three patent claims: SEQUR specification, semantic governance process, and context assembly algorithm.

### Evidence Requirements by Claim

**Claim 1 — SEQUR Specification: **Demonstrate that SEQUR is a functional, novel query language that agents can reliably generate and that produces meaningful results.

- Reduction to practice: timestamped test runs proving the parser works, agents generate valid SEQUR, and the expressions produce real context retrieval results.

- Novelty: no prior art demonstrates a declarative query language designed for machine cognition that maps to cognitive operations (resolve, discover, trace) rather than data operations (select, join, filter).

- Non-obviousness: the agent generation contract (system prompt + schema + few-shot examples enabling reliable LLM generation) is a non-obvious innovation.

**Claim 2 — Semantic Governance Process: **Demonstrate the CERTIFY workflow, reputation network via SIGNAL, and adaptive governance model.

- Evidence comes primarily from SIGNAL and CERTIFY implementation tests (future primitives), but the test suite captures the foundation: scope-based access, entity ownership, quality metadata in return envelopes.

**Claim 3 — Context Assembly Algorithm: **Demonstrate that the multi-adapter fan-out, scope-aware filtering, and result merging algorithm produces qualitatively different and superior results to traditional retrieval.

- The context_chain field in test_results captures the full algorithm execution path.

- The adapter_individual_results field captures what each adapter returned independently.

- The comparison_runs table captures the RAG baseline for the same intents.

### Comparison Baseline Table

comparison_runs

  id                  UUID PRIMARY KEY

  run_id              UUID REFERENCES test_runs(id)  -- the SEQUR run being compared

  baseline_system     VARCHAR NOT NULL  -- 'langchain_rag'|'direct_sql'|'direct_cypher'

  baseline_config     JSONB             -- system details of baseline (model, chunking, etc)

  intent_id           UUID REFERENCES test_intents(id)

  baseline_result     JSONB             -- what the baseline system returned

  capability_gaps     JSONB             -- structured list of what SEQUR returned

                                        -- that the baseline could not

  quality_comparison  JSONB             -- side-by-side quality assessment

  inserted_at         TIMESTAMP

### Cryptographic Timestamping

After each test run completes, the full results are hashed and committed to git with a GPG-signed commit. The git history provides an immutable timestamped record of when each capability was demonstrated. The process:

- Run completes and results are written to the database.

- A results summary JSON is generated including: run_id, timestamp, aggregate scores, model, git commit of the codebase.

- The summary is written to a file in the repository (e.g., validation/runs/<run_id>.json).

- A GPG-signed git commit is created: git commit -S -m "Validation run <run_id>: syntactic=X%, semantic=Y%, fidelity=Z"

- The signed commit hash is written back to the test_runs record as temporal_anchor.

## F5: Execution Runner

**Purpose: **Orchestrate the execution of all 100 intents against a specific configuration, with progress tracking and fault tolerance.

### Runner Behavior

- Accept configuration parameters: model provider (ollama/claude), model name, optional system prompt override.

- Compute the configuration fingerprint and create a test_runs record.

- Load all test_intents for the active corpus version.

- For each intent, sequentially: send the natural language to the LLM with the standard system prompt, capture the raw response, extract the SEQUR expression, attempt to parse it, validate entity/scope references, score intent fidelity via LLM judge.

- Optionally execute the parsed SEQUR through Sequr.Engine and capture the full context chain and adapter-level results.

- Write each test_results record as it completes (not batch at end — fault tolerance).

- On completion, compute aggregate scores and update the test_runs record with duration and summary statistics.

- Trigger the cryptographic timestamping workflow.

### Fault Tolerance

The runner must handle: LLM timeouts (configurable, default 60s per intent), LLM rate limiting (backoff and retry), adapter failures during execution (capture partial results), runner crash mid-suite (resume from last completed intent using the run_id and checking which intent_ids have results).

### Elixir Implementation Notes

The runner is a GenServer under the application supervision tree. It processes intents sequentially (not concurrently) to avoid LLM rate limiting and to ensure deterministic ordering. Progress is broadcast via Phoenix PubSub so the LiveView dashboard can show real-time progress.

defmodule Unica.Validation.Runner do

  use GenServer

  def start_run(config) do

    GenServer.call(__MODULE__, {:start_run, config})

  end

  def resume_run(run_id) do

    GenServer.call(__MODULE__, {:resume_run, run_id})

  end

  # State: %{run_id, config, progress, total, status}

end

## F6: Results Dashboard

**Purpose: **Phoenix LiveView page at /validation showing validation results with drill-down, comparison, and trend analysis.

### Dashboard Views

**Run Summary: **Aggregate scores for the most recent run. Three metric cards: syntactic accuracy %, semantic accuracy %, intent fidelity average. Configuration fingerprint displayed below. Pass/fail status against targets (90%/85%/4.0).

**Tier Breakdown: **Bar chart showing accuracy scores broken down by complexity tier. Immediately answers: are simple intents at 95% while complex ones are at 60%?

**Domain Breakdown: **Bar chart showing accuracy scores broken down by domain. Immediately answers: are finance intents accurate but HR intents failing?

**Failure Analysis: **Table of failed intents with: the natural language input, the generated SEQUR, the gold standard, the parse error or semantic error, and the failure category. Filterable by tier, domain, and failure category.

**Trend Over Time: **Line chart showing syntactic accuracy, semantic accuracy, and intent fidelity across all runs. X-axis is run timestamp. Hover shows the configuration fingerprint for each run. Immediately answers: is the system getting better?

**Run Comparison: **Select two runs side by side. For each intent, show: did the score change? What was the generated SEQUR in each run? Highlight regressions (passed before, failed now) in red.

**Regression Detection: **Automated flag on any intent that passed syntactically or semantically in the previous run but failed in the current run. These regressions require investigation before the run is considered valid.

### LiveView Implementation Notes

The dashboard is a Phoenix LiveView mounted at /validation in the existing Phoenix application. It reads from the test_intents, test_runs, and test_results tables. Charts use a lightweight JS charting library (Chart.js via CDN hook). The run-in-progress view shows a real-time progress bar updated via PubSub broadcasts from the Runner GenServer.

## F7: RAG Comparison Baseline

**Purpose: **Run a subset of test intents through a standard RAG pipeline using the same data and same LLM, and systematically document what SEQUR produces that RAG cannot.

### MVP1 Scope

For MVP1, the RAG comparison does not need to be fully automated. A manual or semi-automated process covering 20 representative intents (5 per tier) is sufficient for the provisional patent filing. Full automation is a post-MVP1 enhancement.

### Baseline System

The baseline is a standard retrieval pipeline: the same LLM receives the same natural language intent, but instead of generating SEQUR, it has access to direct tool calls against the same Postgres and Neo4j backends. The tools are: query_postgres(sql), query_neo4j(cypher), search_vectors(query_text). The LLM decides which tools to call and how to combine results.

### Capability Gap Documentation

For each compared intent, the capability_gaps field captures structured evidence of what SEQUR provides that the RAG baseline cannot:

- **Scope-aware filtering: **Did SEQUR return results scoped to organizational boundaries that RAG returned without scope context?

- **Quality metadata: **Did SEQUR return freshness, reputation, confidence, lineage that RAG did not?

- **Cross-adapter merging: **Did SEQUR merge graph traversal results with vector similarity results into a coherent neighborhood that RAG retrieved separately without merging?

- **Causal chain discovery: **Did SEQUR discover multi-hop causal relationships (e.g., eNPS → attrition → operating_expenses) that RAG’s individual queries missed?

- **Attribution: **Did SEQUR identify which adapter contributed each piece of context, enabling the agent to reason about source reliability?

# Improvements Over Previously Discussed Design

The following enhancements extend beyond what was originally discussed in the architecture conversations:

## Failure Categorization Taxonomy

The earlier discussion mentioned tracking failures but did not define a taxonomy. MVP1 introduces a closed set of failure categories that enables pattern analysis:

| **Category** | **Definition** | **Remediation Path** |
| --- | --- | --- |
| parse_error | Expression does not parse against the NimbleParsec grammar. | Grammar simplification, additional few-shot examples, constrained decoding. |
| wrong_entity | Parsed, but references an entity that does not exist in the schema. | Improve schema presentation in system prompt, add entity lookup examples. |
| wrong_primitive | Parsed and valid entities, but used RESOLVE when DISCOVER was appropriate (or vice versa). | Add primitive selection examples, clarify when to use each. |
| invented_syntax | LLM generated syntax constructs that do not exist in SEQUR (e.g., multiple anchors, nested expressions). | Add negative examples to system prompt. |
| wrong_scope | Correct entity but queried from a scope that doesn’t contain it. | Improve scope-entity mapping in schema format. |
| parameter_error | Correct primitive and entity but invalid parameter values (e.g., non-numeric depth, malformed duration). | Add parameter constraint examples. |
| partial_intent | Captures part of the intent but misses a significant aspect (e.g., user asked for freshness constraint, LLM omitted it). | More complete few-shot examples with full parameter sets. |

## Execution Mode Toggle

The original design assumed all test intents would be both generated and executed. MVP1 adds a toggle: generation-only mode (score the SEQUR expression without executing it against the engine) and full-execution mode (generate, score, and execute through the engine with full context chain capture). Generation-only mode is faster, cheaper (no adapter calls), and sufficient for syntax/semantic/fidelity scoring. Full-execution mode is required for patent evidence capture and RAG comparison.

## Corpus Versioning

The original design had a static set of 100 intents. MVP1 adds corpus versioning: the test_intents table has a version field, and each test_run records which corpus version it ran against. This allows the intent suite to evolve (adding harder intents, refining gold standards, adding SIGNAL/TRACE intents later) while maintaining comparability within a version.

## Resume-from-Failure

The original design did not discuss fault tolerance for the runner. MVP1 adds resume capability: if the runner crashes mid-suite (LLM timeout, adapter failure, process crash), it can resume from the last completed intent rather than restarting the entire 100-intent run. This is implemented by checking which intent_ids already have results for the current run_id.

## Multi-Expression Scoring for Multi-Step Tier

The original design did not specify how to score the multi-step tier (10 intents). MVP1 defines: the LLM’s response is evaluated for whether it correctly identified that multiple expressions are needed, whether each individual expression is syntactically correct, and whether the sequence is logically ordered (typically DISCOVER first, then RESOLVE on specific items). The gold standard for multi-step intents includes the full sequence, and scoring is per-expression within the sequence plus a sequence-level coherence score.

# Implementation Plan

MVP1 is scoped for approximately 2 weeks of development using Claude Code as the primary development tool. The implementation is sequenced to deliver value incrementally.

## Week 1: Foundation

- Database migrations for test_intents, test_runs, test_results, comparison_runs tables.

- Ecto schemas and contexts for the validation domain.

- Test intent corpus: author all 100 intents with gold standards. This is the most time-consuming step and requires careful thought about each intent.

- Scoring engine: Syntactic scorer (parse/no-parse), Semantic scorer (entity/scope validation against DB), Intent fidelity judge (LLM judge prompt, score extraction).

- Basic runner GenServer: sequential execution, per-intent result writes, configuration fingerprinting.

## Week 2: Dashboard and Evidence

- Phoenix LiveView dashboard: run summary, tier breakdown, domain breakdown, failure analysis table.

- Trend chart: accuracy over time across runs.

- Run comparison view: side-by-side diff of two runs.

- Regression detection: automated flagging of intents that regressed.

- Patent evidence: context chain capture, adapter individual results, cryptographic timestamping via signed git commits.

- RAG comparison: manual baseline run for 20 representative intents, capability gap documentation.

## Post-MVP1 Enhancements

- Automated RAG comparison pipeline (full 100-intent baseline)

- SIGNAL and TRACE intent tiers (added as those primitives are implemented)

- Cross-model comparison dashboard (run same suite against multiple models in one session)

- Statistical significance testing (are two runs’ accuracy differences statistically meaningful?)

- Export to patent-filing format (structured evidence package for provisional application)

- Fine-tuning data generation (use failures to generate training pairs for a SEQUR-specialized model)

- CI integration (run validation suite on every parser commit, fail the build on regression)

# Success Criteria for MVP1

MVP1 is complete when:

- 100 test intents are authored with gold standards, stratified by tier and domain, stored in the database.

- The runner can execute the full 100-intent suite against any configured model and produce per-intent scores.

- Syntactic accuracy, semantic accuracy, and intent fidelity scores are computed automatically.

- The LiveView dashboard displays run summaries, tier/domain breakdowns, failure analysis, and trend charts.

- At least two runs have been completed (different models or different system prompts) to validate the comparison and trend features.

- Patent evidence fields (context_chain, adapter_individual_results) are captured for at least one full-execution run.

- At least 20 RAG comparison results are documented in the comparison_runs table with capability gap analysis.

- One GPG-signed git commit anchors the first formal validation run with timestamped results.

## Target Metrics

| **Metric** | **Phase 1 Target** | **Stretch Target** | **Notes** |
| --- | --- | --- | --- |
| Syntactic accuracy | 90%+ | 95%+ | Across all 100 intents. Simple tier should be near 100%. |
| Semantic accuracy | 85%+ | 92%+ | On expressions that parse. Schema presentation quality is the lever. |
| Intent fidelity | 4.0+ average | 4.3+ average | On 5-point scale. LLM judge validated by human spot-check. |
| Multi-step coherence | 70%+ | 85%+ | Percentage of multi-step intents where the LLM correctly generates a valid sequence. |

END OF DOCUMENT